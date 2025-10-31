use thiserror::Error;

#[derive(Error, Debug, uniffi::Error)]
#[uniffi(flat_error)]
pub enum MLSError {
    #[error("Invalid input: {message}")]
    InvalidInput { message: String },
    
    #[error("Group not found: {message}")]
    GroupNotFound { message: String },
    
    #[error("Invalid key package")]
    InvalidKeyPackage,
    
    #[error("Failed to add members")]
    AddMembersFailed,
    
    #[error("Encryption failed")]
    EncryptionFailed,
    
    #[error("Decryption failed")]
    DecryptionFailed,
    
    #[error("Serialization error")]
    SerializationError,
    
    #[error("OpenMLS error")]
    OpenMLSError,
    
    #[error("Invalid group ID")]
    InvalidGroupId,
    
    #[error("Secret export failed")]
    SecretExportFailed,
    
    #[error("Commit processing failed")]
    CommitProcessingFailed,
    
    #[error("Invalid commit")]
    InvalidCommit,
    
    #[error("Invalid data")]
    InvalidData,
    
    #[error("Context not initialized")]
    ContextNotInitialized,

    #[error("Wire format policy violation: {message}")]
    WireFormatPolicyViolation { message: String },

    #[error("Merge failed")]
    MergeFailed,
}

impl MLSError {
    pub fn invalid_input(msg: impl Into<String>) -> Self {
        Self::InvalidInput { message: msg.into() }
    }

    pub fn group_not_found(msg: impl Into<String>) -> Self {
        Self::GroupNotFound { message: msg.into() }
    }

    pub fn wire_format_policy_violation(msg: impl Into<String>) -> Self {
        Self::WireFormatPolicyViolation { message: msg.into() }
    }
}
