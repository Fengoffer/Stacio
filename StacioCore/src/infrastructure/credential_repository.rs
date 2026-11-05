use chrono::Utc;
use rusqlite::{params, Connection};
use uuid::Uuid;

use crate::domain::{
    credential::{CredentialDraft, CredentialRecord},
    session::SessionError,
};

pub struct CredentialRepository {
    connection: Connection,
}

impl CredentialRepository {
    pub fn new(connection: Connection) -> Self {
        Self { connection }
    }

    pub fn save_credential(
        &self,
        draft: CredentialDraft,
    ) -> Result<CredentialRecord, SessionError> {
        let record = CredentialRecord {
            id: Uuid::new_v4().to_string(),
            kind: draft.kind.trim().to_string(),
            label: draft.label.trim().to_string(),
            keychain_service: draft.keychain_service.trim().to_string(),
            keychain_account: draft.keychain_account.trim().to_string(),
        };
        let now = Utc::now().to_rfc3339();

        self.connection.execute(
            "INSERT INTO credentials
             (id, kind, label, keychain_service, keychain_account, last_verified_at, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, NULL, ?6, ?6)",
            params![
                record.id,
                record.kind,
                record.label,
                record.keychain_service,
                record.keychain_account,
                now
            ],
        )?;

        Ok(record)
    }

    pub fn list_credentials(&self) -> Result<Vec<CredentialRecord>, SessionError> {
        let mut statement = self.connection.prepare(
            "SELECT id, kind, label, keychain_service, keychain_account
             FROM credentials ORDER BY label COLLATE NOCASE",
        )?;
        let records = statement
            .query_map([], read_credential)?
            .collect::<Result<Vec<_>, _>>()?;

        Ok(records)
    }

    pub fn delete_credential(&self, id: String) -> Result<(), SessionError> {
        self.connection
            .execute("DELETE FROM credentials WHERE id = ?1", params![id])?;
        Ok(())
    }
}

fn read_credential(row: &rusqlite::Row<'_>) -> rusqlite::Result<CredentialRecord> {
    Ok(CredentialRecord {
        id: row.get(0)?,
        kind: row.get(1)?,
        label: row.get(2)?,
        keychain_service: row.get(3)?,
        keychain_account: row.get(4)?,
    })
}

#[cfg(test)]
mod credential_repository_tests {
    use rusqlite::Connection;

    use crate::domain::credential::CredentialDraft;
    use crate::infrastructure::db::apply_migrations;

    use super::CredentialRepository;

    #[test]
    fn saves_and_lists_credential_metadata_without_secret_values() {
        let connection = Connection::open_in_memory().expect("open database");
        apply_migrations(&connection).expect("migrate");
        let repository = CredentialRepository::new(connection);

        let record = repository
            .save_credential(CredentialDraft {
                kind: "password".to_string(),
                label: "API password".to_string(),
                keychain_service: "Stacio".to_string(),
                keychain_account: "deploy@example.com".to_string(),
            })
            .expect("save credential");

        let records = repository.list_credentials().expect("list credentials");
        let serialized = serde_json::to_string(&records).expect("serialize");

        assert_eq!(records, vec![record]);
        assert!(!serialized.contains("super-secret"));
        assert!(!serialized.contains("password123"));
    }

    #[test]
    fn deletes_credential_metadata() {
        let connection = Connection::open_in_memory().expect("open database");
        apply_migrations(&connection).expect("migrate");
        let repository = CredentialRepository::new(connection);
        let record = repository
            .save_credential(CredentialDraft {
                kind: "password".to_string(),
                label: "API password".to_string(),
                keychain_service: "Stacio".to_string(),
                keychain_account: "deploy@example.com".to_string(),
            })
            .expect("save credential");

        repository
            .delete_credential(record.id)
            .expect("delete credential");

        assert!(repository
            .list_credentials()
            .expect("list credentials")
            .is_empty());
    }
}
