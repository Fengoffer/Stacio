#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct CredentialRecord {
    pub id: String,
    pub kind: String,
    pub label: String,
    pub keychain_service: String,
    pub keychain_account: String,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct CredentialDraft {
    pub kind: String,
    pub label: String,
    pub keychain_service: String,
    pub keychain_account: String,
}
