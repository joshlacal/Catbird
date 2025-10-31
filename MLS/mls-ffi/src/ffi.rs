use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;
use std::slice;
use std::sync::{Arc, Mutex};
use std::collections::HashMap;

use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;
use tls_codec::{Deserialize as TlsDeserialize};

use crate::error::{MLSError, Result};
use crate::mls_context::MLSContext;

static CONTEXTS: Mutex<Option<HashMap<usize, Arc<MLSContext>>>> = Mutex::new(None);
static NEXT_CONTEXT_ID: Mutex<usize> = Mutex::new(1);

/// FFI-safe result type
#[repr(C)]
pub struct MLSResult {
    pub success: bool,
    pub error_message: *mut c_char,
    pub data: *mut u8,
    pub data_len: usize,
}

impl MLSResult {
    pub fn ok(data: Vec<u8>) -> Self {
        let len = data.len();
        let ptr = if len > 0 {
            Box::into_raw(data.into_boxed_slice()) as *mut u8
        } else {
            ptr::null_mut()
        };
        Self {
            success: true,
            error_message: ptr::null_mut(),
            data: ptr,
            data_len: len,
        }
    }

    pub fn err(error: MLSError) -> Self {
        Self {
            success: false,
            error_message: error.to_c_string(),
            data: ptr::null_mut(),
            data_len: 0,
        }
    }
}

/// Initialize the MLS FFI library
/// Returns a context handle for subsequent operations
#[no_mangle]
pub extern "C" fn mls_init() -> usize {
    let mut contexts_guard = match CONTEXTS.lock() {
        Ok(guard) => guard,
        Err(_) => return 0,
    };
    
    let contexts = contexts_guard.get_or_insert_with(HashMap::new);
    
    let mut next_id_guard = match NEXT_CONTEXT_ID.lock() {
        Ok(guard) => guard,
        Err(_) => return 0,
    };
    
    let context_id = *next_id_guard;
    *next_id_guard += 1;
    
    let context = Arc::new(MLSContext::new());
    contexts.insert(context_id, context);
    
    context_id
}

/// Free an MLS context
#[no_mangle]
pub extern "C" fn mls_free_context(context_id: usize) {
    if let Ok(mut contexts_guard) = CONTEXTS.lock() {
        if let Some(contexts) = contexts_guard.as_mut() {
            contexts.remove(&context_id);
        }
    }
}

fn get_context(context_id: usize) -> Result<Arc<MLSContext>> {
    let contexts_guard = CONTEXTS.lock()
        .map_err(|_| MLSError::ThreadSafety("Failed to acquire lock".to_string()))?;
    
    let contexts = contexts_guard.as_ref()
        .ok_or(MLSError::InvalidContext)?;
    
    contexts.get(&context_id)
        .cloned()
        .ok_or(MLSError::InvalidContext)
}

// Security limits for FFI inputs
const MAX_IDENTITY_LEN: usize = 1024;
const MAX_KEY_PACKAGES_LEN: usize = 10 * 1024 * 1024; // 10MB
const MAX_MESSAGE_LEN: usize = 100 * 1024 * 1024; // 100MB
const MAX_GROUP_ID_LEN: usize = 256;

fn validate_input_len(len: usize, max: usize, name: &'static str) -> Result<()> {
    if len > max {
        return Err(MLSError::InvalidInput(
            format!("{} length {} exceeds maximum {}", name, len, max)
        ));
    }
    Ok(())
}

fn safe_slice<'a>(ptr: *const u8, len: usize, name: &'static str) -> Result<&'a [u8]> {
    if ptr.is_null() {
        return Err(MLSError::NullPointer(name));
    }
    if len == 0 {
        return Ok(&[]);
    }
    unsafe { Ok(slice::from_raw_parts(ptr, len)) }
}

