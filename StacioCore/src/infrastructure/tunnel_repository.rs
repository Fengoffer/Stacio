use chrono::Utc;
use rusqlite::{params, Connection};

use crate::domain::tunnel::{TunnelKind, TunnelProfile, TunnelProfileRecord};

pub struct TunnelRepository {
    connection: Connection,
}

impl TunnelRepository {
    pub fn new(connection: Connection) -> Self {
        Self { connection }
    }

    pub fn upsert_profile(
        &self,
        session_id: Option<String>,
        profile: &TunnelProfile,
    ) -> Result<(), rusqlite::Error> {
        self.upsert_profile_record(&TunnelProfileRecord {
            profile: profile.clone(),
            session_id,
            endpoint_session_id: None,
        })
    }

    pub fn upsert_profile_record(
        &self,
        record: &TunnelProfileRecord,
    ) -> Result<(), rusqlite::Error> {
        let now = Utc::now().to_rfc3339();
        self.connection.execute(
            "INSERT INTO tunnels
             (id, session_id, kind, local_host, local_port, remote_host, remote_port, endpoint_session_id, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?9)
             ON CONFLICT(id) DO UPDATE SET
               session_id = excluded.session_id,
               kind = excluded.kind,
               local_host = excluded.local_host,
               local_port = excluded.local_port,
               remote_host = excluded.remote_host,
               remote_port = excluded.remote_port,
               endpoint_session_id = excluded.endpoint_session_id,
               updated_at = excluded.updated_at",
            params![
                &record.profile.id,
                record.session_id.as_deref(),
                kind_label(&record.profile.kind),
                &record.profile.local_host,
                i64::from(record.profile.local_port),
                &record.profile.remote_host,
                i64::from(record.profile.remote_port),
                record.endpoint_session_id.as_deref(),
                now
            ],
        )?;

        Ok(())
    }

    pub fn list_profiles(
        &self,
        session_id: Option<String>,
    ) -> Result<Vec<TunnelProfile>, rusqlite::Error> {
        Ok(self
            .list_profile_records(session_id)?
            .into_iter()
            .map(|record| record.profile)
            .collect())
    }

    pub fn list_profile_records(
        &self,
        session_id: Option<String>,
    ) -> Result<Vec<TunnelProfileRecord>, rusqlite::Error> {
        if let Some(session_id) = session_id {
            self.query_profile_records(
                "SELECT id, session_id, kind, local_host, local_port, remote_host, remote_port, endpoint_session_id
                 FROM tunnels WHERE session_id = ?1 ORDER BY id COLLATE NOCASE",
                params![session_id],
            )
        } else {
            self.query_profile_records(
                "SELECT id, session_id, kind, local_host, local_port, remote_host, remote_port, endpoint_session_id
                 FROM tunnels ORDER BY id COLLATE NOCASE",
                [],
            )
        }
    }

    pub fn delete_profile(&self, id: &str) -> Result<(), rusqlite::Error> {
        self.connection
            .execute("DELETE FROM tunnels WHERE id = ?1", params![id])?;
        Ok(())
    }

    fn query_profile_records<P>(
        &self,
        sql: &str,
        params: P,
    ) -> Result<Vec<TunnelProfileRecord>, rusqlite::Error>
    where
        P: rusqlite::Params,
    {
        let mut statement = self.connection.prepare(sql)?;
        let records = statement
            .query_map(params, read_tunnel_profile_record)?
            .collect::<Result<Vec<_>, _>>()?;

        Ok(records)
    }
}

fn read_tunnel_profile_record(row: &rusqlite::Row<'_>) -> rusqlite::Result<TunnelProfileRecord> {
    let kind: String = row.get(2)?;
    let local_port: i64 = row.get(4)?;
    let remote_port: i64 = row.get(6)?;
    Ok(TunnelProfileRecord {
        profile: TunnelProfile {
            id: row.get(0)?,
            kind: parse_kind(&kind)?,
            local_host: row.get(3)?,
            local_port: local_port as u16,
            remote_host: row.get(5)?,
            remote_port: remote_port as u16,
        },
        session_id: row.get(1)?,
        endpoint_session_id: row.get(7)?,
    })
}

