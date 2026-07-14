#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct AgentActionAuditEvent {
    pub request_id: String,
    pub actor_kind: String,
    pub actor_name: String,
    pub target_runtime_id: Option<String>,
    pub target_title: String,
    pub action_kind: String,
    pub risk: String,
    pub state: String,
    pub redacted_input: String,
    pub environment: String,
    pub approval_mode: String,
    pub policy_decision: String,
    pub redaction_version: String,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct AgentTaskSessionDraft {
    pub id: String,
    pub request_id: String,
    pub actor_kind: String,
    pub actor_name: String,
    pub target_runtime_id: Option<String>,
    pub target_title: String,
    pub state: String,
    pub user_prompt: String,
    pub assistant_message: String,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct AgentTaskProposalDraft {
    pub id: String,
    pub command: String,
    pub explanation: String,
    pub risk: String,
    pub state: String,
    pub sort_order: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct AIConversationHistoryItemDraft {
    pub runtime_id: String,
    pub role: String,
    pub content: String,
    pub request_id: Option<String>,
}