/// Create a new MLS group
/// Returns serialized group ID
#[no_mangle]
pub extern "C" fn mls_create_group(
    context_id: usize,
    identity_bytes: *const u8,
    identity_len: usize,
) -> MLSResult {
    let result: Result<Vec<u8>> = (|| {
        validate_input_len(identity_len, MAX_IDENTITY_LEN, "identity")?;
        let context = get_context(context_id)?;
        let identity = safe_slice(identity_bytes, identity_len, "identity")?;
        
        let credential = Credential::new(identity.to_vec(), CredentialType::Basic)
            .map_err(|e| MLSError::OpenMLS(e.to_string()))?;
        
        let signature_keypair = SignatureKeyPair::new(SignatureScheme::ED25519)
            .map_err(|e| MLSError::OpenMLS(e.to_string()))?;
        
        signature_keypair.store(context.provider().key_store())
            .map_err(|e| MLSError::OpenMLS(e.to_string()))?;
        
        let credential_with_key = CredentialWithKey {
            credential: credential.clone(),
            signature_key: signature_keypair.public().into(),
        };
        
        let group_config = MlsGroupConfig::default();
        
        let group = MlsGroup::new(
            context.provider(),
            &signature_keypair,
            &group_config,
            credential_with_key,
        ).map_err(|e| MLSError::OpenMLS(e.to_string()))?;
        
        // Keep signer for this identity and group
        let signer_arc = std::sync::Arc::new(signature_keypair);
        context.set_identity_signer(identity.to_vec(), std::sync::Arc::clone(&signer_arc))?;
        
        let group_id_bytes = group.group_id().as_slice().to_vec();
        context.add_group(group_id_bytes.clone(), group, signer_arc)?;
        
        Ok(group_id_bytes)
    })();
    
    match result {
        Ok(data) => MLSResult::ok(data),
        Err(e) => MLSResult::err(e),
    }
}

/// Add members to an MLS group
/// Input: TLS-encoded KeyPackage bytes concatenated
/// Output: [commit_len_le: u64][commit_bytes][welcome_bytes]
#[no_mangle]
pub extern "C" fn mls_add_members(
    context_id: usize,
    group_id: *const u8,
    group_id_len: usize,
    key_packages_bytes: *const u8,
    key_packages_len: usize,
) -> MLSResult {
    let result: Result<Vec<u8>> = (|| {
        validate_input_len(group_id_len, MAX_GROUP_ID_LEN, "group_id")?;
        validate_input_len(key_packages_len, MAX_KEY_PACKAGES_LEN, "key_packages")?;
        
        let context = get_context(context_id)?;
        let gid = safe_slice(group_id, group_id_len, "group_id")?;
        let kp_bytes = safe_slice(key_packages_bytes, key_packages_len, "key_packages")?;

        if kp_bytes.is_empty() {
            return Err(MLSError::InvalidInput("No key packages provided".to_string()));
        }

        // Parse KeyPackages from JSON
        // Two supported formats:
        // 1. Array of KeyPackage objects (direct serde): [{"payload": {...}, "signature": "..."}, ...]
        // 2. Array with tls_serialized field: [{"tls_serialized": "base64..."}, ...]
        
        let key_packages: Vec<KeyPackage> = if let Ok(kps) = serde_json::from_slice::<Vec<KeyPackage>>(kp_bytes) {
            // Direct serde format (full KeyPackage JSON)
            kps
        } else {
            // Try tls_serialized format
            let json_packages: Vec<serde_json::Value> = serde_json::from_slice(kp_bytes)
                .map_err(|e| MLSError::Serialization(e))?;
            
            // Convert TLS bytes to KeyPackages via MlsMessageIn wrapper
            json_packages.iter()
                .map(|pkg| {
                    let tls_b64 = pkg.get("tls_serialized")
                        .and_then(|v| v.as_str())
                        .ok_or_else(|| MLSError::InvalidInput("Missing tls_serialized field".to_string()))?;
                    
                    let tls_bytes = base64::Engine::decode(&base64::engine::general_purpose::STANDARD, tls_b64)
                        .map_err(|e| MLSError::InvalidInput(format!("Invalid base64: {}", e)))?;
                    
                    // Wrap in MlsMessageIn to deserialize
                    let mls_msg = MlsMessageIn::tls_deserialize(&mut &tls_bytes[..])
                        .map_err(|e| MLSError::TlsCodec(format!("Failed to deserialize: {}", e)))?;
                    
                    // Extract KeyPackage from message and validate
                    match mls_msg.extract() {
                        MlsMessageInBody::KeyPackage(kp_in) => {
                            // Validate KeyPackageIn to get KeyPackage
                            let kp = kp_in.validate(context.provider().crypto(), ProtocolVersion::default())
                                .map_err(|e| MLSError::OpenMLS(format!("KeyPackage validation failed: {}", e)))?;
                            Ok(kp)
                        },
                        _ => Err(MLSError::InvalidInput("Message is not a KeyPackage".to_string())),
                    }
                })
                .collect::<Result<Vec<KeyPackage>>>()?
        };

        if key_packages.is_empty() {
            return Err(MLSError::InvalidInput("KeyPackage array is empty".to_string()));
        }
        
        let signer = context.signer_for_group(gid)?;
        context.with_group(gid, |group| {
            let (commit, welcome, _group_info) = group
                .add_members(context.provider(), signer.as_ref(), &key_packages)
                .map_err(|e| MLSError::OpenMLS(e.to_string()))?;
            
            group.merge_pending_commit(context.provider())
                .map_err(|e| MLSError::OpenMLS(e.to_string()))?;
            
            let commit_bytes = commit
                .tls_serialize_detached()
                .map_err(|e| MLSError::TlsCodec(e.to_string()))?;
            let welcome_bytes = welcome
                .tls_serialize_detached()
                .map_err(|e| MLSError::TlsCodec(e.to_string()))?;

            let mut out = Vec::with_capacity(8 + commit_bytes.len() + welcome_bytes.len());
            out.extend_from_slice(&(commit_bytes.len() as u64).to_le_bytes());
            out.extend_from_slice(&commit_bytes);
            out.extend_from_slice(&welcome_bytes);
            Ok(out)
        })
    })();
    
    match result {
        Ok(data) => MLSResult::ok(data),
        Err(e) => MLSResult::err(e),
    }
}

