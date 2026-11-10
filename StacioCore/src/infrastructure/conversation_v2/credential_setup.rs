//! CredentialUseLease owner 隔离、VerificationRequest 状态机与 revoke fence（P3-8c，独立存储域）。
//!
//! 本轮实现状态机部分；Permit 接线与 Keychain staging（credentialSetupCreate/originCopy/
//! rotation/configurationActivation）待 P3-9 落地后实施（计划 P3-8c 执行顺序）。

use rusqlite::{params, Connection};
use std::sync::{Arc, Mutex};

const SETUP_INIT_SQL: &str = include_str!("../../../migrations/credential_setup_0001_init.sql");

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CredentialSetupError {
    OwnerMismatch { expected: String, actual: String },
    RevokeGateClosed { generation_id: String },
    InvalidTransition { from: String, to: String },
    NotFound { id: String },
    Storage(String),
}

pub struct CredentialSetupDb {
    connection: Arc<Mutex<Connection>>,
 #[allow(dead_code)] //保留数据库路径，供诊断与未来排查使用
    path: String,
}

impl CredentialSetupDb {
    pub fn open(path: &str) -> rusqlite::Result<Self> {
        let connection = Connection::open(path)?;
        let db = Self {
            connection: Arc::new(Mutex::new(connection)),
            path: path.to_string(),
        };
        db.apply_migrations()?;
        Ok(db)
    }

    pub fn open_in_memory() -> rusqlite::Result<Self> {
        let connection = Connection::open_in_memory()?;
        let db = Self {
            connection: Arc::new(Mutex::new(connection)),
            path: ":memory:".to_string(),
        };
        db.apply_migrations()?;
        Ok(db)
    }

    pub fn connection(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.connection.lock().expect("setup db poisoned")
    }

    pub fn connection_arc(&self) -> Arc<Mutex<Connection>> {
        Arc::clone(&self.connection)
    }

    fn apply_migrations(&self) -> rusqlite::Result<()> {
        self.connection().execute_batch(SETUP_INIT_SQL)
    }
}

pub struct CredentialSetupStore {
    connection: Arc<Mutex<Connection>>,
}

impl CredentialSetupStore {
    pub fn new(db: &CredentialSetupDb) -> Self {
        Self {
            connection: db.connection_arc(),
        }
    }

    // MARK: use lease（三类 owner 隔离）

    pub fn acquire_use_lease(
        &self,
        lease_id: &str,
        owner: &str,
        credential_generation_id: &str,
    ) -> Result<(), CredentialSetupError> {
        let connection = self.connection.lock().expect("setup db poisoned");
        // revoke gate：已关闭则拒绝新 lease
        let gate_closed: bool = connection
            .query_row(
                "SELECT closed = 1 FROM credential_revoke_fence WHERE credential_generation_id = ?1",
                params![credential_generation_id],
                |row| row.get::<_, bool>(0),
            )
            .unwrap_or(false);
        if gate_closed {
            return Err(CredentialSetupError::RevokeGateClosed {
                generation_id: credential_generation_id.to_string(),
            });
        }
        connection
            .execute(
                "INSERT INTO credential_use_lease (lease_id, owner, state, credential_generation_id, created_at)
                 VALUES (?1, ?2, 'granted', ?3, 't')",
                params![lease_id, owner, credential_generation_id],
            )
            .map_err(|error| CredentialSetupError::Storage(error.to_string()))?;
        Ok(())
    }

    /// owner 隔离：Attempt/setup/configuration-action 不能互换。
    pub fn validate_owner(&self, lease_id: &str, owner: &str) -> Result<(), CredentialSetupError> {
        let connection = self.connection.lock().expect("setup db poisoned");
        let expected: String = connection
            .query_row(
                "SELECT owner FROM credential_use_lease WHERE lease_id = ?1",
                params![lease_id],
                |row| row.get(0),
            )
            .map_err(|_| CredentialSetupError::NotFound {
                id: lease_id.to_string(),
            })?;
        if expected != owner {
            return Err(CredentialSetupError::OwnerMismatch {
                expected,
                actual: owner.to_string(),
            });
        }
        Ok(())
    }

    pub fn release_use_lease(&self, lease_id: &str) -> Result<(), CredentialSetupError> {
        let connection = self.connection.lock().expect("setup db poisoned");
        let state: String = connection
            .query_row(
                "SELECT state FROM credential_use_lease WHERE lease_id = ?1",
                params![lease_id],
                |row| row.get(0),
            )
            .map_err(|_| CredentialSetupError::NotFound {
                id: lease_id.to_string(),
            })?;
        if state != "granted" {
            return Err(CredentialSetupError::InvalidTransition {
                from: state,
                to: "released".to_string(),
            });
        }
        connection
            .execute(
                "UPDATE credential_use_lease SET state = 'released', released_at = 't' WHERE lease_id = ?1",
                params![lease_id],
            )
            .map_err(|error| CredentialSetupError::Storage(error.to_string()))?;
        Ok(())
    }

