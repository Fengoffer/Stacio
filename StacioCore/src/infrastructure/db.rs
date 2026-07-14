use rusqlite::Connection;

const INIT_SQL: &str = include_str!("../../migrations/0001_init.sql");
const AGENT_ACTIONS_SQL: &str = include_str!("../../migrations/0002_agent_actions.sql");
const AGENT_TASKS_SQL: &str = include_str!("../../migrations/0003_agent_tasks.sql");
const AI_CONVERSATION_HISTORY_SQL: &str =
    include_str!("../../migrations/0004_ai_conversation_history.sql");
const TERMINAL_MACROS_SQL: &str = include_str!("../../migrations/0005_terminal_macros.sql");

pub fn configure_connection(connection: &Connection) -> rusqlite::Result<()> {
    connection.pragma_update(None, "journal_mode", "WAL")?;
    connection.pragma_update(None, "foreign_keys", "ON")?;
    connection.pragma_update(None, "synchronous", "NORMAL")?;
    connection.busy_timeout(std::time::Duration::from_millis(5_000))?;
    Ok(())
}

pub fn apply_migrations(connection: &Connection) -> rusqlite::Result<()> {
    configure_connection(connection)?;
    connection.execute_batch(INIT_SQL)?;
    connection.execute_batch(AGENT_ACTIONS_SQL)?;
    connection.execute_batch(AGENT_TASKS_SQL)?;
    connection.execute_batch(AI_CONVERSATION_HISTORY_SQL)?;
    connection.execute_batch(TERMINAL_MACROS_SQL)?;
    add_column_if_missing(connection, "sessions", "last_opened_at", "TEXT")?;
    add_column_if_missing(connection, "sessions", "config_json", "TEXT")?;
    add_column_if_missing(
        connection,
        "tunnels",
        "endpoint_session_id",
        "TEXT REFERENCES sessions(id) ON DELETE SET NULL",
    )?;
    add_column_if_missing(
        connection,
        "audit_events",
        "target_count",
        "INTEGER NOT NULL DEFAULT 0",
    )?;
    add_column_if_missing(
        connection,
        "audit_events",
        "sent_count",
        "INTEGER NOT NULL DEFAULT 0",
    )?;
    add_column_if_missing(
        connection,
        "audit_events",
        "failed_count",
        "INTEGER NOT NULL DEFAULT 0",
    )?;
    add_column_if_missing(
        connection,
        "audit_events",
        "redacted_input",
        "TEXT NOT NULL DEFAULT ''",
    )?;
    add_column_if_missing(
        connection,
        "audit_events",
        "executed",
        "INTEGER NOT NULL DEFAULT 0",
    )?;
    add_column_if_missing(
        connection,
        "agent_action_events",
        "environment",
        "TEXT NOT NULL DEFAULT 'unknown'",
    )?;
    add_column_if_missing(
        connection,
        "agent_action_events",
        "approval_mode",
        "TEXT NOT NULL DEFAULT 'unknown'",
    )?;
    add_column_if_missing(
        connection,
        "agent_action_events",
        "policy_decision",
        "TEXT NOT NULL DEFAULT 'unknown'",
    )?;
    add_column_if_missing(
        connection,
        "agent_action_events",
        "redaction_version",
        "TEXT NOT NULL DEFAULT 'stacio.agent-redaction.v1'",
    )?;
    Ok(())
}

