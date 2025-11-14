// UniFFI Record types (structs passed across FFI)

#[derive(uniffi::Record)]
pub struct KeyPackageData {
    pub data: Vec<u8>,
}

#[derive(uniffi::Record)]
pub struct GroupCreationResult {
    pub group_id: Vec<u8>,
}

#[derive(uniffi::Record)]
pub struct AddMembersResult {
    pub commit_data: Vec<u8>,
    pub welcome_data: Vec<u8>,
}

#[derive(uniffi::Record)]
pub struct EncryptResult {
    pub ciphertext: Vec<u8>,
}

#[derive(uniffi::Record)]
pub struct DecryptResult {
    pub plaintext: Vec<u8>,
}

#[derive(uniffi::Record)]
pub struct KeyPackageResult {
    pub key_package_data: Vec<u8>,
    pub hash_ref: Vec<u8>,
}

#[derive(uniffi::Record)]
pub struct WelcomeResult {
    pub group_id: Vec<u8>,
}

#[derive(uniffi::Record)]
pub struct ExportedSecret {
    pub secret: Vec<u8>,
}

#[derive(uniffi::Record)]
pub struct CommitResult {
    pub new_epoch: u64,
}

#[derive(uniffi::Record, Clone)]
pub struct CredentialData {
    pub credential_type: String,
    pub identity: Vec<u8>,
}

#[derive(uniffi::Record)]
pub struct MemberCredential {
    pub credential: CredentialData,
    pub signature_key: Vec<u8>,
}

#[derive(uniffi::Record)]
pub struct StagedWelcomeInfo {
    pub group_id: Vec<u8>,
    pub sender_credential: CredentialData,
    pub member_credentials: Vec<MemberCredential>,
    pub staged_welcome_id: String,
}

#[derive(uniffi::Record)]
pub struct StagedCommitInfo {
    pub group_id: Vec<u8>,
    pub sender_credential: CredentialData,
    pub added_members: Vec<MemberCredential>,
    pub removed_members: Vec<MemberCredential>,
    pub staged_commit_id: String,
}

#[derive(uniffi::Record)]
pub struct UpdateProposalInfo {
    pub leaf_index: u32,
    pub old_credential: CredentialData,
    pub new_credential: CredentialData,
}

#[derive(uniffi::Record)]
pub struct GroupMemberDebugInfo {
    pub leaf_index: u32,
    pub credential_identity: Vec<u8>,
    pub credential_type: String,
}

#[derive(uniffi::Record)]
pub struct GroupDebugInfo {
    pub group_id: Vec<u8>,
    pub epoch: u64,
    pub total_members: u32,
    pub members: Vec<GroupMemberDebugInfo>,
}

// Proposal inspection types

#[derive(uniffi::Record)]
pub struct ProposalRef {
    pub data: Vec<u8>,
}

#[derive(uniffi::Record)]
pub struct AddProposalInfo {
    pub credential: CredentialData,
    pub key_package_ref: Vec<u8>,
}

#[derive(uniffi::Record)]
pub struct RemoveProposalInfo {
    pub removed_index: u32,
}

#[derive(uniffi::Enum)]
pub enum ProposalInfo {
    Add { info: AddProposalInfo },
    Remove { info: RemoveProposalInfo },
    Update { info: UpdateProposalInfo },
}

#[derive(uniffi::Enum)]
pub enum ProcessedContent {
    ApplicationMessage { plaintext: Vec<u8>, sender: CredentialData },
    Proposal { proposal: ProposalInfo, proposal_ref: ProposalRef },
    StagedCommit { new_epoch: u64 },
}

#[derive(uniffi::Record)]
pub struct ProcessCommitResult {
    pub new_epoch: u64,
    pub update_proposals: Vec<UpdateProposalInfo>,
}

#[derive(uniffi::Record)]
pub struct GroupConfig {
    pub max_past_epochs: u32,
    pub out_of_order_tolerance: u32,
    pub maximum_forward_distance: u32,
}

impl Default for GroupConfig {
    fn default() -> Self {
        Self {
            max_past_epochs: 5,  // Retain 5 past epochs to handle network delays and message reordering
            out_of_order_tolerance: 10,
            maximum_forward_distance: 2000,
        }
    }
}

// Logger callback trait for Swift OSLog integration
#[uniffi::export(callback_interface)]
pub trait MLSLogger: Send + Sync {
    /// Log a message from Rust to Swift's OSLog
    /// - level: "debug", "info", "warning", "error"
    /// - message: The log message
    fn log(&self, level: String, message: String);
}

// Epoch secret storage callback trait for Swift encrypted storage
#[uniffi::export(callback_interface)]
pub trait EpochSecretStorage: Send + Sync {
    /// Store epoch secret for a conversation
    /// - conversation_id: Hex-encoded conversation/group ID
    /// - epoch: Epoch number
    /// - secret_data: Serialized epoch secret material
    /// Returns true if stored successfully
    fn store_epoch_secret(&self, conversation_id: String, epoch: u64, secret_data: Vec<u8>) -> bool;

    /// Retrieve epoch secret for a conversation
    /// - conversation_id: Hex-encoded conversation/group ID
    /// - epoch: Epoch number
    /// Returns serialized epoch secret material if found
    fn get_epoch_secret(&self, conversation_id: String, epoch: u64) -> Option<Vec<u8>>;

    /// Delete epoch secret (called during retention cleanup)
    /// - conversation_id: Hex-encoded conversation/group ID
    /// - epoch: Epoch number
    /// Returns true if deleted successfully
    fn delete_epoch_secret(&self, conversation_id: String, epoch: u64) -> bool;
}
