use std::collections::{HashMap, HashSet};

use crate::domain::session::{QuickConnectTarget, SessionError, SessionFolder, SessionRecord};

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct ImportSessionPreview {
    pub name: String,
    pub folder: Option<String>,
    pub protocol: String,
    pub host: String,
    pub port: u16,
    pub username: Option<String>,
    pub private_key_path: Option<String>,
    pub conflict: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct ImportPreview {
    pub sessions: Vec<ImportSessionPreview>,
    pub warnings: Vec<String>,
    pub conflict_count: u32,
    pub ignored_secret_field_count: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct ImportReport {
    pub id: String,
    pub source_type: String,
    pub source_name: String,
    pub status: String,
    pub imported_count: u32,
    pub skipped_count: u32,
    pub failed_count: u32,
    pub issues: Vec<String>,
    pub created_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct ImportApplyResult {
    pub report: ImportReport,
    pub imported_sessions: Vec<crate::domain::session::SessionRecord>,
}

pub fn preview_csv_import(
    input: &str,
    existing_session_names: Vec<String>,
) -> Result<ImportPreview, SessionError> {
    let mut lines = input.lines().filter(|line| !line.trim().is_empty());
    let header_line = lines.next().ok_or(SessionError::InvalidQuickConnect)?;
    let headers = split_csv_line(header_line);
    let header_index = headers
        .iter()
        .enumerate()
        .map(|(index, name)| (name.to_ascii_lowercase(), index))
        .collect::<HashMap<_, _>>();
    let existing = existing_set(existing_session_names);
    let mut warnings = Vec::new();
    let mut sessions = Vec::new();
    let mut ignored_secret_field_count = 0_u32;

    for (row_index, line) in lines.enumerate() {
        let values = split_csv_line(line);
        if value_for(&values, &header_index, "password").is_some() {
            ignored_secret_field_count += 1;
            warnings.push(format!(
                "第 {} 行包含密码字段，已忽略；导入后请在钥匙串中配置凭据",
                row_index + 2
            ));
        }

        let name = required_value(&values, &header_index, "name")?;
        let host = required_value(&values, &header_index, "host")?;
        let Some(port) = csv_port_for_row(&values, &header_index, row_index + 2, &mut warnings)
        else {
            continue;
        };
        let username = value_for(&values, &header_index, "username");
        let folder = value_for(&values, &header_index, "folder");
        let private_key_path = value_for(&values, &header_index, "private_key_path");
        let conflict = existing.contains(&name.to_ascii_lowercase());

        sessions.push(ImportSessionPreview {
            name,
            folder,
            protocol: "ssh".to_string(),
            host,
            port,
            username,
            private_key_path,
            conflict,
        });
    }

    Ok(preview_from_parts(
        sessions,
        warnings,
        ignored_secret_field_count,
    ))
}

pub fn preview_legacy_ini_import(
    input: &str,
    existing_session_names: Vec<String>,
) -> Result<ImportPreview, SessionError> {
    let existing = existing_set(existing_session_names);
    let mut warnings = Vec::new();
    let mut sessions = Vec::new();
    let mut ignored_secret_field_count = 0_u32;

    for line in input.lines().map(str::trim).filter(|line| !line.is_empty()) {
        if line.starts_with('[') || line.starts_with('#') || line.starts_with(';') {
            continue;
        }

        let Some((raw_name, raw_value)) = line.split_once('=') else {
            continue;
        };

        if raw_name.to_ascii_lowercase().contains("password") {
            ignored_secret_field_count += 1;
            warnings.push(format!("{raw_name} 包含密码字段，已忽略；不会导入密码"));
            continue;
        }

        let Some(parsed_target) = parse_legacy_ini_session_target(raw_value.trim())? else {
            warnings.push(format!(
                "{raw_name} 已跳过；当前仅导入 SSH、FTP、Telnet 和 VNC 会话"
            ));
            continue;
        };
        if parsed_target.ignored_userinfo_secret {
            ignored_secret_field_count += 1;
            warnings.push(format!(
                "{raw_name} 的 URL 用户信息包含密码，已忽略；导入后请在钥匙串中配置凭据"
            ));
        }
        let target = parsed_target.target;

        let (folder, name) = split_folder_name(raw_name.trim());
        let conflict = existing.contains(&name.to_ascii_lowercase());

        sessions.push(ImportSessionPreview {
            name,
            folder,
            protocol: target.protocol,
            host: target.host,
            port: target.port,
            username: target.username,
            private_key_path: None,
            conflict,
        });
    }

    Ok(preview_from_parts(
        sessions,
        warnings,
        ignored_secret_field_count,
    ))
}

pub fn preview_stacio_json_import(
    input: &str,
    existing_session_names: Vec<String>,
) -> Result<ImportPreview, SessionError> {
    let bundle = serde_json::from_str::<StacioSessionExportBundle>(input)
        .map_err(|_| SessionError::InvalidQuickConnect)?;
    if bundle.format != "stacio.sessions.v1" {
        return Err(SessionError::InvalidQuickConnect);
    }

    let existing = existing_set(existing_session_names);
    let folders_by_id = folder_paths_by_id(&bundle.folders);
    let sessions = bundle
        .sessions
        .into_iter()
        .filter_map(|session| stacio_json_preview_session(session, &folders_by_id, &existing))
        .collect::<Vec<_>>();

    Ok(preview_from_parts(sessions, vec![], 0))
}

#[derive(serde::Deserialize)]
struct StacioSessionExportBundle {
    format: String,
    folders: Vec<SessionFolder>,
    sessions: Vec<SessionRecord>,
}

fn stacio_json_preview_session(
    session: SessionRecord,
    folders_by_id: &HashMap<String, String>,
    existing: &HashSet<String>,
) -> Option<ImportSessionPreview> {
    let protocol = session.protocol.trim().to_ascii_lowercase();
    if !matches!(protocol.as_str(), "ssh" | "ftp" | "telnet" | "vnc") {
        return None;
    }
    let port = u16::try_from(session.port).ok().filter(|port| *port > 0)?;
    let name = session.name.trim().to_string();
    let host = session.host.trim().to_string();
    if name.is_empty() || host.is_empty() {
        return None;
    }
    Some(ImportSessionPreview {
        conflict: existing.contains(&name.to_ascii_lowercase()),
        name,
        folder: session
            .folder_id
            .as_ref()
            .and_then(|folder_id| folders_by_id.get(folder_id).cloned()),
        protocol,
        host,
        port,
        username: session
            .username
            .map(|username| username.trim().to_string())
            .filter(|username| !username.is_empty()),
        private_key_path: session
            .private_key_path
            .map(|path| path.trim().to_string())
            .filter(|path| !path.is_empty()),
    })
}

fn folder_paths_by_id(folders: &[SessionFolder]) -> HashMap<String, String> {
    let folders_by_id = folders
        .iter()
        .map(|folder| (folder.id.clone(), folder.clone()))
        .collect::<HashMap<_, _>>();
    folders
        .iter()
        .filter_map(|folder| {
            folder_path_for(&folder.id, &folders_by_id, &mut HashSet::new())
                .map(|path| (folder.id.clone(), path))
        })
        .collect()
}

fn folder_path_for(
    folder_id: &str,
    folders_by_id: &HashMap<String, SessionFolder>,
    visiting: &mut HashSet<String>,
) -> Option<String> {
    if !visiting.insert(folder_id.to_string()) {
        return None;
    }
    let folder = folders_by_id.get(folder_id)?;
    let name = folder.name.trim();
    if name.is_empty() {
        return None;
    }
    let path = match folder.parent_id.as_ref() {
        Some(parent_id) => {
            let parent = folder_path_for(parent_id, folders_by_id, visiting)?;
            format!("{parent}/{name}")
        }
        None => name.to_string(),
    };
    visiting.remove(folder_id);
    Some(path)
}

fn parse_legacy_ini_session_target(
    input: &str,
) -> Result<Option<ParsedLegacyIniTarget>, SessionError> {
    let trimmed = input.trim();
    let Some((scheme, target)) = trimmed.split_once("://") else {
        return Ok(None);
    };
    let protocol = scheme.trim().to_ascii_lowercase();
    let Some(default_port) = default_import_port(&protocol) else {
        return Ok(None);
    };
    let (username, host_port, ignored_userinfo_secret) = match target.rsplit_once('@') {
        Some((userinfo, rest)) if !userinfo.trim().is_empty() && !rest.trim().is_empty() => {
            let (username, ignored_secret) = sanitized_url_userinfo(userinfo)?;
            (username, rest.trim(), ignored_secret)
        }
        Some(_) => return Err(SessionError::InvalidQuickConnect),
        None => (None, target.trim(), false),
    };

    let (host, port) = match host_port.rsplit_once(':') {
        Some((host, port_text)) if !host.trim().is_empty() && !port_text.trim().is_empty() => {
            let port = port_text
                .parse::<u16>()
                .map_err(|_| SessionError::InvalidPort)?;
            (host.trim().to_string(), port)
        }
        Some(_) => return Err(SessionError::InvalidQuickConnect),
        None => (host_port.trim().to_string(), default_port),
    };

    if host.is_empty() {
        return Err(SessionError::InvalidQuickConnect);
    }

    Ok(Some(ParsedLegacyIniTarget {
        target: QuickConnectTarget {
            protocol,
            username,
            host,
            port,
        },
        ignored_userinfo_secret,
    }))
}

struct ParsedLegacyIniTarget {
    target: QuickConnectTarget,
    ignored_userinfo_secret: bool,
}

fn sanitized_url_userinfo(userinfo: &str) -> Result<(Option<String>, bool), SessionError> {
    let userinfo = userinfo.trim();
    let (username, ignored_secret) = match userinfo.split_once(':') {
        Some((username, _password)) => (username.trim(), true),
        None => (userinfo, false),
    };
    if username.is_empty() {
        return Err(SessionError::InvalidQuickConnect);
    }
    Ok((Some(username.to_string()), ignored_secret))
}

fn default_import_port(protocol: &str) -> Option<u16> {
    match protocol {
        "ssh" => Some(22),
        "ftp" => Some(21),
        "telnet" => Some(23),
        "vnc" => Some(5900),
        _ => None,
    }
}

fn preview_from_parts(
    sessions: Vec<ImportSessionPreview>,
    warnings: Vec<String>,
    ignored_secret_field_count: u32,
) -> ImportPreview {
    let conflict_count = sessions.iter().filter(|session| session.conflict).count() as u32;
    ImportPreview {
        sessions,
        warnings,
        conflict_count,
        ignored_secret_field_count,
    }
}

fn split_csv_line(line: &str) -> Vec<String> {
    let mut values = Vec::new();
    let mut value = String::new();
    let mut chars = line.chars().peekable();
    let mut in_quotes = false;

    while let Some(ch) = chars.next() {
        match ch {
            '"' if in_quotes && chars.peek() == Some(&'"') => {
                value.push('"');
                chars.next();
            }
            '"' => {
                in_quotes = !in_quotes;
            }
            ',' if !in_quotes => {
                values.push(value.trim().to_string());
                value.clear();
            }
            _ => value.push(ch),
        }
    }
    values.push(value.trim().to_string());
    values
}

fn existing_set(names: Vec<String>) -> HashSet<String> {
    names
        .into_iter()
        .map(|name| name.trim().to_ascii_lowercase())
        .filter(|name| !name.is_empty())
        .collect()
}

fn value_for(
    values: &[String],
    header_index: &HashMap<String, usize>,
    name: &str,
) -> Option<String> {
    let index = *header_index.get(name)?;
    values
        .get(index)
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn required_value(
    values: &[String],
    header_index: &HashMap<String, usize>,
    name: &str,
) -> Result<String, SessionError> {
    value_for(values, header_index, name).ok_or(SessionError::InvalidQuickConnect)
}

fn csv_port_for_row(
    values: &[String],
    header_index: &HashMap<String, usize>,
    row_number: usize,
    warnings: &mut Vec<String>,
) -> Option<u16> {
    let Some(port_text) = value_for(values, header_index, "port") else {
        return Some(22);
    };
    match port_text.parse::<u16>() {
        Ok(port) if port > 0 => Some(port),
        _ => {
            warnings.push(format!("第 {row_number} 行端口无效，已跳过"));
            None
        }
    }
}

fn split_folder_name(raw_name: &str) -> (Option<String>, String) {
    match raw_name.rsplit_once('/') {
        Some((folder, name)) if !folder.is_empty() && !name.is_empty() => {
            (Some(folder.to_string()), name.to_string())
        }
        _ => (None, raw_name.to_string()),
    }
}

#[cfg(test)]
mod import_tests {
    use crate::domain::session::SessionError;

    use super::{preview_csv_import, preview_legacy_ini_import, preview_stacio_json_import};

    #[test]
    fn previews_csv_sessions_and_ignores_secret_fields() {
        let csv = include_str!("../../../tests/fixtures/import/sessions.csv");

        let preview = preview_csv_import(csv, vec!["API Server".to_string()]).expect("preview");

        assert_eq!(preview.sessions.len(), 2);
        assert_eq!(preview.sessions[0].name, "API Server");
        assert_eq!(preview.sessions[0].host, "api.example.com");
        assert_eq!(preview.sessions[0].port, 2222);
        assert_eq!(preview.sessions[0].username, Some("deploy".to_string()));
        assert_eq!(
            preview.sessions[0].private_key_path,
            Some("~/.ssh/prod".to_string())
        );
        assert_eq!(preview.conflict_count, 1);
        assert!(preview
            .warnings
            .iter()
            .any(|warning| warning.contains("密码字段，已忽略")));

        let serialized = serde_json::to_string(&preview).expect("serialize");
        assert!(!serialized.contains("do-not-import"));
    }

    #[test]
    fn previews_csv_sessions_with_quoted_commas_and_escaped_quotes() {
        let csv = "name,host,port,username,folder,private_key_path,password\n\
                   \"API, East\",\"api-east.example.com\",2222,\"deploy\",Production,\"~/.ssh/id_ed25519\",\"do-not-import\"\n\
                   \"Worker \"\"Blue\"\"\",worker.example.com,22,ops,Lab,,\n";

        let preview = preview_csv_import(csv, vec!["API, East".to_string()]).expect("preview");
        let serialized = serde_json::to_string(&preview).expect("serialize");

        assert_eq!(preview.sessions.len(), 2);
        assert_eq!(preview.sessions[0].name, "API, East");
        assert_eq!(preview.sessions[0].host, "api-east.example.com");
        assert_eq!(
            preview.sessions[0].private_key_path,
            Some("~/.ssh/id_ed25519".to_string())
        );
        assert!(preview.sessions[0].conflict);
        assert_eq!(preview.sessions[1].name, "Worker \"Blue\"");
        assert_eq!(preview.sessions[1].folder, Some("Lab".to_string()));
        assert_eq!(preview.ignored_secret_field_count, 1);
        assert!(!serialized.contains("do-not-import"));
    }

    #[test]
    fn previews_csv_skips_rows_with_invalid_ports_instead_of_defaulting_to_ssh() {
        let csv = "name,host,port,username,folder,private_key_path,password\n\
                   BadText,bad-text.example.com,abc,deploy,Production,,\n\
                   TooLarge,too-large.example.com,70000,deploy,Production,,\n\
                   Worker,worker.example.com,2200,ops,Production,,\n";

        let preview = preview_csv_import(csv, vec![]).expect("preview");

        assert_eq!(preview.sessions.len(), 1);
        assert_eq!(preview.sessions[0].name, "Worker");
        assert_eq!(preview.sessions[0].port, 2200);
        assert_eq!(preview.warnings.len(), 2);
        assert!(preview
            .warnings
            .iter()
            .any(|warning| warning.contains("第 2 行端口无效，已跳过")));
        assert!(preview
            .warnings
            .iter()
            .any(|warning| warning.contains("第 3 行端口无效，已跳过")));
    }

    #[test]
    fn previews_stacio_json_export_bundle_without_credential_references() {
        let json = r#"{
            "format": "stacio.sessions.v1",
            "exported_at": "2026-05-31T00:00:00Z",
            "folders": [
                {"id": "folder_prod", "parent_id": null, "name": "Production"}
            ],
            "sessions": [
                {
                    "id": "session_api",
                    "folder_id": "folder_prod",
                    "name": "API",
                    "protocol": "ssh",
                    "host": "api.example.com",
                    "port": 2200,
                    "username": "deploy",
                    "private_key_path": "~/.ssh/prod",
                    "credential_id": "cred_should_not_round_trip",
                    "tags": ["prod"],
                    "last_opened_at": "2026-05-31T00:00:00Z"
                }
            ]
        }"#;

        let preview = preview_stacio_json_import(json, vec![]).expect("preview json");
        let serialized = serde_json::to_string(&preview).expect("serialize");

        assert_eq!(preview.sessions.len(), 1);
        assert_eq!(preview.sessions[0].name, "API");
        assert_eq!(preview.sessions[0].folder, Some("Production".to_string()));
        assert_eq!(preview.sessions[0].protocol, "ssh");
        assert_eq!(preview.sessions[0].host, "api.example.com");
        assert_eq!(preview.sessions[0].port, 2200);
        assert_eq!(preview.sessions[0].username, Some("deploy".to_string()));
        assert_eq!(
            preview.sessions[0].private_key_path,
            Some("~/.ssh/prod".to_string())
        );
        assert!(!serialized.contains("cred_should_not_round_trip"));
        assert!(!serialized.contains("last_opened_at"));
        assert!(!serialized.contains("password"));
    }

    #[test]
    fn previews_stacio_json_nested_folder_paths() {
        let json = r#"{
            "format": "stacio.sessions.v1",
            "exported_at": "2026-05-31T00:00:00Z",
            "folders": [
                {"id": "folder_prod", "parent_id": null, "name": "Production"},
                {"id": "folder_db", "parent_id": "folder_prod", "name": "Database"},
                {"id": "folder_primary", "parent_id": "folder_db", "name": "Primary"}
            ],
            "sessions": [
                {
                    "id": "session_db",
                    "folder_id": "folder_primary",
                    "name": "Primary DB",
                    "protocol": "ssh",
                    "host": "db.example.com",
                    "port": 22,
                    "username": "deploy",
                    "private_key_path": null,
                    "credential_id": null,
                    "tags": [],
                    "last_opened_at": null
                }
            ]
        }"#;

        let preview = preview_stacio_json_import(json, vec![]).expect("preview json");

        assert_eq!(preview.sessions.len(), 1);
        assert_eq!(
            preview.sessions[0].folder,
            Some("Production/Database/Primary".to_string())
        );
    }

    #[test]
    fn previews_stacio_json_marks_existing_names_as_conflicts() {
        let json = r#"{
            "format": "stacio.sessions.v1",
            "exported_at": "2026-05-31T00:00:00Z",
            "folders": [],
            "sessions": [
                {
                    "id": "session_api",
                    "folder_id": null,
                    "name": "API",
                    "protocol": "ssh",
                    "host": "api.example.com",
                    "port": 22,
                    "username": null,
                    "private_key_path": null,
                    "credential_id": null,
                    "tags": [],
                    "last_opened_at": null
                }
            ]
        }"#;

        let preview =
            preview_stacio_json_import(json, vec!["api".to_string()]).expect("preview json");

        assert_eq!(preview.sessions.len(), 1);
        assert_eq!(preview.conflict_count, 1);
        assert!(preview.sessions[0].conflict);
    }

    #[test]
    fn preview_stacio_json_rejects_unknown_format() {
        let json = r#"{
            "format": "other.sessions.v1",
            "folders": [],
            "sessions": []
        }"#;

        let error = preview_stacio_json_import(json, vec![]).expect_err("reject unknown format");

        assert_eq!(error, SessionError::InvalidQuickConnect);
    }

    #[test]
    fn previews_legacy_ini_ini_like_sessions() {
        let text = format!(
            "{}\nProduction/FTP=ftp://files@files.example.com\n\
             Lab/Telnet=telnet://admin@router.example.com\n\
             Desktop/VNC=vnc://screen.example.com:5901\n\
             Desktop/XDMCP=xdmcp://display.example.com",
            include_str!("../../../tests/fixtures/import/legacy_ini.ini")
        );

        let preview = preview_legacy_ini_import(&text, vec![]).expect("preview");

        assert_eq!(preview.sessions.len(), 5);
        assert_eq!(preview.sessions[0].folder, Some("Production".to_string()));
        assert_eq!(preview.sessions[0].name, "API");
        assert_eq!(preview.sessions[0].host, "api.example.com");
        assert_eq!(preview.sessions[0].port, 2222);
        assert_eq!(preview.sessions[1].port, 22);
        assert_eq!(preview.sessions[2].protocol, "ftp");
        assert_eq!(preview.sessions[2].username, Some("files".to_string()));
        assert_eq!(preview.sessions[2].port, 21);
        assert_eq!(preview.sessions[3].protocol, "telnet");
        assert_eq!(preview.sessions[3].port, 23);
        assert_eq!(preview.sessions[4].protocol, "vnc");
        assert_eq!(preview.sessions[4].port, 5901);
        assert!(preview
            .warnings
            .iter()
            .any(|warning| warning.contains("密码字段，已忽略")));
        assert!(preview
            .warnings
            .iter()
            .any(|warning| warning.contains("Desktop/XDMCP 已跳过")));
        assert!(!preview
            .warnings
            .iter()
            .any(|warning| warning.contains("当前仅导入 SSH 会话")));
    }

    #[test]
    fn previews_legacy_ini_urls_strip_userinfo_passwords() {
        let text = "Production/SSH=ssh://deploy:super-secret@api.example.com:2222\n\
                    Production/FTP=ftp://files:ftp-secret@files.example.com";

        let preview = preview_legacy_ini_import(text, vec![]).expect("preview");
        let serialized = serde_json::to_string(&preview).expect("serialize");

        assert_eq!(preview.sessions.len(), 2);
        assert_eq!(preview.sessions[0].protocol, "ssh");
        assert_eq!(preview.sessions[0].username, Some("deploy".to_string()));
        assert_eq!(preview.sessions[0].host, "api.example.com");
        assert_eq!(preview.sessions[0].port, 2222);
        assert_eq!(preview.sessions[1].protocol, "ftp");
        assert_eq!(preview.sessions[1].username, Some("files".to_string()));
        assert_eq!(preview.sessions[1].host, "files.example.com");
        assert_eq!(preview.ignored_secret_field_count, 2);
        assert!(preview
            .warnings
            .iter()
            .any(|warning| warning.contains("URL 用户信息包含密码，已忽略")));
        assert!(!serialized.contains("super-secret"));
        assert!(!serialized.contains("ftp-secret"));
    }
}
