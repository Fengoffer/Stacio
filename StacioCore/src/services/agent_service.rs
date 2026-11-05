use crate::domain::agent::AgentActionAuditEvent;

pub fn validate_agent_action_audit_event(event: &AgentActionAuditEvent) -> Result<(), String> {
    if event.request_id.trim().is_empty() {
        return Err("request_id is required".to_string());
    }
    if event.actor_name.trim().is_empty() {
        return Err("actor_name is required".to_string());
    }
    if event.target_title.trim().is_empty() {
        return Err("target_title is required".to_string());
    }
    Ok(())
}
