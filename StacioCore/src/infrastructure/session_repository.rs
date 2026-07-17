use std::collections::HashSet;

use chrono::Utc;
use rusqlite::{
    params, params_from_iter, Connection, OptionalExtension, Transaction, TransactionBehavior,
};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::domain::{
    serial::{validate_serial_config, SerialConnectionConfig},
    session::{
        SessionDraft, SessionError, SessionFolder, SessionIconAssignment, SessionRecord,
        SessionSidebarOrderItem, SessionSidebarSnapshot, SessionUpdate,
    },
};

const SESSION_COLUMNS: &str = "id, folder_id, name, protocol, host, port, username, private_key_path, credential_id, tags_json, last_opened_at";

pub struct SessionRepository {
    connection: Connection,
}

impl SessionRepository {
    pub fn new(connection: Connection) -> Self {
        Self { connection }
    }

    pub fn create_folder(
        &self,
        parent_id: Option<String>,
        name: &str,
    ) -> Result<SessionFolder, SessionError> {
        let name = name.trim();
        if name.is_empty() {
            return Err(SessionError::InvalidQuickConnect);
        }
        let folder = SessionFolder {
            id: Uuid::new_v4().to_string(),
            parent_id,
            name: name.to_string(),
        };
        let now = Utc::now().to_rfc3339();
        let transaction =
            Transaction::new_unchecked(&self.connection, TransactionBehavior::Immediate)?;
        let position = next_sidebar_position(&transaction, folder.parent_id.as_deref())?;

        transaction.execute(
            "INSERT INTO folders (id, parent_id, name, position, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?5)",
            params![folder.id, folder.parent_id, folder.name, position, now],
        )?;
        transaction.commit()?;

        Ok(folder)
    }

    pub fn rename_folder(&self, id: String, name: &str) -> Result<SessionFolder, SessionError> {
        let name = name.trim();
        if name.is_empty() {
            return Err(SessionError::InvalidQuickConnect);
        }
        let now = Utc::now().to_rfc3339();
        let changed = self.connection.execute(
            "UPDATE folders SET name = ?2, updated_at = ?3 WHERE id = ?1",
            params![id.as_str(), name, now],
        )?;
        if changed == 0 {
            return Err(SessionError::NotFound);
        }

        self.get_folder(&id)?.ok_or(SessionError::NotFound)
    }

    pub fn delete_folder(&self, id: String) -> Result<(), SessionError> {
        let transaction =
            Transaction::new_unchecked(&self.connection, TransactionBehavior::Immediate)?;
        let parent_id = transaction
            .query_row(
                "SELECT parent_id FROM folders WHERE id = ?1",
                params![id.as_str()],
                |row| row.get::<_, Option<String>>(0),
            )
            .optional()?;
        let Some(parent_id) = parent_id else {
            return Err(SessionError::NotFound);
        };
        let root_items_before = sidebar_items_for_parent(&transaction, None)?;
        let mut moved_sessions = Vec::new();
        collect_folder_subtree_sessions(
            &transaction,
            &id,
            &mut HashSet::new(),
            &mut moved_sessions,
        )?;

        let changed = transaction.execute("DELETE FROM folders WHERE id = ?1", params![id])?;
        if changed == 0 {
            return Err(SessionError::NotFound);
        }
        let mut root_items = root_items_before
            .into_iter()
            .filter(|item| item.kind != "folder" || item.id != id)
            .collect::<Vec<_>>();
        root_items.extend(moved_sessions.into_iter().map(|mut session| {
            session.parent_id = None;
            session
        }));
        rewrite_sidebar_positions(&transaction, &root_items)?;
        if let Some(parent_id) = parent_id.as_deref() {
            let parent_items = sidebar_items_for_parent(&transaction, Some(parent_id))?;
            rewrite_sidebar_positions(&transaction, &parent_items)?;
        }
        transaction.commit()?;
        Ok(())
    }

    pub fn list_folders(&self) -> Result<Vec<SessionFolder>, SessionError> {
        let mut statement = self.connection.prepare(
            "SELECT id, parent_id, name
             FROM folders
             ORDER BY parent_id IS NOT NULL, COALESCE(parent_id, ''), position,
                      name COLLATE NOCASE, id",
        )?;
        let folders = statement
            .query_map([], read_folder)?
            .collect::<Result<Vec<_>, _>>()?;

        Ok(folders)
    }

    pub fn create_session(&self, draft: SessionDraft) -> Result<SessionRecord, SessionError> {
        let config_json_override = draft.config_json.clone();
        let session = SessionRecord {
            id: Uuid::new_v4().to_string(),
            folder_id: draft.folder_id,
            name: draft.name,
            protocol: draft.protocol,
            host: draft.host,
            port: draft.port,
            username: draft.username,
            private_key_path: draft.private_key_path,
            credential_id: draft.credential_id,
            tags: draft.tags,
            last_opened_at: None,
        };
        let now = Utc::now().to_rfc3339();
        let tags_json =
            serde_json::to_string(&session.tags).map_err(|error| SessionError::Database {
                message: error.to_string(),
            })?;
        let config_json = protocol_config_json_for_session_with_override(
            &session,
            config_json_override.as_deref(),
        )?;
        let transaction =
            Transaction::new_unchecked(&self.connection, TransactionBehavior::Immediate)?;
        let position = next_sidebar_position(&transaction, session.folder_id.as_deref())?;

        transaction.execute(
            "INSERT INTO sessions
             (id, folder_id, name, protocol, host, port, username, private_key_path, credential_id, tags_json, config_json, position, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?13)",
            params![
                session.id,
                session.folder_id,
                session.name,
                session.protocol,
                session.host,
                i64::from(session.port),
                session.username,
                session.private_key_path,
                session.credential_id,
                tags_json,
                config_json,
                position,
                now
            ],
        )?;
        transaction.commit()?;

        Ok(session)
    }

    pub fn list_sessions(
        &self,
        folder_id: Option<String>,
    ) -> Result<Vec<SessionRecord>, SessionError> {
        if let Some(folder_id) = folder_id {
            self.query_sessions(
                &format!(
                    "SELECT {SESSION_COLUMNS}
                     FROM sessions WHERE folder_id = ?1
                     ORDER BY position, name COLLATE NOCASE, id"
                ),
                params![folder_id],
            )
        } else {
            self.query_sessions(
                &format!(
                    "SELECT {SESSION_COLUMNS}
                     FROM sessions WHERE folder_id IS NULL
                     ORDER BY position, name COLLATE NOCASE, id"
                ),
                [],
            )
        }
    }

    pub fn list_all_sessions(&self) -> Result<Vec<SessionRecord>, SessionError> {
        self.query_sessions(
            &format!("SELECT {SESSION_COLUMNS} FROM sessions ORDER BY name COLLATE NOCASE, id"),
            [],
        )
    }

    pub fn list_session_sidebar_order(&self) -> Result<Vec<SessionSidebarOrderItem>, SessionError> {
        let mut statement = self.connection.prepare(
            "SELECT kind, id, parent_id
             FROM (
                 SELECT 'folder' AS kind, id, parent_id, position, name
                 FROM folders
                 UNION ALL
                 SELECT 'session' AS kind, id, folder_id AS parent_id, position, name
                 FROM sessions
             )
             ORDER BY parent_id IS NOT NULL, COALESCE(parent_id, ''), position,
                      CASE
                          WHEN parent_id IS NULL AND kind = 'session' THEN 0
                          WHEN parent_id IS NULL THEN 1
                          WHEN kind = 'folder' THEN 0
                          ELSE 1
                      END,
                      name COLLATE NOCASE, id",
        )?;
        let items = statement
            .query_map([], read_sidebar_order_item)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(SessionError::from)?;
        Ok(items)
    }

    pub fn load_session_sidebar_snapshot(&self) -> Result<SessionSidebarSnapshot, SessionError> {
        Ok(SessionSidebarSnapshot {
            folders: self.list_folders()?,
            sessions: self.list_all_sessions()?,
            order_items: self.list_session_sidebar_order()?,
            manual_icon_assignments: self.list_session_icon_assignments()?,
        })
    }

