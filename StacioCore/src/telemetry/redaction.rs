pub fn redact_detail(key: &str, value: &str) -> String {
    let key = key.to_ascii_lowercase();
    let sensitive_parts = ["password", "passphrase", "token", "secret"];

    if sensitive_parts.iter().any(|part| key.contains(part)) {
        "[redacted]".to_string()
    } else {
        value.to_string()
    }
}