fn add_column_if_missing(
    connection: &Connection,
    table: &str,
    column: &str,
    column_definition: &str,
) -> rusqlite::Result<()> {
    let mut statement = connection.prepare(&format!("PRAGMA table_info({table})"))?;
    let columns = statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<Vec<_>, _>>()?;
    if columns.iter().any(|existing| existing == column) {
        return Ok(());
    }

    connection.execute(
        &format!("ALTER TABLE {table} ADD COLUMN {column} {column_definition}"),
        [],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use rusqlite::Connection;

    use super::apply_migrations;

    #[test]
    fn creates_foundation_tables() {
        let connection = Connection::open_in_memory().expect("open database");

        apply_migrations(&connection).expect("apply migrations");

        let mut statement = connection
            .prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
            .expect("prepare table query");
        let tables = statement
            .query_map([], |row| row.get::<_, String>(0))
            .expect("query tables")
            .collect::<Result<Vec<_>, _>>()
            .expect("collect tables");

        assert!(tables.contains(&"schema_migrations".to_string()));
        assert!(tables.contains(&"folders".to_string()));
        assert!(tables.contains(&"sessions".to_string()));
        assert!(tables.contains(&"credentials".to_string()));
        assert!(tables.contains(&"known_hosts".to_string()));
        assert!(tables.contains(&"tunnels".to_string()));
        assert!(tables.contains(&"transfer_jobs".to_string()));
        assert!(tables.contains(&"transfer_events".to_string()));
        assert!(tables.contains(&"import_reports".to_string()));
        assert!(tables.contains(&"settings".to_string()));
        assert!(tables.contains(&"audit_events".to_string()));
        assert!(tables.contains(&"agent_action_events".to_string()));
        assert!(tables.contains(&"agent_task_sessions".to_string()));
        assert!(tables.contains(&"agent_task_proposals".to_string()));
        assert!(tables.contains(&"ai_conversation_history".to_string()));
        assert!(tables.contains(&"terminal_macros".to_string()));
    }

    #[test]
    fn upgrades_existing_sessions_table_with_session_runtime_columns() {
        let connection = Connection::open_in_memory().expect("open database");
        connection
            .execute_batch(
                "CREATE TABLE sessions (
                    id TEXT PRIMARY KEY NOT NULL,
                    folder_id TEXT,
                    name TEXT NOT NULL,
                    protocol TEXT NOT NULL,
                    host TEXT,
                    port INTEGER,
                    username TEXT,
                    private_key_path TEXT,
                    environment TEXT NOT NULL DEFAULT 'unknown',
                    tags_json TEXT NOT NULL DEFAULT '[]',
                    credential_id TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );",
            )
            .expect("create legacy sessions table");

        apply_migrations(&connection).expect("apply migrations");

        let columns = connection
            .prepare("PRAGMA table_info(sessions)")
            .expect("prepare columns")
            .query_map([], |row| row.get::<_, String>(1))
            .expect("query columns")
            .collect::<Result<Vec<_>, _>>()
            .expect("collect columns");

        assert!(columns.contains(&"last_opened_at".to_string()));
        assert!(columns.contains(&"config_json".to_string()));
    }

    #[test]
    fn upgrades_existing_tunnels_table_with_endpoint_session_reference() {
        let connection = Connection::open_in_memory().expect("open database");
        connection
            .execute_batch(
                "CREATE TABLE tunnels (
                    id TEXT PRIMARY KEY NOT NULL,
                    session_id TEXT,
                    kind TEXT NOT NULL,
                    local_host TEXT NOT NULL,
                    local_port INTEGER NOT NULL,
                    remote_host TEXT NOT NULL,
                    remote_port INTEGER NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );",
            )
            .expect("create legacy tunnels table");

        apply_migrations(&connection).expect("apply migrations");

        let columns = connection
            .prepare("PRAGMA table_info(tunnels)")
            .expect("prepare columns")
            .query_map([], |row| row.get::<_, String>(1))
            .expect("query columns")
            .collect::<Result<Vec<_>, _>>()
            .expect("collect columns");

        assert!(columns.contains(&"endpoint_session_id".to_string()));
    }

    #[test]
    fn upgrades_existing_audit_events_table_with_broadcast_columns() {
        let connection = Connection::open_in_memory().expect("open database");
        connection
            .execute_batch(
                "CREATE TABLE audit_events (
                    id TEXT PRIMARY KEY NOT NULL,
                    trace_id TEXT NOT NULL,
                    event_type TEXT NOT NULL,
                    severity TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );",
            )
            .expect("create legacy audit table");

        apply_migrations(&connection).expect("apply migrations");

        let columns = connection
            .prepare("PRAGMA table_info(audit_events)")
            .expect("prepare columns")
            .query_map([], |row| row.get::<_, String>(1))
            .expect("query columns")
            .collect::<Result<Vec<_>, _>>()
            .expect("collect columns");

        assert!(columns.contains(&"target_count".to_string()));
        assert!(columns.contains(&"sent_count".to_string()));
        assert!(columns.contains(&"failed_count".to_string()));
        assert!(columns.contains(&"redacted_input".to_string()));
        assert!(columns.contains(&"executed".to_string()));
    }

    #[test]
    fn agent_action_events_table_is_created_by_migrations() {
        let connection = Connection::open_in_memory().expect("open database");

        apply_migrations(&connection).expect("apply migrations");

        let exists: i64 = connection
            .query_row(
                "SELECT COUNT(*)
                 FROM sqlite_master
                 WHERE type = 'table' AND name = 'agent_action_events'",
                [],
                |row| row.get(0),
            )
            .expect("query agent action table");

        assert_eq!(exists, 1);
    }

    #[test]
    fn upgrades_existing_agent_action_events_table_with_policy_columns() {
        let connection = Connection::open_in_memory().expect("open database");
        connection
            .execute_batch(
                "CREATE TABLE agent_action_events (
                    id TEXT PRIMARY KEY NOT NULL,
                    request_id TEXT NOT NULL,
                    actor_kind TEXT NOT NULL,
                    actor_name TEXT NOT NULL,
                    target_runtime_id TEXT,
                    target_title TEXT NOT NULL,
                    action_kind TEXT NOT NULL,
                    risk TEXT NOT NULL,
                    state TEXT NOT NULL,
                    redacted_input TEXT NOT NULL DEFAULT '',
                    created_at TEXT NOT NULL
                );",
            )
            .expect("create legacy agent action table");

        apply_migrations(&connection).expect("apply migrations");

        let columns = connection
            .prepare("PRAGMA table_info(agent_action_events)")
            .expect("prepare columns")
            .query_map([], |row| row.get::<_, String>(1))
            .expect("query columns")
            .collect::<Result<Vec<_>, _>>()
            .expect("collect columns");

        assert!(columns.contains(&"environment".to_string()));
        assert!(columns.contains(&"approval_mode".to_string()));
        assert!(columns.contains(&"policy_decision".to_string()));
        assert!(columns.contains(&"redaction_version".to_string()));
    }
}
