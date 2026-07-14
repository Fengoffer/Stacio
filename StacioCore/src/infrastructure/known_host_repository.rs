use chrono::Utc;
use rusqlite::{params, Connection, OptionalExtension};

use crate::domain::ssh::{HostKeyRecord, SshRuntimeError};
use crate::services::ssh_service::KnownHostStore;

pub struct KnownHostRepository {
    connection: Connection,
}

impl KnownHostRepository {
    pub fn new(connection: Connection) -> Self {
        Self { connection }
    }

    pub fn upsert(&self, record: &HostKeyRecord) -> Result<(), SshRuntimeError> {
        let now = Utc::now().to_rfc3339();
        self.connection
            .execute(
                "INSERT INTO known_hosts (host, port, fingerprint_sha256, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?4)
                 ON CONFLICT(host, port) DO UPDATE SET
                   fingerprint_sha256 = excluded.fingerprint_sha256,
                   updated_at = excluded.updated_at",
                params![
                    record.host,
                    i64::from(record.port),
                    record.fingerprint_sha256,
                    now
                ],
            )
            .map_err(map_db_error)?;

        Ok(())
    }

    pub fn find(&self, host: &str, port: u16) -> Result<Option<HostKeyRecord>, SshRuntimeError> {
        self.connection
            .query_row(
                "SELECT host, port, fingerprint_sha256 FROM known_hosts WHERE host = ?1 AND port = ?2",
                params![host, i64::from(port)],
                read_known_host,
            )
            .optional()
            .map_err(map_db_error)
    }

    pub fn delete(&self, host: &str, port: u16) -> Result<(), SshRuntimeError> {
        self.connection
            .execute(
                "DELETE FROM known_hosts WHERE host = ?1 AND port = ?2",
                params![host, i64::from(port)],
            )
            .map_err(map_db_error)?;
        Ok(())
    }

    pub fn list_all(&self) -> Result<Vec<HostKeyRecord>, SshRuntimeError> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT host, port, fingerprint_sha256
                 FROM known_hosts
                 ORDER BY host COLLATE NOCASE, port",
            )
            .map_err(map_db_error)?;
        let records = statement
            .query_map([], read_known_host)
            .map_err(map_db_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(map_db_error)?;
        Ok(records)
    }
}

impl KnownHostStore for KnownHostRepository {
    fn find_known_host(
        &self,
        host: &str,
        port: u16,
    ) -> Result<Option<HostKeyRecord>, SshRuntimeError> {
        self.find(host, port)
    }

    fn save_known_host(&self, record: HostKeyRecord) -> Result<(), SshRuntimeError> {
        self.upsert(&record)
    }
}

fn read_known_host(row: &rusqlite::Row<'_>) -> rusqlite::Result<HostKeyRecord> {
    let port: i64 = row.get(1)?;
    Ok(HostKeyRecord {
        host: row.get(0)?,
        port: port as u16,
        fingerprint_sha256: row.get(2)?,
    })
}

fn map_db_error(error: rusqlite::Error) -> SshRuntimeError {
    SshRuntimeError::Transport {
        message: format!("known host database error: {error}"),
    }
}

#[cfg(test)]
mod known_host_repository_tests {
    use rusqlite::Connection;

    use crate::domain::ssh::HostKeyRecord;
    use crate::infrastructure::db::apply_migrations;

    use super::KnownHostRepository;

    #[test]
    fn migration_creates_known_hosts_table() {
        let connection = migrated_connection();

        let exists: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'known_hosts'",
                [],
                |row| row.get(0),
            )
            .expect("table query");

        assert_eq!(exists, 1);
    }

    #[test]
    fn upserts_and_finds_known_host_by_host_and_port() {
        let repository = KnownHostRepository::new(migrated_connection());
        let record = HostKeyRecord {
            host: "example.com".to_string(),
            port: 22,
            fingerprint_sha256: "SHA256:first".to_string(),
        };

        repository.upsert(&record).expect("save known host");

        let found = repository
            .find("example.com", 22)
            .expect("find known host")
            .expect("known host");

        assert_eq!(found, record);
    }

    #[test]
    fn replaces_changed_fingerprint_for_same_host_and_port() {
        let repository = KnownHostRepository::new(migrated_connection());
        repository
            .upsert(&HostKeyRecord {
                host: "example.com".to_string(),
                port: 22,
                fingerprint_sha256: "SHA256:old".to_string(),
            })
            .expect("save old");

        repository
            .upsert(&HostKeyRecord {
                host: "example.com".to_string(),
                port: 22,
                fingerprint_sha256: "SHA256:new".to_string(),
            })
            .expect("save new");

        let found = repository
            .find("example.com", 22)
            .expect("find")
            .expect("known host");

        assert_eq!(found.fingerprint_sha256, "SHA256:new");
    }

    #[test]
    fn deletes_known_host_by_host_and_port() {
        let repository = KnownHostRepository::new(migrated_connection());
        repository
            .upsert(&HostKeyRecord {
                host: "example.com".to_string(),
                port: 22,
                fingerprint_sha256: "SHA256:old".to_string(),
            })
            .expect("save old");

        repository
            .delete("example.com", 22)
            .expect("delete known host");

        assert!(repository.find("example.com", 22).expect("find").is_none());
    }

    #[test]
    fn lists_known_hosts_without_secret_or_system_command_values() {
        let repository = KnownHostRepository::new(migrated_connection());
        repository
            .upsert(&HostKeyRecord {
                host: "b.example.com".to_string(),
                port: 22,
                fingerprint_sha256: "SHA256:b".to_string(),
            })
            .expect("save b");
        repository
            .upsert(&HostKeyRecord {
                host: "a.example.com".to_string(),
                port: 2222,
                fingerprint_sha256: "SHA256:a".to_string(),
            })
            .expect("save a");

        let records = repository.list_all().expect("list known hosts");
        let serialized = serde_json::to_string(&records).expect("serialize");

        assert_eq!(records[0].host, "a.example.com");
        assert_eq!(records[1].host, "b.example.com");
        assert!(!serialized.contains("secret"));
        assert!(!serialized.contains("password"));
        assert!(!serialized.contains("ssh "));
        assert!(!serialized.contains("scp "));
    }

    fn migrated_connection() -> Connection {
        let connection = Connection::open_in_memory().expect("open database");
        apply_migrations(&connection).expect("migrate");
        connection
    }
}