/// Encrypt a message for the group
#[no_mangle]
pub extern "C" fn mls_encrypt_message(
    context_id: usize,
    group_id: *const u8,
    group_id_len: usize,
    plaintext: *const u8,
    plaintext_len: usize,
) -> MLSResult {
    let result: Result<Vec<u8>> = (|| {
        validate_input_len(group_id_len, MAX_GROUP_ID_LEN, "group_id")?;
        validate_input_len(plaintext_len, MAX_MESSAGE_LEN, "plaintext")?;
        
        let context = get_context(context_id)?;
        let gid = safe_slice(group_id, group_id_len, "group_id")?;
        let pt = safe_slice(plaintext, plaintext_len, "plaintext")?;
        
        let signer = context.signer_for_group(gid)?;
        context.with_group(gid, |group| {
            let mls_message = group
                .create_message(context.provider(), signer.as_ref(), pt)
                .map_err(|e| MLSError::OpenMLS(e.to_string()))?;
            
            mls_message.tls_serialize_detached()
                .map_err(|e| MLSError::TlsCodec(e.to_string()))
        })
    })();
    
    match result {
        Ok(data) => MLSResult::ok(data),
        Err(e) => MLSResult::err(e),
    }
}

/// Decrypt a message from the group
#[no_mangle]
pub extern "C" fn mls_decrypt_message(
    context_id: usize,
    group_id: *const u8,
    group_id_len: usize,
    ciphertext: *const u8,
    ciphertext_len: usize,
) -> MLSResult {
    let result: Result<Vec<u8>> = (|| {
        validate_input_len(group_id_len, MAX_GROUP_ID_LEN, "group_id")?;
        validate_input_len(ciphertext_len, MAX_MESSAGE_LEN, "ciphertext")?;
        
        let context = get_context(context_id)?;
        let gid = safe_slice(group_id, group_id_len, "group_id")?;
        let ct = safe_slice(ciphertext, ciphertext_len, "ciphertext")?;
        
        context.with_group(gid, |group| {
            let mls_message_in = MlsMessageIn::tls_deserialize(&mut &ct[..])
                .map_err(|e| MLSError::TlsCodec(e.to_string()))?;
            // Convert to protocol message based on variant
            let protocol_message: ProtocolMessage = match mls_message_in.extract() {
                MlsMessageInBody::PublicMessage(pm) => pm.into(),
                MlsMessageInBody::PrivateMessage(pm) => pm.into(),
                other => {
                    return Err(MLSError::Internal(format!("Unexpected message type: {:?}", other)));
                }
            };
            
            let processed_message = group
                .process_message(context.provider(), protocol_message)
                .map_err(|e| MLSError::OpenMLS(e.to_string()))?;
            
            let plaintext = match processed_message.into_content() {
                ProcessedMessageContent::ApplicationMessage(app_msg) => {
                    app_msg.into_bytes().to_vec()
                },
                ProcessedMessageContent::ProposalMessage(_) => {
                    return Err(MLSError::Internal("Received proposal, not application message".to_string()));
                },
                ProcessedMessageContent::ExternalJoinProposalMessage(_) => {
                    return Err(MLSError::Internal("Received external join proposal".to_string()));
                },
                ProcessedMessageContent::StagedCommitMessage(_) => {
                    return Err(MLSError::Internal("Received staged commit".to_string()));
                },
            };
            
            Ok(plaintext)
        })
    })();
    
    match result {
        Ok(data) => MLSResult::ok(data),
        Err(e) => MLSResult::err(e),
    }
}

