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
fn ai_conversation_history_keeps_all_items_and_truncates_large_entries() {
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

    assert_eq!(restored.len(), 35);
    assert_eq!(restored[0].content, "message-0");
    assert_eq!(restored[34].request_id.as_deref(), Some("req-34"));
    assert!(restored[34].content.len() < oversized.len());
    assert!(restored[34].content.len() <= 2_048);
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

// MARK: - C-6 契约：2048 字节边界 / 前缀保留 / 旧 role 数据保留

/// 内容恰好 2_048 字节 → 不截断（边界值）。
#[test]
fn ai_conversation_history_preserves_exact_2048_byte_content() {
    let database_path = temp_database_path();
    let content = "a".repeat(2_048);
    append_ai_conversation_history_item(
        database_path.clone(),
        AIConversationHistoryItemDraft {
            runtime_id: "runtime-a".to_string(),
            role: "assistant".to_string(),
            content: content.clone(),
            request_id: None,
        },
    )
    .expect("append exact 2048-byte content");

    let restored = list_ai_conversation_history(database_path, "runtime-a".to_string())
        .expect("list runtime history");
    assert_eq!(restored.len(), 1);
    assert_eq!(restored[0].content.len(), 2_048, "恰好 2048 字节不得截断");
    assert_eq!(restored[0].content, content, "边界值内容逐字节保留");
}

/// 2_049 字节 → 截断到 ≤2_048 且保留前缀（不破坏 UTF-8）。
#[test]
fn ai_conversation_history_truncates_2049_bytes_to_at_most_2048_preserving_prefix() {
    let database_path = temp_database_path();
    let content = "b".repeat(2_049);
    append_ai_conversation_history_item(
        database_path.clone(),
        AIConversationHistoryItemDraft {
            runtime_id: "runtime-a".to_string(),
            role: "assistant".to_string(),
            content: content.clone(),
            request_id: None,
        },
    )
    .expect("append oversized content");

    let restored = list_ai_conversation_history(database_path, "runtime-a".to_string())
        .expect("list runtime history");
    assert!(
        restored[0].content.len() <= 2_048,
        "超限内容必须截断到 2048 以内"
    );
    assert!(
        content.starts_with(&restored[0].content),
        "截断必须保留前缀（V1 展示只读语义）"
    );
}

/// 旧 role（human/system 等）数据 roundtrip 保留；「按 user/assistant 标签展示」由读取/展示层映射。
#[test]
fn ai_conversation_history_preserves_legacy_roles_for_display_layer_mapping() {
    let database_path = temp_database_path();
    append_ai_conversation_history_item(
        database_path.clone(),
        AIConversationHistoryItemDraft {
            runtime_id: "runtime-a".to_string(),
            role: "human".to_string(),
            content: "旧版本消息".to_string(),
            request_id: None,
        },
    )
    .expect("append legacy human role");
    append_ai_conversation_history_item(
        database_path.clone(),
        AIConversationHistoryItemDraft {
            runtime_id: "runtime-a".to_string(),
            role: "system".to_string(),
            content: "旧系统消息".to_string(),
            request_id: None,
        },
    )
    .expect("append legacy system role");

    let restored = list_ai_conversation_history(database_path, "runtime-a".to_string())
        .expect("list runtime history");
    assert_eq!(
        restored[0].role, "human",
        "旧 role 数据必须原样保留（展示层负责标签映射）"
    );
    assert_eq!(restored[1].role, "system");
}
