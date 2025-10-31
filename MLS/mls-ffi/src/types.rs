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
    ApplicationMessage { plaintext: Vec<u8> },
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
            max_past_epochs: 0,  // Best forward secrecy - no old epochs retained
            out_of_order_tolerance: 10,
            maximum_forward_distance: 2000,
        }
    }
}
