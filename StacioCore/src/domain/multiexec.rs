#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct MultiExecTarget {
    pub id: String,
    pub label: String,
    pub environment: String,
    pub enabled: bool,
}

impl MultiExecTarget {
    pub fn new(id: &str, label: &str, environment: &str, enabled: bool) -> Self {
        Self {
            id: id.to_string(),
            label: label.to_string(),
            environment: environment.to_string(),
            enabled,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct MultiExecPlan {
    pub target_ids: Vec<String>,
    pub visible_active_state_required: bool,
    pub requires_audit: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum MultiExecError {
    #[error("no targets selected")]
    NoTargetsSelected,
    #[error("production confirmation required")]
    ProductionConfirmationRequired,
}

pub fn build_multiexec_plan(
    targets: Vec<MultiExecTarget>,
    production_confirmed: bool,
) -> Result<MultiExecPlan, MultiExecError> {
    let selected = targets
        .into_iter()
        .filter(|target| target.enabled)
        .collect::<Vec<_>>();

    if selected.is_empty() {
        return Err(MultiExecError::NoTargetsSelected);
    }

    let has_production = selected
        .iter()
        .any(|target| target.environment.trim().eq_ignore_ascii_case("production"));
    if has_production && !production_confirmed {
        return Err(MultiExecError::ProductionConfirmationRequired);
    }

    let mut seen_target_ids = std::collections::HashSet::new();
    let target_ids = selected
        .into_iter()
        .filter_map(|target| {
            if seen_target_ids.insert(target.id.clone()) {
                Some(target.id)
            } else {
                None
            }
        })
        .collect();

    Ok(MultiExecPlan {
        target_ids,
        visible_active_state_required: true,
        requires_audit: true,
    })
}

#[cfg(test)]
mod multiexec_tests {
    use super::{build_multiexec_plan, MultiExecError, MultiExecTarget};

    #[test]
    fn selects_enabled_targets() {
        let targets = vec![
            MultiExecTarget::new("term_1", "dev", "development", true),
            MultiExecTarget::new("term_2", "disabled", "development", false),
        ];

        let plan = build_multiexec_plan(targets, false).expect("plan");

        assert_eq!(plan.target_ids, vec!["term_1".to_string()]);
        assert!(plan.visible_active_state_required);
    }

    #[test]
    fn deduplicates_enabled_target_ids_preserving_first_seen_order() {
        let targets = vec![
            MultiExecTarget::new("term_1", "dev", "development", true),
            MultiExecTarget::new("term_2", "staging", "development", true),
            MultiExecTarget::new("term_1", "duplicate dev", "development", true),
        ];

        let plan = build_multiexec_plan(targets, false).expect("plan");

        assert_eq!(
            plan.target_ids,
            vec!["term_1".to_string(), "term_2".to_string()]
        );
    }

    #[test]
    fn blocks_production_without_confirmation() {
        let targets = vec![MultiExecTarget::new("term_1", "prod", "production", true)];

        let error = build_multiexec_plan(targets, false).expect_err("blocked");

        assert_eq!(error, MultiExecError::ProductionConfirmationRequired);
    }

    #[test]
    fn blocks_trimmed_production_without_confirmation() {
        let targets = vec![MultiExecTarget::new("term_1", "prod", " production ", true)];

        let error = build_multiexec_plan(targets, false).expect_err("blocked");

        assert_eq!(error, MultiExecError::ProductionConfirmationRequired);
    }

    #[test]
    fn allows_production_with_confirmation() {
        let targets = vec![MultiExecTarget::new("term_1", "prod", "production", true)];

        let plan = build_multiexec_plan(targets, true).expect("confirmed");

        assert_eq!(plan.target_ids, vec!["term_1".to_string()]);
        assert!(plan.requires_audit);
    }
}
