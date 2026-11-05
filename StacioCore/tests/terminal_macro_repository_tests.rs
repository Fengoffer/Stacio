use stacio_core::{
    create_terminal_macro, delete_terminal_macro, list_terminal_macros, rename_terminal_macro,
    update_terminal_macro, MacroStep,
};

fn temp_database_path() -> String {
    let file = tempfile::NamedTempFile::new().expect("create temp database");
    let (_file, path) = file.keep().expect("keep temp database");
    path.to_string_lossy().to_string()
}

fn step(order: u32, input: &str) -> MacroStep {
    MacroStep {
        order,
        input: input.to_string(),
        delay_ms: 300,
    }
}

#[test]
fn terminal_macros_persist_crud_operations_across_repository_instances() {
    let database_path = temp_database_path();

    let created = create_terminal_macro(
        database_path.clone(),
        "Deploy".to_string(),
        vec![step(1, "git pull"), step(2, "systemctl restart app")],
    )
    .expect("create macro");

    let listed = list_terminal_macros(database_path.clone()).expect("list macros");
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].id, created.id);
    assert_eq!(listed[0].name, "Deploy");
    assert_eq!(listed[0].steps.len(), 2);
    assert_eq!(listed[0].steps[0].input, "git pull");

    let renamed = rename_terminal_macro(
        database_path.clone(),
        created.id.clone(),
        "Deploy staging".to_string(),
    )
    .expect("rename macro");
    assert_eq!(renamed.name, "Deploy staging");
    assert_eq!(renamed.steps.len(), 2);

    let updated = update_terminal_macro(
        database_path.clone(),
        created.id.clone(),
        "Deploy prod".to_string(),
        vec![step(2, "second"), step(1, "first")],
    )
    .expect("update macro");
    assert_eq!(updated.name, "Deploy prod");
    assert_eq!(
        updated
            .steps
            .iter()
            .map(|step| step.input.as_str())
            .collect::<Vec<_>>(),
        vec!["first", "second"]
    );

    delete_terminal_macro(database_path.clone(), created.id).expect("delete macro");
    assert!(list_terminal_macros(database_path)
        .expect("list after delete")
        .is_empty());
}

#[test]
fn terminal_macro_repository_redacts_commands_before_storage() {
    let database_path = temp_database_path();

    let created = create_terminal_macro(
        database_path.clone(),
        "Secrets".to_string(),
        vec![step(
            1,
            "export PASSWORD=prod-password TOKEN=sk-live-123 curl -H Authorization: Bearer live-secret",
        )],
    )
    .expect("create macro");

    let restored = list_terminal_macros(database_path).expect("list macros");
    assert_eq!(restored[0].id, created.id);
    let stored_input = &restored[0].steps[0].input;
    assert!(!stored_input.contains("prod-password"));
    assert!(!stored_input.contains("sk-live-123"));
    assert!(!stored_input.contains("live-secret"));
    assert!(stored_input.contains("[redacted]"));
}
