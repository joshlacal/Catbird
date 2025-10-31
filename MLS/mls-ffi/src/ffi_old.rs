use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;
use std::slice;
use std::sync::{Arc, Mutex};
use std::collections::HashMap;

use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;
use tls_codec::Serialize as TlsSerialize;

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
        
        let mut group = MlsGroup::new(
            context.provider(),
            &signature_keypair,
            &group_config,
            credential_with_key,
        ).map_err(|e| MLSError::OpenMLS(e.to_string()))?;
        
        let group_id_bytes = group.group_id().as_slice().to_vec();
        context.add_group(group_id_bytes.clone(), group)?;
        
        Ok(group_id_bytes)
    })();
    
    match result {
        Ok(data) => MLSResult::ok(data),
        Err(e) => MLSResult::err(e),
    }
}

/// Add members to an MLS group
/// Returns serialized (Commit, Welcome) messages
#[no_mangle]
pub extern "C" fn mls_add_members(
    context_id: usize,
    group_id: *const u8,
    group_id_len: usize,
    key_packages_bytes: *const u8,
    key_packages_len: usize,
) -> MLSResult {
    let result: Result<Vec<u8>> = (|| {
        let context = get_context(context_id)?;
        let gid = safe_slice(group_id, group_id_len, "group_id")?;
        let kp_bytes = safe_slice(key_packages_bytes, key_packages_len, "key_packages")?;
        
        let key_packages: Vec<KeyPackage> = serde_json::from_slice(kp_bytes)?;
        
        context.with_group(gid, |group| {
            let (commit, welcome, _group_info) = group
                .add_members(context.provider(), &key_packages)
                .map_err(|e| MLSError::OpenMLS(e.to_string()))?;
            
            group.merge_pending_commit(context.provider())
                .map_err(|e| MLSError::OpenMLS(e.to_string()))?;
            
            let result = serde_json::json!({
                "commit": hex::encode(commit.tls_serialize_detached()
                    .map_err(|e| MLSError::TlsCodec(e.to_string()))?),
                "welcome": hex::encode(welcome.tls_serialize_detached()
                    .map_err(|e| MLSError::TlsCodec(e.to_string()))?),
            });
            
            Ok(serde_json::to_vec(&result)?)
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
        let context = get_context(context_id)?;
        let gid = safe_slice(group_id, group_id_len, "group_id")?;
        let pt = safe_slice(plaintext, plaintext_len, "plaintext")?;
        
        context.with_group(gid, |group| {
            let mls_message = group
                .create_message(context.provider(), pt)
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
        let context = get_context(context_id)?;
        let gid = safe_slice(group_id, group_id_len, "group_id")?;
        let ct = safe_slice(ciphertext, ciphertext_len, "ciphertext")?;
        
        context.with_group(gid, |group| {
            let mls_message_in = MlsMessageIn::tls_deserialize(&mut &ct[..])
                .map_err(|e| MLSError::TlsCodec(e.to_string()))?;
            
            let processed_message = group
                .process_message(context.provider(), mls_message_in)
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
        
        // Wrap the key package in an MlsMessageOut for wire format compatibility
        let mls_message = MlsMessageOut::from(key_package);
        let serialized = mls_message.tls_serialize_detached()
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
        let context = get_context(context_id)?;
        let welcome_data = safe_slice(welcome_bytes, welcome_len, "welcome")?;
        
        let mls_message_in = MlsMessageIn::tls_deserialize(&mut &welcome_data[..])
            .map_err(|e| MLSError::TlsCodec(e.to_string()))?;
        
        let welcome = match mls_message_in.extract() {
            MlsMessageIn::Welcome(w) => w,
            _ => return Err(MLSError::Internal("Not a Welcome message".to_string())),
        };
        
        let group_config = MlsGroupJoinConfig::default();
        
        let group = StagedWelcome::new_from_welcome(
            context.provider(),
            &group_config,
            welcome,
            None,
        )
        .map_err(|e| MLSError::OpenMLS(e.to_string()))?
        .into_group(context.provider())
        .map_err(|e| MLSError::OpenMLS(e.to_string()))?;
        
        let group_id = group.group_id().as_slice().to_vec();
        context.add_group(group_id.clone(), group)?;
        
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