    fn list_session_icon_assignments(&self) -> Result<Vec<SessionIconAssignment>, SessionError> {
        let mut statement = self.connection.prepare(
            "SELECT id, config_json
             FROM sessions
             WHERE LOWER(TRIM(protocol)) IN ('ssh', 'scp')
             ORDER BY id",
        )?;
        let rows = statement.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?))
        })?;
        let mut assignments = Vec::new();
        for row in rows {
            let (session_id, config_json) = row?;
            if let Some(icon_id) = safe_session_icon_id(config_json.as_deref()) {
                assignments.push(SessionIconAssignment {
                    session_id,
                    icon_id,
                });
            }
        }
        Ok(assignments)
    }

    pub fn mark_session_opened(&self, id: String) -> Result<SessionRecord, SessionError> {
        let now = Utc::now().to_rfc3339();
        let changed = self.connection.execute(
            "UPDATE sessions
             SET last_opened_at = ?2, updated_at = ?2
             WHERE id = ?1",
            params![id.as_str(), now.as_str()],
        )?;
        if changed == 0 {
            return Err(SessionError::NotFound);
        }

        self.get_session(&id)?.ok_or(SessionError::NotFound)
    }

    pub fn update_session(
        &self,
        id: String,
        update: SessionUpdate,
    ) -> Result<SessionRecord, SessionError> {
        let existing_config_json: Option<String> = self
            .connection
            .query_row(
                "SELECT config_json FROM sessions WHERE id = ?1",
                params![id.as_str()],
                |row| row.get(0),
            )
            .optional()?
            .flatten();
        let mut current = self.get_session(&id)?.ok_or(SessionError::NotFound)?;
        let original_folder_id = current.folder_id.clone();
        let current_position = self.connection.query_row(
            "SELECT position FROM sessions WHERE id = ?1",
            params![id.as_str()],
            |row| row.get::<_, i64>(0),
        )?;
        if let Some(name) = update.name {
            current.name = name;
        }
        if let Some(protocol) = update.protocol {
            current.protocol = protocol;
        }
        if let Some(folder_id) = update.folder_id {
            current.folder_id = Some(folder_id);
        }
        if let Some(host) = update.host {
            current.host = host;
        }
        if let Some(port) = update.port {
            current.port = port;
        }
        if let Some(username) = update.username {
            current.username = non_empty_optional(username);
        }
        if let Some(private_key_path) = update.private_key_path {
            current.private_key_path = non_empty_optional(private_key_path);
        }
        if let Some(credential_id) = update.credential_id {
            current.credential_id = non_empty_optional(credential_id);
        }
        if let Some(tags) = update.tags {
            current.tags = tags;
        }
        let config_json_override = update.config_json.or(existing_config_json);

        let tags_json =
            serde_json::to_string(&current.tags).map_err(|error| SessionError::Database {
                message: error.to_string(),
            })?;
        let config_json = protocol_config_json_for_session_with_override(
            &current,
            config_json_override.as_deref(),
        )?;
        let position = if current.folder_id == original_folder_id {
            current_position
        } else {
            next_sidebar_position(&self.connection, current.folder_id.as_deref())?
        };
        let now = Utc::now().to_rfc3339();

        self.connection.execute(
            "UPDATE sessions
             SET folder_id = ?2, name = ?3, protocol = ?4, host = ?5, port = ?6, username = ?7, private_key_path = ?8, credential_id = ?9, tags_json = ?10, config_json = ?11, position = ?12, updated_at = ?13
             WHERE id = ?1",
            params![
                current.id,
                current.folder_id,
                current.name,
                current.protocol,
                current.host,
                i64::from(current.port),
                current.username,
                current.private_key_path,
                current.credential_id,
                tags_json,
                config_json,
                position,
                now
            ],
        )?;

        Ok(current)
    }

    pub fn delete_session(&self, id: String) -> Result<(), SessionError> {
        let transaction =
            Transaction::new_unchecked(&self.connection, TransactionBehavior::Immediate)?;
        let parent_id = transaction
            .query_row(
                "SELECT folder_id FROM sessions WHERE id = ?1",
                params![id.as_str()],
                |row| row.get::<_, Option<String>>(0),
            )
            .optional()?;
        let Some(parent_id) = parent_id else {
            transaction.commit()?;
            return Ok(());
        };
        transaction.execute("DELETE FROM sessions WHERE id = ?1", params![id])?;
        let remaining = sidebar_items_for_parent(&transaction, parent_id.as_deref())?;
        rewrite_sidebar_positions(&transaction, &remaining)?;
        transaction.commit()?;
        Ok(())
    }

    pub fn duplicate_session(
        &self,
        id: String,
        target_folder_id: Option<String>,
    ) -> Result<SessionRecord, SessionError> {
        let source = self.get_session(&id)?.ok_or(SessionError::NotFound)?;
        let config_json = self.get_session_config_json(&id)?;
        self.create_session(SessionDraft {
            folder_id: target_folder_id,
            name: self.next_duplicate_name(&source.name)?,
            protocol: source.protocol,
            host: source.host,
            port: source.port,
            username: source.username,
            private_key_path: source.private_key_path,
            credential_id: source.credential_id,
            tags: source.tags,
            config_json,
        })
    }

    pub fn move_session(
        &self,
        id: String,
        target_folder_id: Option<String>,
    ) -> Result<SessionRecord, SessionError> {
        let current = self.get_session(&id)?.ok_or(SessionError::NotFound)?;
        if current.folder_id == target_folder_id {
            return Ok(current);
        }
        self.place_session_sidebar_item(
            "session".to_string(),
            id.clone(),
            target_folder_id,
            u32::MAX,
        )?;
        self.get_session(&id)?.ok_or(SessionError::NotFound)
    }

    pub fn place_session_sidebar_item(
        &self,
        kind: String,
        id: String,
        target_parent_id: Option<String>,
        target_index: u32,
    ) -> Result<SessionSidebarOrderItem, SessionError> {
        let kind = normalized_sidebar_kind(&kind)?;
        let transaction =
            Transaction::new_unchecked(&self.connection, TransactionBehavior::Immediate)?;
        let source_parent_id = sidebar_parent_for_item(&transaction, kind, &id)?;

        if kind == "folder" && source_parent_id != target_parent_id {
            return Err(invalid_sidebar_placement(
                "folders can only be reordered inside their current parent",
            ));
        }
        if kind == "session" {
            validate_sidebar_parent(&transaction, target_parent_id.as_deref())?;
        }

        let mut source_items = sidebar_items_for_parent(&transaction, source_parent_id.as_deref())?;
        source_items.retain(|item| item.kind != kind || item.id != id);
        let same_parent = source_parent_id == target_parent_id;
        let mut target_items = if same_parent {
            source_items.clone()
        } else {
            sidebar_items_for_parent(&transaction, target_parent_id.as_deref())?
        };
        let insertion_index = usize::try_from(target_index)
            .unwrap_or(usize::MAX)
            .min(target_items.len());
        let placed = SessionSidebarOrderItem {
            kind: kind.to_string(),
            id: id.clone(),
            parent_id: target_parent_id.clone(),
        };
        target_items.insert(insertion_index, placed.clone());

        if kind == "session" {
            transaction.execute(
                "UPDATE sessions SET folder_id = ?2, updated_at = ?3 WHERE id = ?1",
                params![id.as_str(), target_parent_id, Utc::now().to_rfc3339()],
            )?;
        }
        if !same_parent {
            rewrite_sidebar_positions(&transaction, &source_items)?;
        }
        rewrite_sidebar_positions(&transaction, &target_items)?;
        transaction.commit()?;
        Ok(placed)
    }

    pub fn export_sessions_without_secrets(&self) -> Result<Vec<SessionRecord>, SessionError> {
        self.list_all_sessions()
    }

    pub fn export_sessions_json(&self) -> Result<String, SessionError> {
        let sessions = self.export_session_records(self.export_sessions_without_secrets()?)?;
        let bundle = SessionExportBundle {
            format: "stacio.sessions.v1".to_string(),
            exported_at: Utc::now().to_rfc3339(),
            folders: self.list_folders()?,
            sessions,
        };
        serde_json::to_string_pretty(&bundle).map_err(|error| SessionError::Database {
            message: error.to_string(),
        })
    }

    pub fn export_folder_sessions_json(&self, folder_id: String) -> Result<String, SessionError> {
        let folders = self.list_folder_subtree(&folder_id)?;
        if folders.is_empty() {
            return Err(SessionError::NotFound);
        }
        let folder_ids = folders
            .iter()
            .map(|folder| folder.id.clone())
            .collect::<Vec<_>>();
        let sessions =
            self.export_session_records(self.list_sessions_for_folder_ids(&folder_ids)?)?;
        let bundle = SessionExportBundle {
            format: "stacio.sessions.v1".to_string(),
            exported_at: Utc::now().to_rfc3339(),
            folders,
            sessions,
        };
        serde_json::to_string_pretty(&bundle).map_err(|error| SessionError::Database {
            message: error.to_string(),
        })
    }

    fn export_session_records(
        &self,
        sessions: Vec<SessionRecord>,
    ) -> Result<Vec<SessionExportRecord>, SessionError> {
        sessions
            .into_iter()
            .map(|session| {
                let stored_config_json = self.get_session_config_json(&session.id)?;
                let config_json = export_safe_config_json(stored_config_json.as_deref());
                Ok(SessionExportRecord {
                    session,
                    config_json,
                })
            })
            .collect()
    }

    pub fn get_session_config_json(&self, id: &str) -> Result<Option<String>, SessionError> {
        let row = self
            .connection
            .query_row(
                "SELECT protocol, host, port, username, private_key_path, config_json
                 FROM sessions WHERE id = ?1",
                params![id],
                |row| {
                    let port: i64 = row.get(2)?;
                    let session = SessionRecord {
                        id: id.to_string(),
                        folder_id: None,
                        name: String::new(),
                        protocol: row.get(0)?,
                        host: row.get(1)?,
                        port: port as u32,
                        username: row.get(3)?,
                        private_key_path: row.get(4)?,
                        credential_id: None,
                        tags: vec![],
                        last_opened_at: None,
                    };
                    let config_json = row.get::<_, Option<String>>(5)?;
                    Ok((session, config_json))
                },
            )
            .optional()?;

        match row {
            Some((_session, Some(config_json))) if !config_json.trim().is_empty() => {
                Ok(Some(config_json))
            }
            Some((session, _)) => protocol_config_json_for_session(&session),
            None => Err(SessionError::NotFound),
        }
    }

    fn get_session(&self, id: &str) -> Result<Option<SessionRecord>, SessionError> {
        self.connection
            .query_row(
                &format!("SELECT {SESSION_COLUMNS} FROM sessions WHERE id = ?1"),
                params![id],
                read_session,
            )
            .optional()
            .map_err(SessionError::from)
    }

    fn get_folder(&self, id: &str) -> Result<Option<SessionFolder>, SessionError> {
        self.connection
            .query_row(
                "SELECT id, parent_id, name FROM folders WHERE id = ?1",
                params![id],
                read_folder,
            )
            .optional()
            .map_err(SessionError::from)
    }

    fn list_folder_subtree(&self, folder_id: &str) -> Result<Vec<SessionFolder>, SessionError> {
        let mut statement = self.connection.prepare(
            "WITH RECURSIVE folder_tree(id, parent_id, name, position, depth) AS (
                 SELECT id, parent_id, name, position, 0 FROM folders WHERE id = ?1
                 UNION ALL
                 SELECT folders.id, folders.parent_id, folders.name, folders.position,
                        folder_tree.depth + 1
                 FROM folders
                 JOIN folder_tree ON folders.parent_id = folder_tree.id
             )
             SELECT id, parent_id, name
             FROM folder_tree
             ORDER BY depth, COALESCE(parent_id, ''), position, name COLLATE NOCASE, id",
        )?;
        let folders = statement
            .query_map(params![folder_id], read_folder)?
            .collect::<Result<Vec<_>, _>>()?;

        Ok(folders)
    }

    fn list_sessions_for_folder_ids(
        &self,
        folder_ids: &[String],
    ) -> Result<Vec<SessionRecord>, SessionError> {
        if folder_ids.is_empty() {
            return Ok(vec![]);
        }
        let placeholders = std::iter::repeat("?")
            .take(folder_ids.len())
            .collect::<Vec<_>>()
            .join(", ");
        self.query_sessions(
            &format!(
                "SELECT {SESSION_COLUMNS}
                 FROM sessions
                 WHERE folder_id IN ({placeholders})
                 ORDER BY folder_id, position, name COLLATE NOCASE, id"
            ),
            params_from_iter(folder_ids.iter()),
        )
    }

    fn query_sessions<P>(&self, sql: &str, params: P) -> Result<Vec<SessionRecord>, SessionError>
    where
        P: rusqlite::Params,
    {
        let mut statement = self.connection.prepare(sql)?;
        let sessions = statement
            .query_map(params, read_session)?
            .collect::<Result<Vec<_>, _>>()?;

        Ok(sessions)
    }

    fn next_duplicate_name(&self, source_name: &str) -> Result<String, SessionError> {
        let existing_names = self
            .list_all_sessions()?
            .into_iter()
            .map(|session| session.name.to_ascii_lowercase())
            .collect::<std::collections::HashSet<_>>();
        let base = format!("{} 副本", source_name.trim());
        if !existing_names.contains(&base.to_ascii_lowercase()) {
            return Ok(base);
        }

        for index in 2.. {
            let candidate = format!("{base} {index}");
            if !existing_names.contains(&candidate.to_ascii_lowercase()) {
                return Ok(candidate);
            }
        }

        unreachable!("unbounded duplicate suffix search should always return")
    }
}