/// Create a key package for joining groups
#[no_mangle]
pub extern "C" fn mls_create_key_package(
    context_id: usize,
    identity_bytes: *const u8,
    identity_len: usize,
) -> MLSResult {
    let result: Result<Vec<u8>> = (|| {
        validate_input_len(identity_len, MAX_IDENTITY_LEN, "identity")?;
        let context = get_context(context_id)?;
        let identity = safe_slice(identity_bytes, identity_len, "identity")?;
        
        let credential = Credential::new(identity.to_vec(), CredentialType::Basic)
            .map_err(|e| MLSError::OpenMLS(e.to_string()))?;
        
        let signature_keypair = SignatureKeyPair::new(SignatureScheme::ED25519)
            .map_err(|e| MLSError::OpenMLS(e.to_string()))?;
        
        signature_keypair.store(context.provider().key_store())
            .map_err(|e| MLSError::OpenMLS(e.to_string()))?;
        
        let credential_with_key = CredentialWithKey {
            credential: credential.clone(),
            signature_key: signature_keypair.public().into(),
        };
        
        let key_package = KeyPackage::builder()
            .build(
                CryptoConfig::default(),
                context.provider(),
                &signature_keypair,
                credential_with_key,
            )
            .map_err(|e| MLSError::OpenMLS(e.to_string()))?;
        
        // Store signer by key package reference for later use in process_welcome
        let key_package_ref = key_package.hash_ref(context.provider().crypto())
            .map_err(|e| MLSError::OpenMLS(e.to_string()))?;
        let signer_arc = Arc::new(signature_keypair);
        context.set_key_package_signer(key_package_ref.as_slice().to_vec(), Arc::clone(&signer_arc))?;
        context.set_identity_signer(identity.to_vec(), signer_arc)?;
        
        let serialized = key_package.tls_serialize_detached()
            .map_err(|e| MLSError::TlsCodec(e.to_string()))?;
        
        Ok(serialized)
    })();
    
    match result {
        Ok(data) => MLSResult::ok(data),
        Err(e) => MLSResult::err(e),
    }
}

/// Process a Welcome message to join a group
#[no_mangle]
pub extern "C" fn mls_process_welcome(
    context_id: usize,
    welcome_bytes: *const u8,
    welcome_len: usize,
    _identity_bytes: *const u8,
    _identity_len: usize,
) -> MLSResult {
    let result: Result<Vec<u8>> = (|| {
        validate_input_len(welcome_len, MAX_MESSAGE_LEN, "welcome")?;
        validate_input_len(_identity_len, MAX_IDENTITY_LEN, "identity")?;
        
        let context = get_context(context_id)?;
        let welcome_data = safe_slice(welcome_bytes, welcome_len, "welcome")?;
        
        let mls_message_in = MlsMessageIn::tls_deserialize(&mut &welcome_data[..])
            .map_err(|e| MLSError::TlsCodec(format!("Failed to deserialize Welcome: {}", e)))?;
        
        let welcome = match mls_message_in.extract() {
            MlsMessageInBody::Welcome(w) => w,
            _ => return Err(MLSError::InvalidInput("Not a Welcome message".to_string())),
        };
        
        // Try to find signer by key package reference first (more reliable)
        // Welcome contains key_package_ref that we can use to lookup the signer
        let identity = safe_slice(_identity_bytes, _identity_len, "identity")?;
        
        // Fallback to identity-based lookup (may fail if not properly stored)
        let signer = context.signer_for_identity(identity)
            .or_else(|_| {
                // If identity lookup fails, try all stored key package signers
                // This is a fallback for robustness
                Err(MLSError::Internal(
                    "No matching signer found. Ensure key package was created with this identity.".to_string()
                ))
            })?;
        
        let group = MlsGroup::new_from_welcome(
            context.provider(),
            &MlsGroupConfig::default(),
            welcome,
            None,
        ).map_err(|e| MLSError::OpenMLS(format!("Failed to process Welcome: {}", e)))?;
        
        let group_id = group.group_id().as_slice().to_vec();
        context.add_group(group_id.clone(), group, signer)?;
        
        Ok(group_id)
    })();
    
    match result {
        Ok(data) => MLSResult::ok(data),
        Err(e) => MLSResult::err(e),
    }
}

