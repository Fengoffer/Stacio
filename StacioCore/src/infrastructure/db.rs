use rusqlite::{params, Connection, Transaction, TransactionBehavior};

const INIT_SQL: &str = include_str!("../../migrations/0001_init.sql");
const AGENT_ACTIONS_SQL: &str = include_str!("../../migrations/0002_agent_actions.sql");
const AGENT_TASKS_SQL: &str = include_str!("../../migrations/0003_agent_tasks.sql");
const AI_CONVERSATION_HISTORY_SQL: &str =
    include_str!("../../migrations/0004_ai_conversation_history.sql");
const TERMINAL_MACROS_SQL: &str = include_str!("../../migrations/0005_terminal_macros.sql");
const SESSION_SIDEBAR_ORDER_MIGRATION_VERSION: i64 = 6;
const SESSION_SIDEBAR_ORDER_MIGRATION_NAME: &str = "session_sidebar_order";

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
        "sessions",
        "position",
        "INTEGER NOT NULL DEFAULT 0",
    )?;
    add_column_if_missing(
        connection,
        "folders",
        "position",
        "INTEGER NOT NULL DEFAULT 0",
    )?;
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
    migrate_session_sidebar_order(connection)?;
    Ok(())
}

fn migrate_session_sidebar_order(connection: &Connection) -> rusqlite::Result<()> {
    if session_sidebar_order_migration_applied(connection)? {
        return Ok(());
    }
    let transaction = Transaction::new_unchecked(connection, TransactionBehavior::Immediate)?;
    if session_sidebar_order_migration_applied(&transaction)? {
        transaction.commit()?;
        return Ok(());
    }

    // Preserve the legacy visible order while assigning one mixed position space
    // to folders and sessions in every parent container.
    const LEGACY_ITEMS_CTE: &str = "
        WITH legacy_items(kind, id, parent_key, name, type_rank) AS (
            SELECT 'session', id, COALESCE(folder_id, ''), name,
                   CASE WHEN folder_id IS NULL THEN 0 ELSE 1 END
            FROM sessions
            UNION ALL
            SELECT 'folder', id, COALESCE(parent_id, ''), name,
                   CASE WHEN parent_id IS NULL THEN 1 ELSE 0 END
            FROM folders
        ), ranked(kind, id, position) AS (
            SELECT kind, id,
                   ROW_NUMBER() OVER (
                       PARTITION BY parent_key
                       ORDER BY type_rank, name COLLATE NOCASE, id
                   ) - 1
            FROM legacy_items
        )";
    transaction.execute_batch(&format!(
        "{LEGACY_ITEMS_CTE}
         UPDATE sessions
         SET position = (
             SELECT position FROM ranked
             WHERE ranked.kind = 'session' AND ranked.id = sessions.id
         );
         {LEGACY_ITEMS_CTE}
         UPDATE folders
         SET position = (
             SELECT position FROM ranked
             WHERE ranked.kind = 'folder' AND ranked.id = folders.id
         );"
    ))?;
    transaction.execute(
        "INSERT INTO schema_migrations (version, name, applied_at)
         VALUES (?1, ?2, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))",
        params![
            SESSION_SIDEBAR_ORDER_MIGRATION_VERSION,
            SESSION_SIDEBAR_ORDER_MIGRATION_NAME
        ],
    )?;
    transaction.commit()?;
    Ok(())
}

fn session_sidebar_order_migration_applied(connection: &Connection) -> rusqlite::Result<bool> {
    connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE version = ?1)",
        params![SESSION_SIDEBAR_ORDER_MIGRATION_VERSION],
        |row| row.get(0),
    )
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
    use rusqlite::{params, Connection};

    use super::{apply_migrations, INIT_SQL, SESSION_SIDEBAR_ORDER_MIGRATION_VERSION};

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
        assert!(columns.contains(&"position".to_string()));
    }

    #[test]
    fn migrates_legacy_sidebar_items_into_one_stable_mixed_order() {
        let connection = Connection::open_in_memory().expect("open database");
        connection
            .execute_batch(INIT_SQL)
            .expect("create legacy schema");
        connection
            .execute_batch(
                "INSERT INTO folders (id, parent_id, name, position, created_at, updated_at)
                 VALUES
                    ('folder_z', NULL, 'Zulu', 0, 'now', 'now'),
                    ('folder_a', NULL, 'Alpha', 0, 'now', 'now'),
                    ('child_z', 'folder_a', 'Zulu Child', 0, 'now', 'now'),
                    ('child_a', 'folder_a', 'Alpha Child', 0, 'now', 'now');
                 INSERT INTO sessions
                    (id, folder_id, name, protocol, position, created_at, updated_at)
                 VALUES
                    ('session_z', NULL, 'Zulu Session', 'ssh', 0, 'now', 'now'),
                    ('session_a', NULL, 'Alpha Session', 'ssh', 0, 'now', 'now'),
                    ('nested_z', 'folder_a', 'Zulu Nested', 'ssh', 0, 'now', 'now'),
                    ('nested_a', 'folder_a', 'Alpha Nested', 'ssh', 0, 'now', 'now');",
            )
            .expect("insert legacy sidebar items");

        apply_migrations(&connection).expect("apply sidebar order migration");

        assert_eq!(
            sidebar_order(&connection, None),
            vec![
                "session:session_a",
                "session:session_z",
                "folder:folder_a",
                "folder:folder_z",
            ]
        );
        assert_eq!(
            sidebar_order(&connection, Some("folder_a")),
            vec![
                "folder:child_a",
                "folder:child_z",
                "session:nested_a",
                "session:nested_z",
            ]
        );
        let marker_count: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM schema_migrations WHERE version = ?1",
                params![SESSION_SIDEBAR_ORDER_MIGRATION_VERSION],
                |row| row.get(0),
            )
            .expect("query migration marker");
        assert_eq!(marker_count, 1);

        connection
            .execute_batch(
                "UPDATE folders SET position = 0 WHERE id = 'folder_z';
                 UPDATE sessions SET position = 1 WHERE id = 'session_z';
                 UPDATE folders SET position = 2 WHERE id = 'folder_a';
                 UPDATE sessions SET position = 3 WHERE id = 'session_a';",
            )
            .expect("write custom order");
        apply_migrations(&connection).expect("reapply migrations");

        assert_eq!(
            sidebar_order(&connection, None),
            vec![
                "folder:folder_z",
                "session:session_z",
                "folder:folder_a",
                "session:session_a",
            ]
        );
    }

    fn sidebar_order(connection: &Connection, parent_id: Option<&str>) -> Vec<String> {
        let mut statement = connection
            .prepare(
                "SELECT kind, id
                 FROM (
                     SELECT 'folder' AS kind, id, parent_id, position FROM folders
                     UNION ALL
                     SELECT 'session' AS kind, id, folder_id AS parent_id, position FROM sessions
                 )
                 WHERE parent_id IS ?1
                 ORDER BY position",
            )
            .expect("prepare sidebar order query");
        statement
            .query_map(params![parent_id], |row| {
                Ok(format!(
                    "{}:{}",
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?
                ))
            })
            .expect("query sidebar order")
            .collect::<Result<Vec<_>, _>>()
            .expect("collect sidebar order")
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
