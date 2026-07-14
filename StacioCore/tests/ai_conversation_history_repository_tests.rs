use stacio_core::{
    append_ai_conversation_history_item, clear_ai_conversation_history,
    list_ai_conversation_history, AIConversationHistoryItemDraft,
};

fn temp_database_path() -> String {
    let file = tempfile::NamedTempFile::new().expect("create temp database");
    let (_file, path) = file.keep().expect("keep temp database");
    path.to_string_lossy().to_string()
}

#[test]
fn ai_conversation_history_persists_by_runtime_across_repository_instances() {
    let database_path = temp_database_path();

    let user = append_ai_conversation_history_item(
        database_path.clone(),
        AIConversationHistoryItemDraft {
            runtime_id: "runtime-a".to_string(),
            role: "user".to_string(),
            content: "看一下磁盘".to_string(),
            request_id: None,
        },
    )
    .expect("append user message");
    let assistant = append_ai_conversation_history_item(
        database_path.clone(),
        AIConversationHistoryItemDraft {
            runtime_id: "runtime-a".to_string(),
            role: "assistant".to_string(),
            content: "建议先运行 df -h。".to_string(),
            request_id: Some("req-1".to_string()),
        },
    )
    .expect("append assistant message");
    append_ai_conversation_history_item(
        database_path.clone(),
        AIConversationHistoryItemDraft {
            runtime_id: "runtime-b".to_string(),
            role: "user".to_string(),
            content: "另一个会话".to_string(),
            request_id: None,
        },
    )
    .expect("append other runtime message");

    let restored = list_ai_conversation_history(database_path, "runtime-a".to_string())
        .expect("list runtime history");

    assert_eq!(restored, vec![user, assistant]);
    assert_eq!(restored[0].role, "user");
    assert_eq!(restored[1].request_id.as_deref(), Some("req-1"));
}

#[test]
fn ai_conversation_history_keeps_recent_thirty_and_truncates_large_entries() {
    let database_path = temp_database_path();
    let oversized = "密".repeat(900);

    for index in 0..35 {
        append_ai_conversation_history_item(
            database_path.clone(),
            AIConversationHistoryItemDraft {
                runtime_id: "runtime-a".to_string(),
                role: "assistant".to_string(),
                content: if index == 34 {
                    oversized.clone()
                } else {
                    format!("message-{index}")
                },
                request_id: Some(format!("req-{index}")),
            },
        )
        .expect("append history item");
    }

    let restored = list_ai_conversation_history(database_path, "runtime-a".to_string())
        .expect("list runtime history");

    assert_eq!(restored.len(), 30);
    assert_eq!(restored[0].content, "message-5");
    assert_eq!(restored[29].request_id.as_deref(), Some("req-34"));
    assert!(restored[29].content.len() < oversized.len());
    assert!(restored[29].content.len() <= 2_048);
}

#[test]
fn ai_conversation_history_clear_removes_all_runtimes() {
    let database_path = temp_database_path();
    append_ai_conversation_history_item(
        database_path.clone(),
        AIConversationHistoryItemDraft {
            runtime_id: "runtime-a".to_string(),
            role: "user".to_string(),
            content: "保留前".to_string(),
            request_id: None,
        },
    )
    .expect("append runtime a");
    append_ai_conversation_history_item(
        database_path.clone(),
        AIConversationHistoryItemDraft {
            runtime_id: "runtime-b".to_string(),
            role: "assistant".to_string(),
            content: "另一个会话".to_string(),
            request_id: None,
        },
    )
    .expect("append runtime b");

    clear_ai_conversation_history(database_path.clone()).expect("clear history");

    assert!(
        list_ai_conversation_history(database_path.clone(), "runtime-a".to_string())
            .expect("list runtime a")
            .is_empty()
    );
    assert!(
        list_ai_conversation_history(database_path, "runtime-b".to_string())
            .expect("list runtime b")
            .is_empty()
    );
}