fn normalized_sidebar_kind(kind: &str) -> Result<&'static str, SessionError> {
    match kind.trim().to_ascii_lowercase().as_str() {
        "folder" => Ok("folder"),
        "session" => Ok("session"),
        _ => Err(invalid_sidebar_placement("unsupported sidebar item kind")),
    }
}

fn invalid_sidebar_placement(message: &str) -> SessionError {
    SessionError::Database {
        message: message.to_string(),
    }
}

fn validate_sidebar_parent(
    connection: &Connection,
    parent_id: Option<&str>,
) -> Result<(), SessionError> {
    let Some(parent_id) = parent_id else {
        return Ok(());
    };
    let exists = connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM folders WHERE id = ?1)",
        params![parent_id],
        |row| row.get::<_, bool>(0),
    )?;
    if exists {
        Ok(())
    } else {
        Err(SessionError::NotFound)
    }
}

fn sidebar_parent_for_item(
    connection: &Connection,
    kind: &str,
    id: &str,
) -> Result<Option<String>, SessionError> {
    let sql = match kind {
        "folder" => "SELECT parent_id FROM folders WHERE id = ?1",
        "session" => "SELECT folder_id FROM sessions WHERE id = ?1",
        _ => return Err(invalid_sidebar_placement("unsupported sidebar item kind")),
    };
    connection
        .query_row(sql, params![id], |row| row.get::<_, Option<String>>(0))
        .optional()?
        .ok_or(SessionError::NotFound)
}

fn next_sidebar_position(
    connection: &Connection,
    parent_id: Option<&str>,
) -> Result<i64, SessionError> {
    connection
        .query_row(
            "SELECT COALESCE(MAX(position), -1) + 1
             FROM (
                 SELECT position FROM folders WHERE parent_id IS ?1
                 UNION ALL
                 SELECT position FROM sessions WHERE folder_id IS ?1
             )",
            params![parent_id],
            |row| row.get(0),
        )
        .map_err(SessionError::from)
}

fn sidebar_items_for_parent(
    connection: &Connection,
    parent_id: Option<&str>,
) -> Result<Vec<SessionSidebarOrderItem>, SessionError> {
    let mut statement = connection.prepare(
        "SELECT kind, id, parent_id
         FROM (
             SELECT 'folder' AS kind, id, parent_id, position, name
             FROM folders WHERE parent_id IS ?1
             UNION ALL
             SELECT 'session' AS kind, id, folder_id AS parent_id, position, name
             FROM sessions WHERE folder_id IS ?1
         )
         ORDER BY position,
                  CASE
                      WHEN ?1 IS NULL AND kind = 'session' THEN 0
                      WHEN ?1 IS NULL THEN 1
                      WHEN kind = 'folder' THEN 0
                      ELSE 1
                  END,
                  name COLLATE NOCASE, id",
    )?;
    let items = statement
        .query_map(params![parent_id], read_sidebar_order_item)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(SessionError::from)?;
    Ok(items)
}

fn rewrite_sidebar_positions(
    connection: &Connection,
    items: &[SessionSidebarOrderItem],
) -> Result<(), SessionError> {
    for (position, item) in items.iter().enumerate() {
        let sql = match item.kind.as_str() {
            "folder" => "UPDATE folders SET position = ?2 WHERE id = ?1",
            "session" => "UPDATE sessions SET position = ?2 WHERE id = ?1",
            _ => return Err(invalid_sidebar_placement("unsupported sidebar item kind")),
        };
        let changed = connection.execute(sql, params![item.id.as_str(), position as i64])?;
        if changed != 1 {
            return Err(SessionError::NotFound);
        }
    }
    Ok(())
}

fn collect_folder_subtree_sessions(
    connection: &Connection,
    folder_id: &str,
    visited_folder_ids: &mut HashSet<String>,
    sessions: &mut Vec<SessionSidebarOrderItem>,
) -> Result<(), SessionError> {
    if !visited_folder_ids.insert(folder_id.to_string()) {
        return Err(invalid_sidebar_placement("cyclic folder hierarchy"));
    }
    for item in sidebar_items_for_parent(connection, Some(folder_id))? {
        if item.kind == "folder" {
            collect_folder_subtree_sessions(connection, &item.id, visited_folder_ids, sessions)?;
        } else {
            sessions.push(item);
        }
    }
    Ok(())
}

#[derive(Serialize)]
struct SessionExportBundle {
    format: String,
    exported_at: String,
    folders: Vec<SessionFolder>,
    sessions: Vec<SessionExportRecord>,
}

#[derive(Serialize)]
struct SessionExportRecord {
    #[serde(flatten)]
    session: SessionRecord,
    #[serde(skip_serializing_if = "Option::is_none")]
    config_json: Option<String>,
}

fn read_folder(row: &rusqlite::Row<'_>) -> rusqlite::Result<SessionFolder> {
    Ok(SessionFolder {
        id: row.get(0)?,
        parent_id: row.get(1)?,
        name: row.get(2)?,
    })
}

fn read_sidebar_order_item(row: &rusqlite::Row<'_>) -> rusqlite::Result<SessionSidebarOrderItem> {
    Ok(SessionSidebarOrderItem {
        kind: row.get(0)?,
        id: row.get(1)?,
        parent_id: row.get(2)?,
    })
}

fn read_session(row: &rusqlite::Row<'_>) -> rusqlite::Result<SessionRecord> {
    let tags_json: String = row.get(9)?;
    let tags = serde_json::from_str(&tags_json).unwrap_or_default();
    let port: i64 = row.get(5)?;

    Ok(SessionRecord {
        id: row.get(0)?,
        folder_id: row.get(1)?,
        name: row.get(2)?,
        protocol: row.get(3)?,
        host: row.get(4)?,
        port: port as u32,
        username: row.get(6)?,
        private_key_path: row.get(7)?,
        credential_id: row.get(8)?,
        tags,
        last_opened_at: row.get(10)?,
    })
}

fn non_empty_optional(value: String) -> Option<String> {
    let value = value.trim().to_string();
    if value.is_empty() {
        None
    } else {
        Some(value)
    }
}

fn protocol_config_json_for_session(
    session: &SessionRecord,
) -> Result<Option<String>, SessionError> {
    protocol_config_json_for_session_with_override(session, None)
}

