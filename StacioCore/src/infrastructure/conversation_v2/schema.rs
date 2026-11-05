use rusqlite::Connection;
use std::sync::{Arc, Mutex};

const V2_INIT_SQL: &str = include_str!("../../../migrations/conversation_v2_0001_init.sql");
const V2_REPOSITORY_SQL: &str =
    include_str!("../../../migrations/conversation_v2_0002_repository.sql");
const V2_ADMISSION_SQL: &str =
    include_str!("../../../migrations/conversation_v2_0003_admission.sql");
const V2_COMPACTION_SQL: &str =
    include_str!("../../../migrations/conversation_v2_0004_compaction.sql");
const V2_OUTBOX_DISPATCH_SQL: &str =
    include_str!("../../../migrations/conversation_v2_0005_outbox_dispatch.sql");
const V2_ADMISSION_RUNTIME_SQL: &str =
    include_str!("../../../migrations/conversation_v2_0006_admission_runtime.sql");

/// V2 独立加密会话库句柄（`agent-conversations-v2.sqlite3`）。
///
/// 物理存储边界（规格 §15.1）：与共用库完全隔离——本句柄只应用 `conversation_v2_*`
/// 迁移集，绝不触碰共用库 0001-0005 表；settings/configuration/credential 权威表
/// 位于独立存储域，本库只保存跨域引用/投影。
pub struct ConversationV2Db {
    connection: Arc<Mutex<Connection>>,
    path: String,
}

impl ConversationV2Db {
    /// 打开（必要时创建）V2 独立库并应用迁移集。
    pub fn open(path: &str) -> rusqlite::Result<Self> {
        let connection = Connection::open(path)?;
        let db = Self {
            connection: Arc::new(Mutex::new(connection)),
            path: path.to_string(),
        };
        db.apply_migrations()?;
        Ok(db)
    }

    /// 内存库（测试用）。
    pub fn open_in_memory() -> rusqlite::Result<Self> {
        let connection = Connection::open_in_memory()?;
        let db = Self {
            connection: Arc::new(Mutex::new(connection)),
            path: ":memory:".to_string(),
        };
        db.apply_migrations()?;
        Ok(db)
    }

    pub fn path(&self) -> &str {
        &self.path
    }

    /// 仅供 Repository 层在同一事务内使用；不对外暴露裸 Connection 写入。
    pub fn connection(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.connection.lock().expect("v2 db connection poisoned")
    }

    /// 共享连接（Repository 与 Db 同库同连接）。
    pub fn connection_arc(&self) -> Arc<Mutex<Connection>> {
        Arc::clone(&self.connection)
    }

    fn apply_migrations(&self) -> rusqlite::Result<()> {
        let connection = self.connection();
        configure_connection(&connection)?;
        connection.execute_batch(V2_INIT_SQL)?;
        connection.execute_batch(V2_REPOSITORY_SQL)?;
        connection.execute_batch(V2_ADMISSION_SQL)?;
        connection.execute_batch(V2_COMPACTION_SQL)?;
        connection.execute_batch(V2_OUTBOX_DISPATCH_SQL)?;
        connection.execute_batch(V2_ADMISSION_RUNTIME_SQL)
    }
}

fn configure_connection(connection: &Connection) -> rusqlite::Result<()> {
    connection.pragma_update(None, "journal_mode", "WAL")?;
    connection.pragma_update(None, "foreign_keys", "ON")?;
    connection.pragma_update(None, "synchronous", "NORMAL")?;
    connection.busy_timeout(std::time::Duration::from_millis(5_000))?;
    Ok(())
}