fn kind_label(kind: &TunnelKind) -> &'static str {
    match kind {
        TunnelKind::Local => "local",
        TunnelKind::Remote => "remote",
        TunnelKind::Dynamic => "dynamic",
    }
}

fn parse_kind(kind: &str) -> rusqlite::Result<TunnelKind> {
    match kind {
        "local" => Ok(TunnelKind::Local),
        "remote" => Ok(TunnelKind::Remote),
        "dynamic" => Ok(TunnelKind::Dynamic),
        _ => Err(rusqlite::Error::InvalidQuery),
    }
}

#[cfg(test)]
mod tunnel_repository_tests {
    use rusqlite::Connection;

    use crate::domain::tunnel::{TunnelKind, TunnelProfile};
    use crate::infrastructure::db::apply_migrations;

    use super::TunnelRepository;

    #[test]
    fn upserts_and_lists_tunnel_profiles_without_system_commands() {
        let repository = TunnelRepository::new(migrated_connection());
        let mut profile = profile("tun_repo_local", TunnelKind::Local);

        repository
            .upsert_profile(None, &profile)
            .expect("insert profile");
        profile.remote_port = 6432;
        repository
            .upsert_profile(None, &profile)
            .expect("update profile");

        let profiles = repository.list_profiles(None).expect("list profiles");
        let serialized = serde_json::to_string(&profiles).expect("serialize");

        assert_eq!(profiles, vec![profile]);
        assert!(!serialized.contains("ssh "));
        assert!(!serialized.contains("scp "));
        assert!(!serialized.contains("sftp "));
    }

    #[test]
    fn deletes_tunnel_profile_by_id() {
        let repository = TunnelRepository::new(migrated_connection());
        let profile = profile("tun_repo_delete", TunnelKind::Remote);
        repository
            .upsert_profile(None, &profile)
            .expect("insert profile");

        repository
            .delete_profile(&profile.id)
            .expect("delete profile");

        let profiles = repository.list_profiles(None).expect("list profiles");
        assert!(profiles.is_empty());
    }

    #[test]
    fn upserts_and_lists_tunnel_profile_records_with_endpoint_session_reference() {
        let repository = TunnelRepository::new(migrated_connection());
        insert_session(&repository.connection, "owner_session");
        insert_session(&repository.connection, "ssh_endpoint_session");
        let record = crate::domain::tunnel::TunnelProfileRecord {
            profile: profile("tun_repo_endpoint", TunnelKind::Local),
            session_id: Some("owner_session".to_string()),
            endpoint_session_id: Some("ssh_endpoint_session".to_string()),
        };

        repository
            .upsert_profile_record(&record)
            .expect("insert profile record");

        let records = repository
            .list_profile_records(Some("owner_session".to_string()))
            .expect("list records");
        let profiles = repository
            .list_profiles(Some("owner_session".to_string()))
            .expect("list profiles");

        assert_eq!(records, vec![record.clone()]);
        assert_eq!(profiles, vec![record.profile]);
        assert_eq!(
            records[0].endpoint_session_id.as_deref(),
            Some("ssh_endpoint_session")
        );
    }

    fn migrated_connection() -> Connection {
        let connection = Connection::open_in_memory().expect("open database");
        apply_migrations(&connection).expect("migrate");
        connection
    }

    fn profile(id: &str, kind: TunnelKind) -> TunnelProfile {
        TunnelProfile {
            id: id.to_string(),
            kind,
            local_host: "127.0.0.1".to_string(),
            local_port: 18080,
            remote_host: "db.internal".to_string(),
            remote_port: 5432,
        }
    }

    fn insert_session(connection: &Connection, id: &str) {
        connection
            .execute(
                "INSERT INTO sessions
                 (id, folder_id, name, protocol, host, port, username, private_key_path, config_json, environment, tags_json, credential_id, last_opened_at, created_at, updated_at)
                 VALUES (?1, NULL, ?1, 'ssh', '127.0.0.1', 22, 'ops', NULL, NULL, 'test', '[]', NULL, NULL, '2026-05-29T00:00:00Z', '2026-05-29T00:00:00Z')",
                [id],
            )
            .expect("insert session fixture");
    }
}