fn protocol_config_json_for_session_with_override(
    session: &SessionRecord,
    config_json_override: Option<&str>,
) -> Result<Option<String>, SessionError> {
    let protocol = session
        .protocol
        .trim()
        .to_ascii_lowercase()
        .replace('-', "_");
    let config = match protocol.as_str() {
        "ssh" | "scp" => serialize_protocol_config(NetworkAuthSessionConfig {
            kind: &protocol,
            host: &session.host,
            port: session.port,
            username: session.username.as_deref(),
            private_key_path: session.private_key_path.as_deref(),
            credential_id: session.credential_id.as_deref(),
            session_icon_id: session_icon_id_for_session(config_json_override)?,
            tag_style: tag_style_for_session(config_json_override)?,
            automation: automation_metadata_for_session(config_json_override)?,
        })?,
        "telnet" => serialize_protocol_config(NetworkSessionConfig {
            kind: "telnet",
            host: &session.host,
            port: session.port,
            username: session.username.as_deref(),
            tag_style: tag_style_for_session(config_json_override)?,
            automation: automation_metadata_for_session(config_json_override)?,
        })?,
        "ftp" => serialize_protocol_config(NetworkCredentialSessionConfig {
            kind: "ftp",
            host: &session.host,
            port: session.port,
            username: session.username.as_deref(),
            credential_id: session.credential_id.as_deref(),
            tag_style: tag_style_for_session(config_json_override)?,
            automation: automation_metadata_for_session(config_json_override)?,
        })?,
        "serial" => {
            serialize_protocol_config(serial_config_for_session(session, config_json_override)?)?
        }
        "vnc" => serialize_protocol_config(GraphicsSessionConfig {
            kind: &protocol,
            host: &session.host,
            port: session.port,
            tag_style: tag_style_for_session(config_json_override)?,
            automation: automation_metadata_for_session(config_json_override)?,
        })?,
        "browser" => serialize_protocol_config(BrowserSessionConfig {
            kind: "browser",
            url: &session.host,
            tag_style: tag_style_for_session(config_json_override)?,
            automation: automation_metadata_for_session(config_json_override)?,
        })?,
        "file" => serialize_protocol_config(PathSessionConfig {
            kind: "file",
            path: &session.host,
            tag_style: tag_style_for_session(config_json_override)?,
            automation: automation_metadata_for_session(config_json_override)?,
        })?,
        "shell" => serialize_protocol_config(PathSessionConfig {
            kind: "shell",
            path: &session.host,
            tag_style: tag_style_for_session(config_json_override)?,
            automation: automation_metadata_for_session(config_json_override)?,
        })?,
        _ => return Ok(None),
    };

    Ok(Some(config))
}

fn session_icon_id_for_session(
    config_json_override: Option<&str>,
) -> Result<Option<String>, SessionError> {
    let Some(config_json) = config_json_override
        .map(str::trim)
        .filter(|value| !value.is_empty())
    else {
        return Ok(None);
    };
    let object = serde_json::from_str::<serde_json::Value>(config_json).map_err(|error| {
        SessionError::Database {
            message: error.to_string(),
        }
    })?;
    Ok(object
        .get("sessionIconID")
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string))
}

fn export_safe_config_json(config_json: Option<&str>) -> Option<String> {
    let icon_id = safe_session_icon_id(config_json)?;
    serde_json::to_string(&serde_json::json!({ "sessionIconID": icon_id })).ok()
}

fn safe_session_icon_id(config_json: Option<&str>) -> Option<String> {
    let object = serde_json::from_str::<serde_json::Value>(config_json?.trim())
        .ok()?
        .as_object()?
        .clone();
    let icon_id = object.get("sessionIconID")?.as_str()?.trim();
    if icon_id.is_empty()
        || icon_id.len() > 64
        || !icon_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return None;
    }
    Some(icon_id.to_string())
}

fn tag_style_for_session(
    config_json_override: Option<&str>,
) -> Result<Option<TagStyleConfig>, SessionError> {
    let Some(config_json) = config_json_override
        .map(str::trim)
        .filter(|value| !value.is_empty())
    else {
        return Ok(None);
    };
    let override_config =
        serde_json::from_str::<TagStyleConfigOverride>(config_json).map_err(|error| {
            SessionError::Database {
                message: error.to_string(),
            }
        })?;
    let Some(tag_style) = override_config.tag_style else {
        return Ok(None);
    };
    let Some(color) = tag_style.color.filter(|value| is_valid_hex_color(value)) else {
        return Ok(None);
    };
    Ok(Some(TagStyleConfig { color }))
}

fn automation_metadata_for_session(
    config_json_override: Option<&str>,
) -> Result<Option<SessionAutomationMetadata>, SessionError> {
    let Some(config_json) = config_json_override
        .map(str::trim)
        .filter(|value| !value.is_empty())
    else {
        return Ok(None);
    };
    let override_config =
        serde_json::from_str::<SessionAutomationOverride>(config_json).map_err(|error| {
            SessionError::Database {
                message: error.to_string(),
            }
        })?;
    let environment = override_config
        .environment
        .and_then(|value| normalize_session_environment(&value));
    let ai_execution_policy = override_config
        .ai_execution_policy
        .and_then(|value| normalize_ai_execution_policy(&value));
    let startup_command = override_config
        .startup_command
        .and_then(|value| normalize_optional_string(&value));
    let post_connect_script = override_config
        .post_connect_script
        .and_then(|value| normalize_optional_string(&value));
    let environment_variables =
        normalize_environment_variables(override_config.environment_variables);
    let connect_timeout_ms = normalize_connect_timeout_ms(override_config.connect_timeout_ms);

    if environment.is_none()
        && ai_execution_policy.is_none()
        && startup_command.is_none()
        && post_connect_script.is_none()
        && environment_variables.is_none()
        && connect_timeout_ms.is_none()
    {
        return Ok(None);
    }
    Ok(Some(SessionAutomationMetadata {
        environment,
        ai_execution_policy,
        startup_command,
        post_connect_script,
        environment_variables,
        connect_timeout_ms,
    }))
}

fn normalize_session_environment(value: &str) -> Option<String> {
    match value.trim().to_ascii_lowercase().as_str() {
        "production" | "prod" => Some("production".to_string()),
        "staging" | "stage" => Some("staging".to_string()),
        "development" | "dev" => Some("development".to_string()),
        _ => None,
    }
}

fn normalize_ai_execution_policy(value: &str) -> Option<String> {
    match value.trim().to_ascii_lowercase().as_str() {
        "inherit" => Some("inherit".to_string()),
        "disabled" | "deny" | "off" => Some("disabled".to_string()),
        "commandcard" | "command_card" | "suggest" => Some("commandCard".to_string()),
        "readonlyauto" | "read_only_auto" | "readonly" => Some("readOnlyAuto".to_string()),
        "requireeverycommand" | "require_every_command" | "confirm" => {
            Some("requireEveryCommand".to_string())
        }
        _ => None,
    }
}