/// Export a secret from the group's key schedule
#[no_mangle]
pub extern "C" fn mls_export_secret(
    context_id: usize,
    group_id: *const u8,
    group_id_len: usize,
    label: *const c_char,
    context_bytes: *const u8,
    context_len: usize,
    key_length: usize,
) -> MLSResult {
    let result: Result<Vec<u8>> = (|| {
        let ctx = get_context(context_id)?;
        let gid = safe_slice(group_id, group_id_len, "group_id")?;
        let context_data = safe_slice(context_bytes, context_len, "context")?;
        
        if label.is_null() {
            return Err(MLSError::NullPointer("label"));
        }
        
        let label_str = unsafe {
            CStr::from_ptr(label)
                .to_str()
                .map_err(|e| MLSError::InvalidUtf8(e))?
        };
        
        ctx.with_group(gid, |group| {
            let secret = group
                .export_secret(ctx.provider(), label_str, context_data, key_length)
                .map_err(|e| MLSError::OpenMLS(e.to_string()))?;
            
            Ok(secret.to_vec())
        })
    })();
    
    match result {
        Ok(data) => MLSResult::ok(data),
        Err(e) => MLSResult::err(e),
    }
}

/// Get the current epoch of the group
#[no_mangle]
pub extern "C" fn mls_get_epoch(
    context_id: usize,
    group_id: *const u8,
    group_id_len: usize,
) -> u64 {
    let result: Result<u64> = (|| {
        let context = get_context(context_id)?;
        let gid = safe_slice(group_id, group_id_len, "group_id")?;
        
        context.with_group(gid, |group| {
            Ok(group.epoch().as_u64())
        })
    })();
    
    result.unwrap_or(0)
}