    pub fn lease_state(&self, lease_id: &str) -> Result<String, CredentialSetupError> {
        let connection = self.connection.lock().expect("setup db poisoned");
        connection
            .query_row(
                "SELECT state FROM credential_use_lease WHERE lease_id = ?1",
                params![lease_id],
                |row| row.get(0),
            )
            .map_err(|_| CredentialSetupError::NotFound {
                id: lease_id.to_string(),
            })
    }

    // MARK: verification request 状态机

    pub fn create_verification_request(
        &self,
        request_id: &str,
        configuration_id: &str,
    ) -> Result<(), CredentialSetupError> {
        let connection = self.connection.lock().expect("setup db poisoned");
        connection
            .execute(
                "INSERT INTO credential_verification_request (request_id, configuration_id, state, created_at)
                 VALUES (?1, ?2, 'prepared', 't')",
                params![request_id, configuration_id],
            )
            .map_err(|error| CredentialSetupError::Storage(error.to_string()))?;
        Ok(())
    }

    fn transition_request(&self, request_id: &str, to: &str) -> Result<(), CredentialSetupError> {
        let connection = self.connection.lock().expect("setup db poisoned");
        let current: String = connection
            .query_row(
                "SELECT state FROM credential_verification_request WHERE request_id = ?1",
                params![request_id],
                |row| row.get(0),
            )
            .map_err(|_| CredentialSetupError::NotFound {
                id: request_id.to_string(),
            })?;
        let allowed = match (current.as_str(), to) {
            ("prepared", "inFlight")
            | ("prepared", "settledCancelled")
            | ("inFlight", "cancellationRequested")
            | ("inFlight", "settledSucceeded")
            | ("inFlight", "settledFailed")
            | ("inFlight", "stateUnknown")
            | ("cancellationRequested", "settledCancelled")
            | ("cancellationRequested", "settledSucceeded")
            | ("cancellationRequested", "settledFailed")
            | ("cancellationRequested", "stateUnknown") => true,
            _ => false,
        };
        if !allowed {
            return Err(CredentialSetupError::InvalidTransition {
                from: current,
                to: to.to_string(),
            });
        }
        connection
            .execute(
                "UPDATE credential_verification_request SET state = ?1 WHERE request_id = ?2",
                params![to, request_id],
            )
            .map_err(|error| CredentialSetupError::Storage(error.to_string()))?;
        Ok(())
    }

    pub fn mark_in_flight(&self, request_id: &str) -> Result<(), CredentialSetupError> {
        self.transition_request(request_id, "inFlight")
    }

    pub fn request_cancellation(&self, request_id: &str) -> Result<(), CredentialSetupError> {
        self.transition_request(request_id, "cancellationRequested")
    }

    pub fn settle_verification(
        &self,
        request_id: &str,
        settlement: &str,
    ) -> Result<(), CredentialSetupError> {
        match settlement {
            "settledSucceeded" | "settledFailed" | "settledCancelled" | "stateUnknown" => {
                self.transition_request(request_id, settlement)
            }
            _ => Err(CredentialSetupError::InvalidTransition {
                from: "unknown".to_string(),
                to: settlement.to_string(),
            }),
        }
    }

    pub fn request_state(&self, request_id: &str) -> Result<String, CredentialSetupError> {
        let connection = self.connection.lock().expect("setup db poisoned");
        connection
            .query_row(
                "SELECT state FROM credential_verification_request WHERE request_id = ?1",
                params![request_id],
                |row| row.get(0),
            )
            .map_err(|_| CredentialSetupError::NotFound {
                id: request_id.to_string(),
            })
    }

    // MARK: revoke fence

    pub fn create_generation_fence(
        &self,
        credential_generation_id: &str,
    ) -> Result<(), CredentialSetupError> {
        let connection = self.connection.lock().expect("setup db poisoned");
        connection
            .execute(
                "INSERT OR IGNORE INTO credential_revoke_fence (credential_generation_id, closed, created_at)
                 VALUES (?1, 0, 't')",
                params![credential_generation_id],
            )
            .map_err(|error| CredentialSetupError::Storage(error.to_string()))?;
        Ok(())
    }

    /// 先 durable 关 gate（closed=1），再 fan-out；gate 关闭后拒绝新 use lease。
    pub fn close_revoke_fence(
        &self,
        credential_generation_id: &str,
    ) -> Result<(), CredentialSetupError> {
        let connection = self.connection.lock().expect("setup db poisoned");
        connection
            .execute(
                "UPDATE credential_revoke_fence SET closed = 1 WHERE credential_generation_id = ?1",
                params![credential_generation_id],
            )
            .map_err(|error| CredentialSetupError::Storage(error.to_string()))?;
        Ok(())
    }

    pub fn fence_closed(
        &self,
        credential_generation_id: &str,
    ) -> Result<bool, CredentialSetupError> {
        let connection = self.connection.lock().expect("setup db poisoned");
        connection
            .query_row(
                "SELECT closed = 1 FROM credential_revoke_fence WHERE credential_generation_id = ?1",
                params![credential_generation_id],
                |row| row.get::<_, bool>(0),
            )
            .map_err(|_| CredentialSetupError::NotFound {
                id: credential_generation_id.to_string(),
            })
    }
}
