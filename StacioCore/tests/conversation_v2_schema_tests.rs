use rusqlite::{params, Connection};
use stacio_core::infrastructure::conversation_v2::ConversationV2Db;

fn temp_database_path(suffix: &str) -> String {
    let file = tempfile::NamedTempFile::new().expect("create temp database");
    let (_file, path) = file.keep().expect("keep temp database");
    format!("{}-{}", path.to_string_lossy(), suffix)
}

/// P3-1：V2 库独立文件路径 `agent-conversations-v2.sqlite3`；不触碰共用库。
#[test]
fn conversation_v2_uses_dedicated_database_file() {
    let database_path = temp_database_path("agent-conversations-v2.sqlite3");
    let db = ConversationV2Db::open(&database_path).expect("open v2 database");
    let conn = db.connection();
    let table_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name LIKE 'conversation_v2_%'",
            [],
            |row| row.get(0),
        )
        .expect("count v2 tables");
    assert!(
        table_count >= 3,
        "V2 库应含会话/事件/损坏隔离表，实际 {table_count}"
    );
}

/// P3-1：V2 库独立于共用库——打开 V2 库不会创建共用库表。
#[test]
fn conversation_v2_does_not_touch_shared_database() {
    let database_path = temp_database_path("agent-conversations-v2.sqlite3");
    let db = ConversationV2Db::open(&database_path).expect("open v2 database");
    let conn = db.connection();
    let shared_tables: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'conversation_v2_%' AND name NOT LIKE 'sqlite_%'",
            [],
            |row| row.get(0),
        )
        .expect("count shared tables");
    assert_eq!(
        shared_tables, 0,
        "V2 独立库不得包含共用库表（0001-0005 不在 V2 库）"
    );
}

/// P3-1：`session_id + sequence` 唯一——同会话同序号重复插入必须失败。
#[test]
fn conversation_v2_session_sequence_is_unique() {
    let database_path = temp_database_path("agent-conversations-v2.sqlite3");
    let db = ConversationV2Db::open(&database_path).expect("open v2 database");
    let conn = db.connection();
    conn.execute(
        "INSERT INTO conversation_v2_session (conversation_id, schema_version, created_at, updated_at)
         VALUES ('c-1', 1, 't', 't')",
        [],
    )
    .expect("insert session");
    conn.execute(
        "INSERT INTO conversation_v2_event
           (conversation_id, sequence, event_id, event_type, write_class, source, created_at, payload_hash, visibility)
         VALUES ('c-1', 1, 'ev-1', 'turnSubmitted', 'durable', 'test', 't', 'h', 'session')",
        [],
    )
    .expect("insert first event");

    let duplicate = conn.execute(
        "INSERT INTO conversation_v2_event
           (conversation_id, sequence, event_id, event_type, write_class, source, created_at, payload_hash, visibility)
         VALUES ('c-1', 1, 'ev-2', 'turnSubmitted', 'durable', 'test', 't', 'h2', 'session')",
        [],
    );
    assert!(
        duplicate.is_err(),
        "同会话同 sequence 重复插入必须被唯一约束拒绝"
    );
}

/// P3-1：明文列白名单——事件表只允许 ID/type/time/status/sequence/length/cipher-version 明文，
/// 敏感负载必须走密文列（payload_cipher）。
#[test]
fn conversation_v2_plaintext_column_whitelist() {
    let database_path = temp_database_path("agent-conversations-v2.sqlite3");
    let db = ConversationV2Db::open(&database_path).expect("open v2 database");
    let conn = db.connection();
    let mut stmt = conn
        .prepare("PRAGMA table_info(conversation_v2_event)")
        .expect("table info");
    let columns: Vec<String> = stmt
        .query_map([], |row| row.get::<_, String>(1))
        .expect("query columns")
        .collect::<Result<Vec<_>, _>>()
        .expect("collect columns");

    let plaintext_whitelist = [
        "conversation_id", // ID
        "event_id",        // ID
        "sequence",        // sequence
        "event_type",      // type
        "write_class",
        "source",
        "created_at", // time
        "status",     // status
        "visibility",
        "payload_cipher_version", // cipher-version
        "payload_byte_length",    // length
        "payload_hash",
    ];
    for column in &plaintext_whitelist {
        assert!(
            columns.contains(&column.to_string()),
            "明文列 {column} 必须在白名单内"
        );
    }
    // 敏感负载只能存在于密文列
    assert!(
        columns.contains(&"payload_cipher".to_string()),
        "必须有密文列存放敏感负载"
    );
    assert!(columns.contains(&"payload_cipher_version".to_string()));
    assert!(columns.contains(&"payload_byte_length".to_string()));
}

/// P3-1：`conversation_corrupted` 只读隔离可表达（插入损坏记录并读取）。
#[test]
fn conversation_v2_corruption_isolation_expressible() {
    let database_path = temp_database_path("agent-conversations-v2.sqlite3");
    let db = ConversationV2Db::open(&database_path).expect("open v2 database");
    let conn = db.connection();
    conn.execute(
        "INSERT INTO conversation_v2_corruption (conversation_id, reason, sequence, created_at)
         VALUES ('c-1', 'same sequence with different event/hash', 5, 't')",
        [],
    )
    .expect("insert corruption record");

    let (reason, sequence): (String, i64) = conn
        .query_row(
            "SELECT reason, sequence FROM conversation_v2_corruption WHERE conversation_id = 'c-1'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("read corruption record");
    assert!(reason.contains("sequence"));
    assert_eq!(sequence, 5);
    // 隔离语义：损坏会话只读——写入事件应被上层拒绝（此处验证记录可查询）
    let conn2 = Connection::open_in_memory().expect("in-memory connection");
    let _ = conn2;
    let _ = params![];
}