/// Process a commit message and update group state
/// This is used for epoch synchronization - processing commits from other members
/// to keep the local group state up-to-date with the server's current epoch.
///
/// # Arguments
/// * `context_id` - The MLS context handle
/// * `group_id` - The group identifier
/// * `commit_bytes` - TLS-encoded MlsMessage containing a commit
///
/// # Returns
/// MLSResult with success=true if commit was processed successfully,
/// or success=false with error message on failure.
#[no_mangle]
pub extern "C" fn mls_process_commit(
    context_id: usize,
    group_id: *const u8,
    group_id_len: usize,
    commit_bytes: *const u8,
    commit_len: usize,
) -> MLSResult {
    let result: Result<Vec<u8>> = (|| {
        validate_input_len(group_id_len, MAX_GROUP_ID_LEN, "group_id")?;
        validate_input_len(commit_len, MAX_MESSAGE_LEN, "commit")?;
        
        let context = get_context(context_id)?;
        let gid = safe_slice(group_id, group_id_len, "group_id")?;
        let commit_data = safe_slice(commit_bytes, commit_len, "commit")?;
        
        context.with_group(gid, |group| {
            // Deserialize the MLS message
            let mls_message_in = MlsMessageIn::tls_deserialize(&mut &commit_data[..])
                .map_err(|e| MLSError::TlsCodec(format!("Failed to deserialize commit: {}", e)))?;
            
            // Convert to protocol message - commits can be PublicMessage or PrivateMessage
            let protocol_message: ProtocolMessage = match mls_message_in.extract() {
                MlsMessageInBody::PublicMessage(pm) => pm.into(),
                MlsMessageInBody::PrivateMessage(pm) => pm.into(),
                other => {
                    return Err(MLSError::InvalidInput(format!(
                        "Expected commit message, got: {:?}", other
                    )));
                }
            };
            
            // Process the message - this will stage the commit
            let processed_message = group
                .process_message(context.provider(), protocol_message)
                .map_err(|e| MLSError::OpenMLS(format!("Failed to process commit: {}", e)))?;
            
            // Verify this is a commit and extract Update proposals before merging
            match processed_message.into_content() {
                ProcessedMessageContent::StagedCommitMessage(staged_commit) => {
                    // Extract Update proposals with credentials before merging
                    let update_proposals: Vec<(u32, Vec<u8>, Vec<u8>)> = staged_commit
                        .add_proposals()
                        .iter()
                        .chain(staged_commit.update_proposals().iter())
                        .filter_map(|queued_proposal| {
                            // Check if this is an Update proposal
                            match queued_proposal.proposal() {
                                Proposal::Update(update_proposal) => {
                                    // Get the leaf node with new credential
                                    let leaf_node = update_proposal.leaf_node();
                                    let new_credential = leaf_node.credential();

                                    // Get leaf index from queued proposal
                                    let leaf_index = queued_proposal.sender().as_u32();

                                    // Get old credential from current group state
                                    if let Some(old_member) = group.members().find(|m| m.index.as_u32() == leaf_index) {
                                        let old_cred_bytes = match old_member.credential.credential_type() {
                                            CredentialType::Basic => old_member.credential.serialized_content().to_vec(),
                                            _ => vec![],
                                        };

                                        let new_cred_bytes = match new_credential.credential_type() {
                                            CredentialType::Basic => new_credential.serialized_content().to_vec(),
                                            _ => vec![],
                                        };

                                        Some((leaf_index, old_cred_bytes, new_cred_bytes))
                                    } else {
                                        None
                                    }
                                },
                                _ => None,
                            }
                        })
                        .collect();

                    // Merge the staged commit to update group state
                    group.merge_staged_commit(context.provider(), *staged_commit)
                        .map_err(|e| MLSError::OpenMLS(format!("Failed to merge commit: {}", e)))?;

                    // Return the new epoch and update proposals
                    let new_epoch = group.epoch().as_u64();

                    // Serialize update proposals as: [epoch: u64][num_updates: u32]([index: u32][old_len: u32][old_cred][new_len: u32][new_cred])*
                    let mut result = Vec::new();
                    result.extend_from_slice(&new_epoch.to_le_bytes());
                    result.extend_from_slice(&(update_proposals.len() as u32).to_le_bytes());

                    for (index, old_cred, new_cred) in update_proposals {
                        result.extend_from_slice(&index.to_le_bytes());
                        result.extend_from_slice(&(old_cred.len() as u32).to_le_bytes());
                        result.extend_from_slice(&old_cred);
                        result.extend_from_slice(&(new_cred.len() as u32).to_le_bytes());
                        result.extend_from_slice(&new_cred);
                    }

                    Ok(result)
                },
                ProcessedMessageContent::ApplicationMessage(_) => {
                    Err(MLSError::InvalidInput("Expected commit, got application message".to_string()))
                },
                ProcessedMessageContent::ProposalMessage(_) => {
                    Err(MLSError::InvalidInput("Expected commit, got proposal".to_string()))
                },
                ProcessedMessageContent::ExternalJoinProposalMessage(_) => {
                    Err(MLSError::InvalidInput("Expected commit, got external join proposal".to_string()))
                },
            }
        })
    })();
    
    match result {
        Ok(data) => MLSResult::ok(data),
        Err(e) => MLSResult::err(e),
    }
}

/// Free a result object
#[no_mangle]
pub extern "C" fn mls_free_result(result: MLSResult) {
    unsafe {
        if !result.error_message.is_null() {
            let _ = CString::from_raw(result.error_message);
        }
        if !result.data.is_null() && result.data_len > 0 {
            let _ = Vec::from_raw_parts(result.data, result.data_len, result.data_len);
        }
    }
}

/// Get the last error message (for debugging)
#[no_mangle]
pub extern "C" fn mls_get_last_error() -> *mut c_char {
    let msg = CString::new("Use MLSResult.error_message for error details").unwrap();
    msg.into_raw()
}

/// Free an error message string
#[no_mangle]
pub extern "C" fn mls_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            let _ = CString::from_raw(s);
        }
    }
}
