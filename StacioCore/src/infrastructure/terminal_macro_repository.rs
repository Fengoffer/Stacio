use chrono::Utc;
use rusqlite::{params, Connection};
use uuid::Uuid;

use crate::domain::macro_recording::{redact_macro_input, MacroStep};

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct TerminalMacroRecord {
    pub id: String,
    pub name: String,
    pub steps: Vec<MacroStep>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, thiserror::Error)]
pub enum TerminalMacroRepositoryError {
    #[error("terminal macro database error: {0}")]
    Database(#[from] rusqlite::Error),
    #[error("terminal macro serialization failed: {0}")]
    Serialization(#[from] serde_json::Error),
    #[error("terminal macro not found")]
    NotFound,
}

pub struct TerminalMacroRepository {
    connection: Connection,
}

impl TerminalMacroRepository {
    pub fn new(connection: Connection) -> Self {
        Self { connection }
    }

    pub fn create(
        &self,
        name: &str,
        steps: Vec<MacroStep>,
    ) -> Result<TerminalMacroRecord, TerminalMacroRepositoryError> {
        let now = Utc::now().to_rfc3339();
        let record = TerminalMacroRecord {
            id: Uuid::new_v4().to_string(),
            name: normalized_name(name),
            steps: normalized_steps(steps),
            created_at: now.clone(),
            updated_at: now,
        };
        let steps_json = serde_json::to_string(&record.steps)?;
        self.connection.execute(
            "INSERT INTO terminal_macros
             (id, name, steps_json, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                record.id,
                record.name,
                steps_json,
                record.created_at,
                record.updated_at
            ],
        )?;
        Ok(record)
    }

    pub fn list(&self) -> Result<Vec<TerminalMacroRecord>, TerminalMacroRepositoryError> {
        let mut statement = self.connection.prepare(
            "SELECT id, name, steps_json, created_at, updated_at
             FROM terminal_macros
             ORDER BY updated_at DESC, rowid DESC",
        )?;
        let mut rows = statement.query([])?;
        let mut records = Vec::new();
        while let Some(row) = rows.next()? {
            records.push(read_terminal_macro_record(row)?);
        }
        Ok(records)
    }

    pub fn update(
        &self,
        id: &str,
        name: &str,
        steps: Vec<MacroStep>,
    ) -> Result<TerminalMacroRecord, TerminalMacroRepositoryError> {
        let updated_at = Utc::now().to_rfc3339();
        let normalized = normalized_steps(steps);
        let steps_json = serde_json::to_string(&normalized)?;
        let affected = self.connection.execute(
            "UPDATE terminal_macros
             SET name = ?2, steps_json = ?3, updated_at = ?4
             WHERE id = ?1",
            params![id, normalized_name(name), steps_json, updated_at],
        )?;
        if affected == 0 {
            return Err(TerminalMacroRepositoryError::NotFound);
        }
        self.get(id)
    }

    pub fn rename(
        &self,
        id: &str,
        name: &str,
    ) -> Result<TerminalMacroRecord, TerminalMacroRepositoryError> {
        let updated_at = Utc::now().to_rfc3339();
        let affected = self.connection.execute(
            "UPDATE terminal_macros
             SET name = ?2, updated_at = ?3
             WHERE id = ?1",
            params![id, normalized_name(name), updated_at],
        )?;
        if affected == 0 {
            return Err(TerminalMacroRepositoryError::NotFound);
        }
        self.get(id)
    }

    pub fn delete(&self, id: &str) -> Result<(), TerminalMacroRepositoryError> {
        self.connection
            .execute("DELETE FROM terminal_macros WHERE id = ?1", params![id])?;
        Ok(())
    }

    fn get(&self, id: &str) -> Result<TerminalMacroRecord, TerminalMacroRepositoryError> {
        let mut statement = self.connection.prepare(
            "SELECT id, name, steps_json, created_at, updated_at
             FROM terminal_macros
             WHERE id = ?1",
        )?;
        let mut rows = statement.query(params![id])?;
        let row = rows.next()?.ok_or(TerminalMacroRepositoryError::NotFound)?;
        read_terminal_macro_record(row)
    }
}

fn read_terminal_macro_record(
    row: &rusqlite::Row<'_>,
) -> Result<TerminalMacroRecord, TerminalMacroRepositoryError> {
    let steps_json: String = row.get(2)?;
    let mut steps: Vec<MacroStep> = serde_json::from_str(&steps_json)?;
    steps.sort_by_key(|step| step.order);
    Ok(TerminalMacroRecord {
        id: row.get(0)?,
        name: row.get(1)?,
        steps,
        created_at: row.get(3)?,
        updated_at: row.get(4)?,
    })
}

fn normalized_name(name: &str) -> String {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        "Macro".to_string()
    } else {
        trimmed.to_string()
    }
}

fn normalized_steps(mut steps: Vec<MacroStep>) -> Vec<MacroStep> {
    steps.sort_by_key(|step| step.order);
    steps
        .into_iter()
        .enumerate()
        .map(|(index, step)| MacroStep {
            order: (index + 1) as u32,
            input: redact_macro_input(&step.input),
            delay_ms: if step.delay_ms == 0 {
                300
            } else {
                step.delay_ms
            },
        })
        .collect()
}