fn normalize_optional_string(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn normalize_environment_variables(values: Option<Vec<String>>) -> Option<Vec<String>> {
    let normalized: Vec<String> = values
        .unwrap_or_default()
        .into_iter()
        .filter_map(|value| normalize_optional_string(&value))
        .collect();
    if normalized.is_empty() {
        None
    } else {
        Some(normalized)
    }
}

fn normalize_connect_timeout_ms(value: Option<u32>) -> Option<u32> {
    value.map(|milliseconds| milliseconds.clamp(1_000, 300_000))
}

fn is_valid_hex_color(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 7 && bytes[0] == b'#' && bytes[1..].iter().all(|byte| byte.is_ascii_hexdigit())
}

fn serial_config_for_session(
    session: &SessionRecord,
    config_json_override: Option<&str>,
) -> Result<SerialSessionConfig, SessionError> {
    let advanced = match config_json_override.map(str::trim) {
        Some(config_json) if !config_json.is_empty() => serde_json::from_str::<
            SerialSessionConfigOverride,
        >(config_json)
        .map_err(|error| SessionError::Database {
            message: error.to_string(),
        })?,
        _ => SerialSessionConfigOverride::default(),
    };
    let config = SerialConnectionConfig {
        device_path: session.host.clone(),
        baud_rate: session.port,
        data_bits: advanced.data_bits.unwrap_or(8),
        stop_bits: advanced.stop_bits.unwrap_or(1),
        parity: advanced.parity.unwrap_or_else(|| "none".to_string()),
        flow_control: advanced.flow_control.unwrap_or_else(|| "none".to_string()),
        backspace_mode: advanced.backspace_mode.unwrap_or_else(|| "del".to_string()),
    };
    validate_serial_config(&config).map_err(|_| SessionError::InvalidPort)?;

    Ok(SerialSessionConfig {
        kind: "serial".to_string(),
        device_path: config.device_path,
        baud_rate: (config.baud_rate != 0).then_some(config.baud_rate),
        data_bits: config.data_bits,
        stop_bits: config.stop_bits,
        parity: config.parity.trim().to_ascii_lowercase(),
        flow_control: config.flow_control.trim().to_ascii_lowercase(),
        backspace_mode: config.backspace_mode.trim().to_ascii_lowercase(),
        device_profile: advanced
            .device_profile
            .as_deref()
            .and_then(normalized_serial_device_profile),
        tag_style: tag_style_for_session(config_json_override)?,
        automation: automation_metadata_for_session(config_json_override)?,
    })
}

fn normalized_serial_device_profile(value: &str) -> Option<String> {
    let normalized = value.trim().to_ascii_lowercase();
    match normalized.as_str() {
        "network-generic-9600"
        | "network-generic-115200"
        | "inspur-network"
        | "yuanmai-network"
        | "cisco"
        | "huawei"
        | "h3c"
        | "ruijie"
        | "bdcom" => Some(normalized),
        _ => None,
    }
}

fn serialize_protocol_config<T: Serialize>(config: T) -> Result<String, SessionError> {
    serde_json::to_string(&config).map_err(|error| SessionError::Database {
        message: error.to_string(),
    })
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct NetworkAuthSessionConfig<'a> {
    kind: &'a str,
    host: &'a str,
    port: u32,
    username: Option<&'a str>,
    private_key_path: Option<&'a str>,
    credential_id: Option<&'a str>,
    #[serde(rename = "sessionIconID", skip_serializing_if = "Option::is_none")]
    session_icon_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tag_style: Option<TagStyleConfig>,
    #[serde(flatten, skip_serializing_if = "Option::is_none")]
    automation: Option<SessionAutomationMetadata>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct NetworkCredentialSessionConfig<'a> {
    kind: &'a str,
    host: &'a str,
    port: u32,
    username: Option<&'a str>,
    credential_id: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tag_style: Option<TagStyleConfig>,
    #[serde(flatten, skip_serializing_if = "Option::is_none")]
    automation: Option<SessionAutomationMetadata>,
}

#[derive(Serialize)]
struct NetworkSessionConfig<'a> {
    kind: &'a str,
    host: &'a str,
    port: u32,
    username: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tag_style: Option<TagStyleConfig>,
    #[serde(flatten, skip_serializing_if = "Option::is_none")]
    automation: Option<SessionAutomationMetadata>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
struct TagStyleConfig {
    color: String,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TagStyleConfigOverride {
    tag_style: Option<TagStyleColorOverride>,
}

#[derive(Debug, Deserialize)]
struct TagStyleColorOverride {
    color: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
struct SessionAutomationMetadata {
    #[serde(skip_serializing_if = "Option::is_none")]
    environment: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    ai_execution_policy: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    startup_command: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    post_connect_script: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    environment_variables: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    connect_timeout_ms: Option<u32>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SessionAutomationOverride {
    environment: Option<String>,
    ai_execution_policy: Option<String>,
    startup_command: Option<String>,
    post_connect_script: Option<String>,
    environment_variables: Option<Vec<String>>,
    connect_timeout_ms: Option<u32>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SerialSessionConfigOverride {
    data_bits: Option<u8>,
    stop_bits: Option<u8>,
    parity: Option<String>,
    flow_control: Option<String>,
    backspace_mode: Option<String>,
    device_profile: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SerialSessionConfig {
    kind: String,
    device_path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    baud_rate: Option<u32>,
    data_bits: u8,
    stop_bits: u8,
    parity: String,
    flow_control: String,
    backspace_mode: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    device_profile: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tag_style: Option<TagStyleConfig>,
    #[serde(flatten, skip_serializing_if = "Option::is_none")]
    automation: Option<SessionAutomationMetadata>,
}

#[derive(Serialize)]
struct GraphicsSessionConfig<'a> {
    kind: &'a str,
    host: &'a str,
    port: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    tag_style: Option<TagStyleConfig>,
    #[serde(flatten, skip_serializing_if = "Option::is_none")]
    automation: Option<SessionAutomationMetadata>,
}

#[derive(Serialize)]
struct BrowserSessionConfig<'a> {
    kind: &'a str,
    url: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    tag_style: Option<TagStyleConfig>,
    #[serde(flatten, skip_serializing_if = "Option::is_none")]
    automation: Option<SessionAutomationMetadata>,
}

#[derive(Serialize)]
struct PathSessionConfig<'a> {
    kind: &'a str,
    path: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    tag_style: Option<TagStyleConfig>,
    #[serde(flatten, skip_serializing_if = "Option::is_none")]
    automation: Option<SessionAutomationMetadata>,
}

#[cfg(test)]
mod session_repository_tests {
    use chrono::Utc;
    use rusqlite::{params, Connection};

    use crate::domain::session::{SessionDraft, SessionUpdate};
    use crate::infrastructure::db::apply_migrations;

    use super::SessionRepository;

    #[test]
    fn creates_folder_and_session_then_lists_by_folder() {
        let connection = Connection::open_in_memory().expect("open database");
        apply_migrations(&connection).expect("migrate");
        let repository = SessionRepository::new(connection);

        let folder = repository
            .create_folder(None, "Production")
            .expect("folder");
        let session = repository
            .create_session(SessionDraft {
                folder_id: Some(folder.id.clone()),
                name: "API Server".to_string(),
                protocol: "ssh".to_string(),
                host: "api.example.com".to_string(),
                port: 22,
                username: Some("deploy".to_string()),
                private_key_path: Some("~/.ssh/prod".to_string()),
                credential_id: None,
                tags: vec!["prod".to_string()],
                config_json: None,
            })
            .expect("session");

        let sessions = repository
            .list_sessions(Some(folder.id.clone()))
            .expect("list sessions");
        let folders = repository.list_folders().expect("list folders");

        assert_eq!(folders, vec![folder.clone()]);
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].id, session.id);
        assert_eq!(sessions[0].folder_id, Some(folder.id));
        assert_eq!(sessions[0].host, "api.example.com");
        assert_eq!(
            sessions[0].private_key_path,
            Some("~/.ssh/prod".to_string())
        );
    }

    #[test]
    fn exports_nested_folder_subtree_only() {
        let connection = Connection::open_in_memory().expect("open database");
        apply_migrations(&connection).expect("migrate");
        let repository = SessionRepository::new(connection);

        let production = repository
            .create_folder(None, "Production")
            .expect("production folder");
        let database = repository
            .create_folder(Some(production.id.clone()), "Database")
            .expect("database folder");
        let primary = repository
            .create_folder(Some(database.id.clone()), "Primary")
            .expect("primary folder");
        let lab = repository.create_folder(None, "Lab").expect("lab folder");
        repository
            .create_session(SessionDraft {
                folder_id: Some(primary.id.clone()),
                name: "Primary DB".to_string(),
                protocol: "ssh".to_string(),
                host: "db.example.com".to_string(),
                port: 22,
                username: Some("deploy".to_string()),
                private_key_path: None,
                credential_id: None,
                tags: vec![],
                config_json: Some(
                    r#"{"sessionIconID":"ubuntu","startupCommand":"export TOKEN=folder-secret","postConnectScript":"curl intranet.example/run","environmentVariables":["PASSWORD=folder-password"]}"#
                        .to_string(),
                ),
            })
            .expect("primary session");
        repository
            .create_session(SessionDraft {
                folder_id: Some(lab.id),
                name: "Lab Box".to_string(),
                protocol: "ssh".to_string(),
                host: "lab.example.com".to_string(),
                port: 22,
                username: Some("ops".to_string()),
                private_key_path: None,
                credential_id: None,
                tags: vec![],
                config_json: None,
            })
            .expect("lab session");

        let json = repository
            .export_folder_sessions_json(production.id)
            .expect("export subtree");

        assert!(json.contains("stacio.sessions.v1"));
        assert!(json.contains("Production"));
        assert!(json.contains("Database"));
        assert!(json.contains("Primary"));
        assert!(json.contains("Primary DB"));
        assert!(json.contains(r#"\"sessionIconID\":\"ubuntu\""#));
        assert!(!json.contains("startupCommand"));
        assert!(!json.contains("postConnectScript"));
        assert!(!json.contains("environmentVariables"));
        assert!(!json.contains("folder-secret"));
        assert!(!json.contains("folder-password"));
        assert!(!json.contains("Lab"));
        assert!(!json.contains("Lab Box"));
    }

    #[test]
    fn renames_and_deletes_folder_without_deleting_sessions() {
        let connection = Connection::open_in_memory().expect("open database");
        apply_migrations(&connection).expect("migrate");
        let repository = SessionRepository::new(connection);

        let folder = repository
            .create_folder(None, "Production")
            .expect("folder");
        let renamed = repository
            .rename_folder(folder.id.clone(), "Prod")
            .expect("rename folder");
        let child = repository
            .create_folder(Some(folder.id.clone()), "Database")
            .expect("child folder");
        let session = repository
            .create_session(SessionDraft {
                folder_id: Some(child.id),
                name: "API Server".to_string(),
                protocol: "ssh".to_string(),
                host: "api.example.com".to_string(),
                port: 22,
                username: Some("deploy".to_string()),
                private_key_path: None,
                credential_id: None,
                tags: vec![],
                config_json: None,
            })
            .expect("session");

        repository.delete_folder(folder.id).expect("delete folder");
        let folders = repository.list_folders().expect("folders");
        let root_sessions = repository.list_sessions(None).expect("root sessions");

        assert_eq!(renamed.name, "Prod");
        assert!(folders.is_empty());
        assert_eq!(root_sessions.len(), 1);
        assert_eq!(root_sessions[0].id, session.id);
        assert_eq!(root_sessions[0].folder_id, None);
    }

    #[test]
    fn persists_protocol_specific_serial_config_without_secrets() {
        let connection = Connection::open_in_memory().expect("open database");
        apply_migrations(&connection).expect("migrate");
        let repository = SessionRepository::new(connection);

        let session = repository
            .create_session(SessionDraft {
                folder_id: None,
                name: "Console".to_string(),
                protocol: "serial".to_string(),
                host: "/dev/cu.usbserial-001".to_string(),
                port: 115_200,
                username: None,
                private_key_path: None,
                credential_id: None,
                tags: vec![],
                config_json: Some(
                    r#"{"kind":"serial","devicePath":"/tmp/ignored","baudRate":1,"dataBits":7,"stopBits":2,"parity":"even","flowControl":"rtscts","password":"secret"}"#
                        .to_string(),
                ),
            })
            .expect("session");
        let config = repository
            .get_session_config_json(&session.id)
            .expect("config")
            .expect("stored config");

        assert_eq!(
            config,
            r#"{"kind":"serial","devicePath":"/dev/cu.usbserial-001","baudRate":115200,"dataBits":7,"stopBits":2,"parity":"even","flowControl":"rtscts","backspaceMode":"del"}"#
        );
        assert!(!config.contains("password"));
        assert!(!config.contains("secret"));
        assert!(!config.contains("/tmp/ignored"));
    }

    #[test]
    fn persists_serial_network_device_profile() {
        let connection = Connection::open_in_memory().expect("open database");
        apply_migrations(&connection).expect("migrate");
        let repository = SessionRepository::new(connection);

        let session = repository
            .create_session(SessionDraft {
                folder_id: None,
                name: "Ruijie Console".to_string(),
                protocol: "serial".to_string(),
                host: "/dev/cu.usbserial-ruijie".to_string(),
                port: 9_600,
                username: None,
                private_key_path: None,
                credential_id: None,
                tags: vec![],
                config_json: Some(
                    r#"{"kind":"serial","devicePath":"/tmp/ignored","baudRate":1,"dataBits":8,"stopBits":1,"parity":"none","flowControl":"none","deviceProfile":"ruijie","password":"secret"}"#
                        .to_string(),
                ),
            })
            .expect("session");
        let config = repository
            .get_session_config_json(&session.id)
            .expect("config")
            .expect("stored config");

        assert_eq!(
            config,
            r#"{"kind":"serial","devicePath":"/dev/cu.usbserial-ruijie","baudRate":9600,"dataBits":8,"stopBits":1,"parity":"none","flowControl":"none","backspaceMode":"del","deviceProfile":"ruijie"}"#
        );
        assert!(!config.contains("password"));
        assert!(!config.contains("secret"));
        assert!(!config.contains("/tmp/ignored"));
    }

    #[test]
    fn persists_serial_config_without_baud_rate_when_unspecified() {
        let connection = Connection::open_in_memory().expect("open database");
        apply_migrations(&connection).expect("migrate");
        let repository = SessionRepository::new(connection);

        let session = repository
            .create_session(SessionDraft {
                folder_id: None,
                name: "Bluetooth Console".to_string(),
                protocol: "serial".to_string(),
                host: "/dev/cu.Stacio-Bluetooth".to_string(),
                port: 0,
                username: None,
                private_key_path: None,
                credential_id: None,
                tags: vec![],
                config_json: Some(
                    r#"{"kind":"serial","devicePath":"/dev/cu.Stacio-Bluetooth","dataBits":8,"stopBits":1,"parity":"none","flowControl":"none"}"#
                        .to_string(),
                ),
            })
            .expect("session");
        let config = repository
            .get_session_config_json(&session.id)
            .expect("config")
            .expect("stored config");

        assert_eq!(
            config,
            r#"{"kind":"serial","devicePath":"/dev/cu.Stacio-Bluetooth","dataBits":8,"stopBits":1,"parity":"none","flowControl":"none","backspaceMode":"del"}"#
        );
        assert!(!config.contains("baudRate"));
    }

    #[test]
    fn persists_network_session_tag_color_metadata_without_secrets() {
        let connection = Connection::open_in_memory().expect("open database");
        apply_migrations(&connection).expect("migrate");
        let repository = SessionRepository::new(connection);

        let session = repository
            .create_session(SessionDraft {
                folder_id: None,
                name: "API".to_string(),
                protocol: "ssh".to_string(),
                host: "api.example.com".to_string(),
                port: 22,
                username: None,
                private_key_path: None,
                credential_id: None,
                tags: vec!["prod".to_string()],
                config_json: Some(
                    r##"{"tagStyle":{"color":"#FF3B30"},"password":"secret"}"##.to_string(),
                ),
            })
            .expect("session");
        let config = repository
            .get_session_config_json(&session.id)
            .expect("config")
            .expect("stored config");

        assert_eq!(
            config,
            r##"{"kind":"ssh","host":"api.example.com","port":22,"username":null,"privateKeyPath":null,"credentialId":null,"tagStyle":{"color":"#FF3B30"}}"##
        );
        assert!(!config.contains("password"));
        assert!(!config.contains("secret"));
    }

    #[test]
    fn persists_network_session_automation_metadata_without_secrets() {
        let connection = Connection::open_in_memory().expect("open database");
        apply_migrations(&connection).expect("migrate");
        let repository = SessionRepository::new(connection);

        let session = repository
            .create_session(SessionDraft {
                folder_id: None,
                name: "API".to_string(),
                protocol: "ssh".to_string(),
                host: "api.example.com".to_string(),
                port: 22,
                username: Some("deploy".to_string()),
                private_key_path: None,
                credential_id: None,
                tags: vec!["prod".to_string()],
                config_json: Some(
                    r#"{"environment":"production","aiExecutionPolicy":"commandCard","startupCommand":"cd /srv/app && docker compose ps","environmentVariables":["APP_ENV=prod","STACIO_TRACE=1"],"connectTimeoutMs":45000,"password":"secret"}"#.to_string(),
                ),
            })
            .expect("session");
        let config = repository
            .get_session_config_json(&session.id)
            .expect("config")
            .expect("stored config");

        assert!(config.contains(r#""environment":"production""#));
        assert!(config.contains(r#""aiExecutionPolicy":"commandCard""#));
        assert!(config.contains(r#""startupCommand":"cd /srv/app && docker compose ps""#));
        assert!(config.contains(r#""environmentVariables":["APP_ENV=prod","STACIO_TRACE=1"]"#));
        assert!(config.contains(r#""connectTimeoutMs":45000"#));
        assert!(!config.contains("password"));
        assert!(!config.contains("secret"));
    }

    #[test]
    fn persists_post_connect_script_in_network_session_automation_metadata() {
        let connection = Connection::open_in_memory().expect("open database");
        apply_migrations(&connection).expect("migrate");
        let repository = SessionRepository::new(connection);

        let session = repository
            .create_session(SessionDraft {
                folder_id: None,
                name: "API".to_string(),
                protocol: "ssh".to_string(),
                host: "api.example.com".to_string(),
                port: 22,
                username: Some("deploy".to_string()),
                private_key_path: None,
                credential_id: None,
                tags: vec!["prod".to_string()],
                config_json: Some(
                    r#"{"postConnectScript":"cd /srv/app\nsource .env && export PS1='prod> '","password":"secret"}"#.to_string(),
                ),
            })
            .expect("session");
        let config = repository
            .get_session_config_json(&session.id)
            .expect("config")
            .expect("stored config");

        assert!(config
            .contains(r#""postConnectScript":"cd /srv/app\nsource .env && export PS1='prod> '""#));
        assert!(!config.contains("password"));
        assert!(!config.contains("secret"));
    }

    #[test]
    fn drops_blank_post_connect_script_from_network_session_automation_metadata() {
        let connection = Connection::open_in_memory().expect("open database");
        apply_migrations(&connection).expect("migrate");
        let repository = SessionRepository::new(connection);

        let session = repository
            .create_session(SessionDraft {
                folder_id: None,
                name: "API".to_string(),
                protocol: "ssh".to_string(),
                host: "api.example.com".to_string(),
                port: 22,
                username: Some("deploy".to_string()),
                private_key_path: None,
                credential_id: None,
                tags: vec![],
                config_json: Some(r#"{"postConnectScript":" \n\t "}"#.to_string()),
            })
            .expect("session");
        let config = repository
            .get_session_config_json(&session.id)
            .expect("config")
            .expect("stored config");

        assert!(!config.contains("postConnectScript"));
    }

    #[test]
    fn reads_serial_config_from_legacy_session_fields_when_json_missing() {
        let connection = Connection::open_in_memory().expect("open database");
        apply_migrations(&connection).expect("migrate");
        let repository = SessionRepository::new(connection);

        let session = repository
            .create_session(SessionDraft {
                folder_id: None,
                name: "Console".to_string(),
                protocol: "serial".to_string(),
                host: "/dev/cu.usbserial-legacy".to_string(),
                port: 9_600,
                username: None,
                private_key_path: None,
                credential_id: None,
                tags: vec![],
                config_json: None,
            })
            .expect("session");
        repository
            .connection
            .execute(
                "UPDATE sessions SET config_json = NULL WHERE id = ?1",
                [&session.id],
            )
            .expect("clear config");

        let config = repository
            .get_session_config_json(&session.id)
            .expect("config")
            .expect("legacy config");

        assert_eq!(
            config,
            r#"{"kind":"serial","devicePath":"/dev/cu.usbserial-legacy","baudRate":9600,"dataBits":8,"stopBits":1,"parity":"none","flowControl":"none","backspaceMode":"del"}"#
        );
    }

    #[test]
    fn updates_and_deletes_session() {
        let connection = Connection::open_in_memory().expect("open database");
        apply_migrations(&connection).expect("migrate");
        let repository = SessionRepository::new(connection);

        let session = repository
            .create_session(SessionDraft {
                folder_id: None,
                name: "Old".to_string(),
                protocol: "ssh".to_string(),
                host: "old.example.com".to_string(),
                port: 22,
                username: None,
                private_key_path: None,
                credential_id: None,
                tags: vec![],
                config_json: None,
            })
            .expect("session");

        let updated = repository
            .update_session(
                session.id.clone(),
                SessionUpdate {
                    name: Some("New".to_string()),
                    protocol: Some("telnet".to_string()),
                    folder_id: None,
                    host: None,
                    port: None,
                    username: Some("ops".to_string()),
                    private_key_path: None,
                    credential_id: None,
                    tags: Some(vec!["team-a".to_string()]),
                    config_json: None,
                },
            )
            .expect("update");

        assert_eq!(updated.name, "New");
        assert_eq!(updated.protocol, "telnet");
        assert_eq!(updated.username, Some("ops".to_string()));
        assert_eq!(updated.tags, vec!["team-a".to_string()]);

        repository.delete_session(session.id).expect("delete");
        assert!(repository.list_sessions(None).expect("list").is_empty());
    }

    #[test]
    fn list_sessions_without_folder_returns_only_root_sessions() {
        let connection = Connection::open_in_memory().expect("open database");
        apply_migrations(&connection).expect("migrate");
        let repository = SessionRepository::new(connection);

        let folder = repository
            .create_folder(None, "Production")
            .expect("folder");
        let root_session = repository
            .create_session(SessionDraft {
                folder_id: None,
                name: "Root Host".to_string(),
                protocol: "ssh".to_string(),
                host: "root.example.com".to_string(),
                port: 22,
                username: Some("ops".to_string()),
                private_key_path: None,
                credential_id: None,
                tags: vec![],
                config_json: None,
            })
            .expect("root session");
        let folder_session = repository
            .create_session(SessionDraft {
                folder_id: Some(folder.id.clone()),
                name: "API Server".to_string(),
                protocol: "ssh".to_string(),
                host: "api.example.com".to_string(),
                port: 22,
                username: Some("deploy".to_string()),
                private_key_path: None,
                credential_id: None,
                tags: vec![],
                config_json: None,
            })
            .expect("folder session");

        let root_sessions = repository.list_sessions(None).expect("root sessions");
        let all_sessions = repository.list_all_sessions().expect("all sessions");

        assert_eq!(root_sessions, vec![root_session.clone()]);
        assert_eq!(all_sessions, vec![folder_session, root_session]);
    }

    #[test]
    fn marks_session_opened_and_returns_last_opened_at_in_lists() {
        let connection = Connection::open_in_memory().expect("open database");
        apply_migrations(&connection).expect("migrate");
        let repository = SessionRepository::new(connection);

        let session = repository
            .create_session(SessionDraft {
                folder_id: None,
                name: "Recent Host".to_string(),
                protocol: "ssh".to_string(),
                host: "recent.example.com".to_string(),
                port: 22,
                username: Some("deploy".to_string()),
                private_key_path: None,
                credential_id: None,
                tags: vec![],
                config_json: None,
            })
            .expect("session");

        assert_eq!(session.last_opened_at, None);

        let opened = repository
            .mark_session_opened(session.id.clone())
            .expect("mark opened");
        let listed = repository.list_sessions(None).expect("list sessions");
        let all_sessions = repository.list_all_sessions().expect("all sessions");

        assert!(opened.last_opened_at.is_some());
        assert_eq!(listed[0].id, session.id);
        assert_eq!(listed[0].last_opened_at, opened.last_opened_at);
        assert_eq!(all_sessions[0].last_opened_at, opened.last_opened_at);
    }

    #[test]
    fn mark_session_opened_returns_not_found_for_missing_session() {
        let connection = Connection::open_in_memory().expect("open database");
        apply_migrations(&connection).expect("migrate");
        let repository = SessionRepository::new(connection);

        let error = repository
            .mark_session_opened("missing-session".to_string())
            .expect_err("missing session");

        assert_eq!(error, crate::domain::session::SessionError::NotFound);
    }

    #[test]
    fn export_rows_do_not_contain_secret_values() {
        let connection = Connection::open_in_memory().expect("open database");
        apply_migrations(&connection).expect("migrate");
        let repository = SessionRepository::new(connection);

        repository
            .create_session(SessionDraft {
                folder_id: None,
                name: "No Secrets".to_string(),
                protocol: "ssh".to_string(),
                host: "secure.example.com".to_string(),
                port: 22,
                username: Some("admin".to_string()),
                private_key_path: Some("~/.ssh/admin".to_string()),
                credential_id: None,
                tags: vec![],
                config_json: None,
            })
            .expect("session");

        let rows = repository
            .export_sessions_without_secrets()
            .expect("export");
        let serialized = serde_json::to_string(&rows).expect("serialize");

        assert!(serialized.contains("secure.example.com"));
        assert!(serialized.contains("~/.ssh/admin"));
        assert!(!serialized.contains("password"));
        assert!(!serialized.contains("secret"));
    }

    #[test]
    fn duplicates_session_without_reusing_identity_or_opened_time() {
        let connection = Connection::open_in_memory().expect("open database");
        apply_migrations(&connection).expect("migrate");
        let repository = SessionRepository::new(connection);
        let folder = repository
            .create_folder(None, "Production")
            .expect("folder");
        let child_folder = repository
            .create_folder(Some(folder.id.clone()), "Database")
            .expect("child folder");
        let credential_id = insert_test_credential(&repository);
        let original = repository
            .create_session(SessionDraft {
                folder_id: None,
                name: "API Server".to_string(),
                protocol: "ssh".to_string(),
                host: "api.example.com".to_string(),
                port: 22,
                username: Some("deploy".to_string()),
                private_key_path: Some("~/.ssh/prod".to_string()),
                credential_id: Some(credential_id.clone()),
                tags: vec!["prod".to_string()],
                config_json: None,
            })
            .expect("session");
        let opened = repository
            .mark_session_opened(original.id.clone())
            .expect("mark opened");

        let duplicate = repository
            .duplicate_session(original.id.clone(), Some(folder.id.clone()))
            .expect("duplicate");

        assert_ne!(duplicate.id, original.id);
        assert_eq!(duplicate.folder_id, Some(folder.id.clone()));
        assert_eq!(duplicate.name, "API Server 副本");
        assert_eq!(duplicate.protocol, original.protocol);
        assert_eq!(duplicate.host, original.host);
        assert_eq!(duplicate.port, original.port);
        assert_eq!(duplicate.username, original.username);
        assert_eq!(duplicate.private_key_path, original.private_key_path);
        assert_eq!(duplicate.credential_id, original.credential_id);
        assert_eq!(duplicate.tags, original.tags);
        assert_eq!(duplicate.last_opened_at, None);
        assert!(opened.last_opened_at.is_some());
        assert_eq!(
            sidebar_ids(&repository, Some(folder.id.as_str())),
            vec![child_folder.id, duplicate.id]
        );
    }

    #[test]
    fn moves_session_to_folder_and_back_to_root() {
        let connection = Connection::open_in_memory().expect("open database");
        apply_migrations(&connection).expect("migrate");
        let repository = SessionRepository::new(connection);
        let folder = repository
            .create_folder(None, "Production")
            .expect("folder");
        let session = repository
            .create_session(SessionDraft {
                folder_id: None,
                name: "API Server".to_string(),
                protocol: "ssh".to_string(),
                host: "api.example.com".to_string(),
                port: 22,
                username: Some("deploy".to_string()),
                private_key_path: None,
                credential_id: None,
                tags: vec![],
                config_json: None,
            })
            .expect("session");

        let moved = repository
            .move_session(session.id.clone(), Some(folder.id.clone()))
            .expect("move to folder");
        let root = repository
            .move_session(session.id, None)
            .expect("move to root");

        assert_eq!(moved.folder_id, Some(folder.id));
        assert_eq!(root.folder_id, None);
        assert_eq!(repository.list_sessions(None).expect("root"), vec![root]);
    }

    #[test]
    fn moving_session_to_its_current_folder_preserves_sidebar_order() {
        let connection = Connection::open_in_memory().expect("open database");
        apply_migrations(&connection).expect("migrate");
        let repository = SessionRepository::new(connection);
        let folder = repository
            .create_folder(None, "Production")
            .expect("folder");
        let first = create_test_session(&repository, Some(folder.id.clone()), "First");
        let second = create_test_session(&repository, Some(folder.id.clone()), "Second");
        let order_before = sidebar_ids(&repository, Some(folder.id.as_str()));

        let unchanged = repository
            .move_session(first.id.clone(), Some(folder.id.clone()))
            .expect("same-folder move");

        assert_eq!(unchanged.id, first.id);
        assert_eq!(
            sidebar_ids(&repository, Some(folder.id.as_str())),
            order_before
        );
        assert_eq!(order_before, vec![first.id, second.id]);
    }

    #[test]
    fn sidebar_snapshot_loads_tree_and_only_safe_manual_icon_assignments() {
        let connection = Connection::open_in_memory().expect("open database");
        apply_migrations(&connection).expect("migrate");
        let repository = SessionRepository::new(connection);
        let folder = repository
            .create_folder(None, "Production")
            .expect("folder");
        let safe = repository
            .create_session(SessionDraft {
                folder_id: Some(folder.id.clone()),
                name: "Safe".to_string(),
                protocol: "ssh".to_string(),
                host: "safe.example.com".to_string(),
                port: 22,
                username: None,
                private_key_path: None,
                credential_id: None,
                tags: vec![],
                config_json: Some(
                    r#"{"sessionIconID":"ubuntu","startupCommand":"export TOKEN=hidden"}"#
                        .to_string(),
                ),
            })
            .expect("safe session");
        repository
            .create_session(SessionDraft {
                folder_id: None,
                name: "Unsafe".to_string(),
                protocol: "ssh".to_string(),
                host: "unsafe.example.com".to_string(),
                port: 22,
                username: None,
                private_key_path: None,
                credential_id: None,
                tags: vec![],
                config_json: Some(
                    r#"{"sessionIconID":"../../payload","postConnectScript":"hidden"}"#.to_string(),
                ),
            })
            .expect("unsafe session");

        let snapshot = repository
            .load_session_sidebar_snapshot()
            .expect("sidebar snapshot");

        assert_eq!(snapshot.folders, vec![folder]);
        assert_eq!(snapshot.sessions.len(), 2);
        assert_eq!(snapshot.order_items.len(), 3);
        assert_eq!(snapshot.manual_icon_assignments.len(), 1);
        assert_eq!(snapshot.manual_icon_assignments[0].session_id, safe.id);
        assert_eq!(snapshot.manual_icon_assignments[0].icon_id, "ubuntu");
        assert!(!format!("{snapshot:?}").contains("TOKEN"));
        assert!(!format!("{snapshot:?}").contains("startupCommand"));
        assert!(!format!("{snapshot:?}").contains("postConnectScript"));
    }

    #[test]
    fn places_mixed_sidebar_items_across_parents_and_persists_order() {
        let database = tempfile::NamedTempFile::new().expect("temp database");
        let path = database.path().to_path_buf();
        let (root_a_id, root_b_id, folder_id, child_folder_id, inside_id);

        {
            let connection = Connection::open(&path).expect("open database");
            apply_migrations(&connection).expect("migrate");
            let repository = SessionRepository::new(connection);
            let root_a = create_test_session(&repository, None, "Root A");
            let folder = repository
                .create_folder(None, "Production")
                .expect("root folder");
            let root_b = create_test_session(&repository, None, "Root B");
            let child_folder = repository
                .create_folder(Some(folder.id.clone()), "Database")
                .expect("child folder");
            let inside = create_test_session(&repository, Some(folder.id.clone()), "Inside");

            assert_eq!(
                sidebar_ids(&repository, None),
                vec![root_a.id.clone(), folder.id.clone(), root_b.id.clone()]
            );
            repository
                .place_session_sidebar_item("folder".to_string(), folder.id.clone(), None, 0)
                .expect("reorder root folder");
            repository
                .place_session_sidebar_item(
                    "session".to_string(),
                    root_b.id.clone(),
                    Some(folder.id.clone()),
                    1,
                )
                .expect("move session into folder");

            assert_eq!(
                sidebar_ids(&repository, None),
                vec![folder.id.clone(), root_a.id.clone()]
            );
            assert_eq!(
                sidebar_ids(&repository, Some(folder.id.as_str())),
                vec![
                    child_folder.id.clone(),
                    root_b.id.clone(),
                    inside.id.clone()
                ]
            );
            let root_before_invalid_move = sidebar_ids(&repository, None);
            let error = repository
                .place_session_sidebar_item(
                    "folder".to_string(),
                    folder.id.clone(),
                    Some(folder.id.clone()),
                    0,
                )
                .expect_err("reject folder parent change");
            assert!(matches!(
                error,
                crate::domain::session::SessionError::Database { .. }
            ));
            assert_eq!(sidebar_ids(&repository, None), root_before_invalid_move);
            let folder_before_invalid_move = sidebar_ids(&repository, Some(folder.id.as_str()));
            let error = repository
                .place_session_sidebar_item(
                    "session".to_string(),
                    root_a.id.clone(),
                    Some("missing-folder".to_string()),
                    0,
                )
                .expect_err("reject missing target folder");
            assert_eq!(error, crate::domain::session::SessionError::NotFound);
            assert_eq!(sidebar_ids(&repository, None), root_before_invalid_move);
            assert_eq!(
                sidebar_ids(&repository, Some(folder.id.as_str())),
                folder_before_invalid_move
            );

            root_a_id = root_a.id;
            root_b_id = root_b.id;
            folder_id = folder.id;
            child_folder_id = child_folder.id;
            inside_id = inside.id;
        }

        let connection = Connection::open(&path).expect("reopen database");
        apply_migrations(&connection).expect("reapply migrations");
        let repository = SessionRepository::new(connection);
        assert_eq!(
            sidebar_ids(&repository, None),
            vec![folder_id.clone(), root_a_id]
        );
        assert_eq!(
            sidebar_ids(&repository, Some(folder_id.as_str())),
            vec![child_folder_id, root_b_id, inside_id]
        );
    }

    #[test]
    fn existing_move_appends_session_to_mixed_destination_order() {
        let connection = Connection::open_in_memory().expect("open database");
        apply_migrations(&connection).expect("migrate");
        let repository = SessionRepository::new(connection);
        let folder = repository
            .create_folder(None, "Production")
            .expect("folder");
        let child = repository
            .create_folder(Some(folder.id.clone()), "Database")
            .expect("child folder");
        let existing = create_test_session(&repository, Some(folder.id.clone()), "Existing");
        let moving = create_test_session(&repository, None, "Moving");

        repository
            .move_session(moving.id.clone(), Some(folder.id.clone()))
            .expect("move session");

        assert_eq!(
            sidebar_ids(&repository, Some(folder.id.as_str())),
            vec![child.id, existing.id, moving.id]
        );
    }

    #[test]
    fn deleting_folder_appends_descendant_sessions_to_root_in_stable_order() {
        let connection = Connection::open_in_memory().expect("open database");
        apply_migrations(&connection).expect("migrate");
        let repository = SessionRepository::new(connection);
        let root = create_test_session(&repository, None, "Root");
        let survivor = repository
            .create_folder(None, "Survivor")
            .expect("survivor folder");
        let doomed = repository
            .create_folder(None, "Doomed")
            .expect("doomed folder");
        let direct = create_test_session(&repository, Some(doomed.id.clone()), "Direct");
        let child = repository
            .create_folder(Some(doomed.id.clone()), "Child")
            .expect("child folder");
        let nested = create_test_session(&repository, Some(child.id), "Nested");
        repository
            .place_session_sidebar_item("folder".to_string(), doomed.id.clone(), None, 1)
            .expect("place doomed folder");

        repository
            .delete_folder(doomed.id)
            .expect("delete folder subtree");

        assert_eq!(
            sidebar_ids(&repository, None),
            vec![
                root.id.clone(),
                survivor.id,
                direct.id.clone(),
                nested.id.clone(),
            ]
        );
        repository
            .delete_session(root.id)
            .expect("delete root session");
        assert_eq!(
            repository
                .list_sessions(None)
                .expect("list moved sessions")
                .into_iter()
                .map(|session| session.id)
                .collect::<Vec<_>>(),
            vec![direct.id, nested.id]
        );
    }

    #[test]
    fn exports_json_bundle_without_secret_values() {
        let connection = Connection::open_in_memory().expect("open database");
        apply_migrations(&connection).expect("migrate");
        let repository = SessionRepository::new(connection);
        let folder = repository
            .create_folder(None, "Production")
            .expect("folder");
        let credential_id = insert_test_credential(&repository);
        repository
            .create_session(SessionDraft {
                folder_id: Some(folder.id),
                name: "API Server".to_string(),
                protocol: "ssh".to_string(),
                host: "api.example.com".to_string(),
                port: 22,
                username: Some("deploy".to_string()),
                private_key_path: Some("~/.ssh/prod".to_string()),
                credential_id: Some(credential_id.clone()),
                tags: vec!["prod".to_string()],
                config_json: Some(
                    r#"{"sessionIconID":"aliyun","startupCommand":"export TOKEN=all-secret","postConnectScript":"source /private/credentials","environmentVariables":["PASSWORD=all-password"]}"#
                        .to_string(),
                ),
            })
            .expect("session");

        let json = repository.export_sessions_json().expect("export json");
        let value = serde_json::from_str::<serde_json::Value>(&json).expect("valid json");

        assert_eq!(value["format"], "stacio.sessions.v1");
        assert!(value["folders"].is_array());
        assert!(value["sessions"].is_array());
        assert!(json.contains("\"folders\""));
        assert!(json.contains("\"sessions\""));
        assert!(json.contains("API Server"));
        assert!(json.contains(&credential_id));
        assert!(json.contains("~/.ssh/prod"));
        assert_eq!(
            value["sessions"][0]["config_json"].as_str(),
            Some(r#"{"sessionIconID":"aliyun"}"#)
        );
        assert!(!json.contains("startupCommand"));
        assert!(!json.contains("postConnectScript"));
        assert!(!json.contains("environmentVariables"));
        assert!(!json.contains("all-secret"));
        assert!(!json.contains("all-password"));
        assert!(!json.contains("password"));
        assert!(!json.contains("secret"));
        assert!(!json.contains("ssh "));
        assert!(!json.contains("scp "));
    }

    fn insert_test_credential(repository: &SessionRepository) -> String {
        let credential_id = format!("cred_{}", uuid::Uuid::new_v4());
        let now = Utc::now().to_rfc3339();
        repository
            .connection
            .execute(
                "INSERT INTO credentials
                 (id, kind, label, keychain_service, keychain_account, last_verified_at, created_at, updated_at)
                 VALUES (?1, 'key_ref', 'API credential', 'Stacio', 'deploy@example.com', NULL, ?2, ?2)",
                params![credential_id.as_str(), now.as_str()],
            )
            .expect("insert credential");
        credential_id
    }

    fn create_test_session(
        repository: &SessionRepository,
        folder_id: Option<String>,
        name: &str,
    ) -> crate::domain::session::SessionRecord {
        repository
            .create_session(SessionDraft {
                folder_id,
                name: name.to_string(),
                protocol: "ssh".to_string(),
                host: format!(
                    "{}.example.com",
                    name.to_ascii_lowercase().replace(' ', "-")
                ),
                port: 22,
                username: None,
                private_key_path: None,
                credential_id: None,
                tags: vec![],
                config_json: None,
            })
            .expect("create test session")
    }

    fn sidebar_ids(repository: &SessionRepository, parent_id: Option<&str>) -> Vec<String> {
        repository
            .list_session_sidebar_order()
            .expect("list sidebar order")
            .into_iter()
            .filter(|item| item.parent_id.as_deref() == parent_id)
            .map(|item| item.id)
            .collect()
    }
}
