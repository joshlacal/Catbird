use openmls::prelude::*;
use openmls::prelude::tls_codec::Serialize;
use openmls::group::PURE_CIPHERTEXT_WIRE_FORMAT_POLICY;
use openmls_basic_credential::SignatureKeyPair;
use std::sync::{Arc, RwLock};

use crate::error::MLSError;
use crate::mls_context::MLSContextInner;
use crate::types::*;

#[derive(uniffi::Object)]
pub struct MLSContext {
    inner: Arc<RwLock<MLSContextInner>>,
}

#[uniffi::export]
impl MLSContext {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            inner: Arc::new(RwLock::new(MLSContextInner::new())),
        })
    }

    /// Set the epoch secret storage backend
    ///
    /// This MUST be called during initialization before any MLS operations.
    /// The storage implementation should persist epoch secrets in encrypted storage (SQLCipher).
    pub fn set_epoch_secret_storage(&self, storage: Box<dyn EpochSecretStorage>) -> Result<(), MLSError> {
        crate::info_log!("[MLS-FFI] set_epoch_secret_storage: Setting epoch secret storage backend");

        let inner = self.inner.read()
            .map_err(|_| MLSError::ContextNotInitialized)?;

        inner.epoch_secret_manager().set_storage(Arc::from(storage));
        crate::info_log!("[MLS-FFI] set_epoch_secret_storage: Complete");

        Ok(())
    }

    pub fn create_group(&self, identity_bytes: Vec<u8>, config: Option<GroupConfig>) -> Result<GroupCreationResult, MLSError> {
        crate::info_log!("[MLS-FFI] create_group: Starting");
        crate::debug_log!("[MLS-FFI] Identity bytes: {} bytes", identity_bytes.len());

        let mut inner = self.inner.write()
            .map_err(|e| {
                crate::error_log!("[MLS-FFI] ERROR: Failed to acquire write lock: {:?}", e);
                MLSError::ContextNotInitialized
            })?;

        let identity = String::from_utf8(identity_bytes)
            .map_err(|e| {
                crate::error_log!("[MLS-FFI] ERROR: Invalid UTF-8 in identity: {:?}", e);
                MLSError::invalid_input("Invalid UTF-8")
            })?;
        crate::debug_log!("[MLS-FFI] Identity: {}", identity);

        let group_config = config.unwrap_or_default();
        crate::debug_log!("[MLS-FFI] Group config - max_past_epochs: {}, out_of_order_tolerance: {}, maximum_forward_distance: {}",
            group_config.max_past_epochs, group_config.out_of_order_tolerance, group_config.maximum_forward_distance);

        let group_id = inner.create_group(&identity, group_config)?;
        crate::info_log!("[MLS-FFI] Group created successfully, ID: {}", hex::encode(&group_id));

        Ok(GroupCreationResult {
            group_id: group_id.to_vec(),
        })
    }

    pub fn add_members(
        &self,
        group_id: Vec<u8>,
        key_packages: Vec<KeyPackageData>,
    ) -> Result<AddMembersResult, MLSError> {
        let mut inner = self.inner.write()
            .map_err(|_| MLSError::ContextNotInitialized)?;

        crate::debug_log!("[MLS] add_members: Processing {} key packages", key_packages.len());
        for (i, kp) in key_packages.iter().enumerate() {
            crate::debug_log!("[MLS] KeyPackage {}: {} bytes", i, kp.data.len());
        }
        
        // Deserialize key packages from TLS format
        // Try both MlsMessage-wrapped format and raw KeyPackage format
        let kps: Vec<KeyPackage> = key_packages
            .iter()
            .enumerate()
            .map(|(idx, kp_data)| {
                crate::debug_log!("[MLS] Deserializing key package {}: {} bytes, first 16 bytes = {:02x?}",
                    idx, kp_data.data.len(), &kp_data.data[..kp_data.data.len().min(16)]);

                // First try: MlsMessage-wrapped format (server might send this)
                if let Ok((mls_msg, _)) = MlsMessageIn::tls_deserialize_bytes(&kp_data.data) {
                    crate::debug_log!("[MLS] Key package {} deserialized as MlsMessage", idx);
                    match mls_msg.extract() {
                        MlsMessageBodyIn::KeyPackage(kp_in) => {
                            crate::debug_log!("[MLS] Extracted KeyPackage from MlsMessage");
                            return kp_in.validate(inner.provider().crypto(), ProtocolVersion::default())
                                .map_err(|e| {
                                    crate::error_log!("[MLS] Key package {} validation failed: {:?}", idx, e);
                                    MLSError::InvalidKeyPackage
                                });
                        }
                        other => {
                            crate::debug_log!("[MLS] MlsMessage contained unexpected type: {:?}, trying raw format",
                                std::mem::discriminant(&other));
                        }
                    }
                }

                // Second try: Raw KeyPackage format
                crate::debug_log!("[MLS] Trying raw KeyPackage deserialization for key package {}", idx);
                let (kp_in, remaining) = KeyPackageIn::tls_deserialize_bytes(&kp_data.data)
                    .map_err(|e| {
                        crate::error_log!("[MLS] Both deserialization methods failed for key package {}: {:?}", idx, e);
                        MLSError::SerializationError
                    })?;

                crate::debug_log!("[MLS] Key package {} deserialized as raw KeyPackage ({} bytes remaining)", idx, remaining.len());

                // Validate the key package
                kp_in.validate(inner.provider().crypto(), ProtocolVersion::default())
                    .map_err(|e| {
                        crate::error_log!("[MLS] Key package {} validation failed: {:?}", idx, e);
                        MLSError::InvalidKeyPackage
                    })
            })
            .collect::<Result<Vec<_>, _>>()?;

        if kps.is_empty() {
            return Err(MLSError::InvalidKeyPackage);
        }

        let gid = GroupId::from_slice(&group_id);

        // 🔍 DEBUG: Check for duplicate key packages by credential
        crate::debug_log!("[MLS-FFI] 🔍 DEBUG: Checking {} key packages for duplicates...", kps.len());
        let mut kp_credentials = std::collections::HashSet::new();
        let mut duplicate_count = 0;
        for (idx, kp) in kps.iter().enumerate() {
            let credential_bytes = kp.leaf_node().credential().tls_serialize_detached()
                .unwrap_or_default();
            let credential_hex = hex::encode(&credential_bytes);

            if !kp_credentials.insert(credential_hex.clone()) {
                duplicate_count += 1;
                crate::warn_log!("[MLS-FFI] ⚠️ WARNING: Duplicate key package detected at index {}: {}",
                    idx, &credential_hex[..credential_hex.len().min(16)]);
            } else {
                crate::debug_log!("[MLS-FFI] KeyPackage[{}] credential: {}...",
                    idx, &credential_hex[..credential_hex.len().min(16)]);
            }
        }

        if duplicate_count > 0 {
            crate::error_log!("[MLS-FFI] ❌ CRITICAL: Found {} duplicate key packages in input!", duplicate_count);
        } else {
            crate::debug_log!("[MLS-FFI] ✅ No duplicate key packages detected in input");
        }

        // 🔍 DEBUG: Inspect key package details for Welcome secrets debugging
        crate::debug_log!("[MLS-FFI] 🔍 Key package details:");
        for (idx, kp) in kps.iter().enumerate() {
            crate::debug_log!("[MLS-FFI]   KeyPackage[{}]:", idx);
            crate::debug_log!("[MLS-FFI]     - Cipher suite: {:?}", kp.ciphersuite());
            crate::debug_log!("[MLS-FFI]     - Credential identity: {} bytes",
                kp.leaf_node().credential().serialized_content().len());

            // Check key package capabilities - specifically extensions
            let kp_capabilities = kp.leaf_node().capabilities();
            let kp_extensions: Vec<String> = kp_capabilities.extensions()
                .iter()
                .map(|e| format!("{:?}", e))
                .collect();
            crate::debug_log!("[MLS-FFI]     - Supported extensions: [{}]", kp_extensions.join(", "));
        }

        let (commit_data, welcome_data) = inner.with_group(&gid, |group, provider, signer| {
            // 🔍 DEBUG: List ALL current group members
            crate::debug_log!("[MLS-FFI] 🔍 Current group members:");
            for (idx, member) in group.members().enumerate() {
                let credential = member.credential.serialized_content();
                let identity = String::from_utf8_lossy(credential);
                crate::debug_log!("[MLS-FFI]   Member[{}]: {}", idx, identity);
                crate::debug_log!("[MLS-FFI]            Raw credential: {}", hex::encode(credential));
            }

            // 🔍 DEBUG: Show FULL credentials of incoming key packages
            crate::debug_log!("[MLS-FFI] 🔍 Incoming key packages full credentials:");
            for (idx, kp) in kps.iter().enumerate() {
                let credential = kp.leaf_node().credential().serialized_content();
                let identity = String::from_utf8_lossy(credential);
                crate::debug_log!("[MLS-FFI]   KeyPackage[{}]: {}", idx, identity);
                crate::debug_log!("[MLS-FFI]                 Raw: {}", hex::encode(credential));
            }

            // 🔍 DEBUG: Check for duplicate credentials (self-add or duplicate member)
            if let Some(own_leaf) = group.own_leaf_node() {
                let own_credential = own_leaf.credential().serialized_content();

                for (idx, kp) in kps.iter().enumerate() {
                    let kp_credential = kp.leaf_node().credential().serialized_content();

                    if own_credential == kp_credential {
                        crate::error_log!("[MLS-FFI] ❌ DUPLICATE DETECTED: KeyPackage[{}] matches group creator!", idx);
                        crate::error_log!("[MLS-FFI]    This will cause OpenMLS to create empty Welcome with 0 secrets");
                        return Err(MLSError::invalid_input("Cannot add duplicate identity to group"));
                    }

                    // Check against all existing members
                    for (member_idx, member) in group.members().enumerate() {
                        let member_credential = member.credential.serialized_content();
                        if kp_credential == member_credential {
                            crate::error_log!("[MLS-FFI] ❌ DUPLICATE DETECTED: KeyPackage[{}] matches existing Member[{}]!", idx, member_idx);
                            return Err(MLSError::invalid_input("Member already in group"));
                        }
                    }
                }
            }

            // 🔍 DEBUG: Check group's required capabilities vs key packages
            crate::debug_log!("[MLS-FFI] 🔍 Group configuration:");
            crate::debug_log!("[MLS-FFI]   - Cipher suite: {:?}", group.ciphersuite());

            // Get the group's own leaf node capabilities
            if let Some(own_leaf) = group.own_leaf_node() {
                let own_capabilities = own_leaf.capabilities();
                let group_extensions: Vec<String> = own_capabilities.extensions()
                    .iter()
                    .map(|e| format!("{:?}", e))
                    .collect();
                crate::debug_log!("[MLS-FFI]   - Own leaf extensions: [{}]", group_extensions.join(", "));

                // Check for capability mismatch
                for (idx, kp) in kps.iter().enumerate() {
                    let kp_exts = kp.leaf_node().capabilities().extensions();
                    let own_exts = own_capabilities.extensions();

                    // Check if key package supports all extensions the group's leaf supports
                    for ext in own_exts.iter() {
                        if !kp_exts.contains(ext) {
                            crate::error_log!("[MLS-FFI]   ❌ CAPABILITY MISMATCH KeyPackage[{}]: Missing extension {:?}", idx, ext);
                            crate::error_log!("[MLS-FFI]      This may cause Welcome to have no secrets!");
                        }
                    }
                }
            }
            // 🔍 DEBUG: Get member count BEFORE adding
            let member_count_before = group.members().count();
            crate::debug_log!("[MLS-FFI] 🔍 DEBUG: Member count BEFORE add_members: {}", member_count_before);
            crate::debug_log!("[MLS-FFI] 🔍 DEBUG: Adding {} key packages", kps.len());

            let (commit, welcome, _group_info) = group
                .add_members(provider, signer, &kps)
                .map_err(|e| {
                    crate::error_log!("[MLS-FFI] ❌ add_members failed: {:?}", e);
                    MLSError::AddMembersFailed
                })?;

            // 🔍 DEBUG: Verify member count unchanged (expected behavior - commit is staged)
            let member_count_after = group.members().count();
            crate::debug_log!("[MLS-FFI] 🔍 DEBUG: Member count AFTER add_members (staged): {}", member_count_after);
            if member_count_after == member_count_before {
                crate::debug_log!("[MLS-FFI] ✅ Commit staged correctly (members not added until merge)");
            } else {
                crate::error_log!("[MLS-FFI] ❌ UNEXPECTED: Member count changed before merge! Before: {}, After: {}",
                    member_count_before, member_count_after);
            }

            // ✅ CRITICAL FIX: Server expects "merge-then-send" pattern
            // The Welcome message must be fully populated with encrypted secrets before sending to server
            // Server's createConvo/addMembers endpoints don't validate, but validateWelcome requires secrets
            // Therefore, we merge immediately after add_members() to ensure Welcome has secrets
            crate::debug_log!("[MLS-FFI] 🔄 Merging commit immediately (server expects merge-then-send pattern)");

            group.merge_pending_commit(provider)
                .map_err(|e| {
                    crate::error_log!("[MLS-FFI] ❌ merge_pending_commit failed: {:?}", e);
                    MLSError::MergeFailed
                })?;

            // 🔍 DEBUG: Verify member count increased after merge
            let member_count_after_merge = group.members().count();
            crate::debug_log!("[MLS-FFI] 🔍 DEBUG: Member count AFTER merge: {}", member_count_after_merge);
            if member_count_after_merge == member_count_before + kps.len() {
                crate::debug_log!("[MLS-FFI] ✅ Members successfully added! Before: {}, After: {}",
                    member_count_before, member_count_after_merge);
            } else {
                crate::warn_log!("[MLS-FFI] ⚠️ Unexpected member count after merge. Before: {}, Expected: {}, Actual: {}",
                    member_count_before, member_count_before + kps.len(), member_count_after_merge);
            }

            crate::debug_log!("[MLS-FFI] ✅ Group advanced to epoch {}", group.epoch().as_u64());

            // Serialize the commit (MlsMessageOut)
            let commit_bytes = commit
                .tls_serialize_detached()
                .map_err(|_| MLSError::SerializationError)?;

            // ✅ CRITICAL FIX: Serialize Welcome WITH MlsMessage wrapper
            // The receiver expects MlsMessageIn format, not bare Welcome
            // Both commit and welcome should be serialized as MlsMessageOut
            crate::debug_log!("[MLS-FFI] 🔄 Serializing Welcome with MlsMessage wrapper");

            let welcome_bytes = welcome
                .tls_serialize_detached()
                .map_err(|_| MLSError::SerializationError)?;

            crate::debug_log!("[MLS-FFI] ✅ Welcome serialized with wrapper");

            // 🔍 DEBUG: Inspect Welcome message structure
            crate::debug_log!("[MLS-FFI] 🔍 Welcome message diagnosis:");
            crate::debug_log!("[MLS-FFI]   - Total size: {} bytes", welcome_bytes.len());
            crate::debug_log!("[MLS-FFI]   ✅ Welcome serialized for {} new member(s)", kps.len());

            Ok((commit_bytes, welcome_bytes))
        })?;

        Ok(AddMembersResult {
            commit_data,
            welcome_data,
        })
    }

    /// Delete an MLS group from storage
    /// This should be called when a conversation is deleted or the user leaves
    pub fn delete_group(&self, group_id: Vec<u8>) -> Result<(), MLSError> {
        let mut inner = self.inner.write()
            .map_err(|_| MLSError::ContextNotInitialized)?;

        let gid = GroupId::from_slice(&group_id);
        let group_id_hex = hex::encode(&group_id);

        crate::info_log!("[MLS-FFI] delete_group: Deleting group {}", group_id_hex);

        // Remove from groups HashMap using MLSContextInner method
        if inner.delete_group(gid.as_slice()) {
            crate::info_log!("[MLS-FFI] ✅ Removed group from context: {}", group_id_hex);
            Ok(())
        } else {
            crate::warn_log!("[MLS-FFI] ⚠️ Group not found in context: {}", group_id_hex);
            Err(MLSError::group_not_found(group_id_hex))
        }
    }

    pub fn encrypt_message(
        &self,
        group_id: Vec<u8>,
        plaintext: Vec<u8>,
    ) -> Result<EncryptResult, MLSError> {
        crate::debug_log!("[MLS-FFI] encrypt_message: Starting");
        crate::debug_log!("[MLS-FFI] Group ID: {} ({} bytes)", hex::encode(&group_id), group_id.len());
        crate::debug_log!("[MLS-FFI] Plaintext size: {} bytes", plaintext.len());

        let mut inner = self.inner.write()
            .map_err(|e| {
                crate::error_log!("[MLS-FFI] ERROR: Failed to acquire write lock: {:?}", e);
                MLSError::ContextNotInitialized
            })?;

        let gid = GroupId::from_slice(&group_id);
        crate::debug_log!("[MLS-FFI] GroupId created");

        let ciphertext = inner.with_group(&gid, |group, provider, signer| {
            crate::debug_log!("[MLS-FFI] Inside with_group for encryption");
            crate::debug_log!("[MLS-FFI] Current epoch: {:?}", group.epoch());

            crate::debug_log!("[MLS-FFI] Creating encrypted message...");
            let msg = group
                .create_message(provider, signer, &plaintext)
                .map_err(|e| {
                    crate::error_log!("[MLS-FFI] ERROR: Failed to create message: {:?}", e);
                    MLSError::EncryptionFailed
                })?;
            crate::debug_log!("[MLS-FFI] Message created successfully");

            crate::debug_log!("[MLS-FFI] Serializing message...");
            msg.tls_serialize_detached()
                .map_err(|e| {
                    crate::error_log!("[MLS-FFI] ERROR: Failed to serialize message: {:?}", e);
                    MLSError::SerializationError
                })
        })?;

        crate::debug_log!("[MLS-FFI] encrypt_message: Completed successfully, ciphertext size: {} bytes", ciphertext.len());
        Ok(EncryptResult { ciphertext })
    }

    pub fn decrypt_message(
        &self,
        group_id: Vec<u8>,
        ciphertext: Vec<u8>,
    ) -> Result<DecryptResult, MLSError> {
        crate::debug_log!("[MLS-FFI] decrypt_message: Starting decryption");
        crate::debug_log!("[MLS-FFI] Group ID: {} ({} bytes)", hex::encode(&group_id), group_id.len());
        crate::debug_log!("[MLS-FFI] Ciphertext size: {} bytes", ciphertext.len());
        crate::debug_log!("[MLS-FFI] Ciphertext first 32 bytes: {:02x?}", &ciphertext[..ciphertext.len().min(32)]);

        let mut inner = self.inner.write()
            .map_err(|e| {
                crate::error_log!("[MLS-FFI] ERROR: Failed to acquire write lock: {:?}", e);
                MLSError::ContextNotInitialized
            })?;

        let gid = GroupId::from_slice(&group_id);
        crate::debug_log!("[MLS-FFI] GroupId created from slice");

        let plaintext = inner.with_group(&gid, |group, provider, _signer| {
            crate::debug_log!("[MLS-FFI] Inside with_group closure");
            crate::debug_log!("[MLS-FFI] Current group epoch: {:?}", group.epoch());
            crate::debug_log!("[MLS-FFI] Group ciphersuite: {:?}", group.ciphersuite());

            crate::debug_log!("[MLS-FFI] Attempting to deserialize MlsMessage...");
            let (mls_msg, remaining) = MlsMessageIn::tls_deserialize_bytes(&ciphertext)
                .map_err(|e| {
                    crate::error_log!("[MLS-FFI] ERROR: Failed to deserialize MlsMessage: {:?}", e);
                    MLSError::SerializationError
                })?;
            crate::debug_log!("[MLS-FFI] MlsMessage deserialized successfully ({} bytes remaining)", remaining.len());

            crate::debug_log!("[MLS-FFI] Converting MlsMessage to ProtocolMessage...");
            let protocol_msg: ProtocolMessage = mls_msg.try_into()
                .map_err(|e| {
                    crate::error_log!("[MLS-FFI] ERROR: Failed to convert to ProtocolMessage: {:?}", e);
                    MLSError::DecryptionFailed
                })?;
            crate::debug_log!("[MLS-FFI] ProtocolMessage created successfully");
            crate::debug_log!("[MLS-FFI] Protocol message epoch: {:?}", protocol_msg.epoch());

            crate::debug_log!("[MLS-FFI] Calling OpenMLS process_message...");
            let processed = group
                .process_message(provider, protocol_msg)
                .map_err(|e| {
                    crate::error_log!("[MLS-FFI] ERROR: OpenMLS process_message failed: {:?}", e);
                    crate::error_log!("[MLS-FFI] ERROR: Error type: {}", std::any::type_name_of_val(&e));
                    MLSError::DecryptionFailed
                })?;
            crate::debug_log!("[MLS-FFI] OpenMLS process_message succeeded");

            crate::debug_log!("[MLS-FFI] Processing message content...");
            match processed.into_content() {
                ProcessedMessageContent::ApplicationMessage(app_msg) => {
                    let bytes = app_msg.into_bytes();
                    crate::debug_log!("[MLS-FFI] ApplicationMessage processed: {} bytes", bytes.len());
                    Ok(bytes)
                },
                ProcessedMessageContent::ProposalMessage(prop) => {
                    crate::debug_log!("[MLS-FFI] ProposalMessage received: {:?}", std::any::type_name_of_val(&prop));
                    Ok(vec![]) // Proposals don't have plaintext
                },
                ProcessedMessageContent::ExternalJoinProposalMessage(ext) => {
                    crate::debug_log!("[MLS-FFI] ExternalJoinProposalMessage received: {:?}", std::any::type_name_of_val(&ext));
                    Ok(vec![])
                },
                ProcessedMessageContent::StagedCommitMessage(staged) => {
                    crate::debug_log!("[MLS-FFI] StagedCommitMessage received: {:?}", std::any::type_name_of_val(&staged));
                    // Don't auto-merge - let Swift validate first
                    // Return empty vec to indicate staged commit (Swift will use process_message instead)
                    Ok(vec![])
                },
            }
        })?;

        crate::debug_log!("[MLS-FFI] decrypt_message: Completed successfully, plaintext size: {} bytes", plaintext.len());
        Ok(DecryptResult { plaintext })
    }

    pub fn process_message(
        &self,
        group_id: Vec<u8>,
        message_data: Vec<u8>,
    ) -> Result<ProcessedContent, MLSError> {
        crate::debug_log!("[MLS-FFI] process_message: Starting");
        crate::debug_log!("[MLS-FFI] Group ID: {} ({} bytes)", hex::encode(&group_id), group_id.len());
        crate::debug_log!("[MLS-FFI] Message data size: {} bytes", message_data.len());
        crate::debug_log!("[MLS-FFI] Message data first 32 bytes: {:02x?}", &message_data[..message_data.len().min(32)]);
        
        let mut inner = self.inner.write()
            .map_err(|e| {
                crate::error_log!("[MLS-FFI] ERROR: Failed to acquire write lock: {:?}", e);
                MLSError::ContextNotInitialized
            })?;

        let gid = GroupId::from_slice(&group_id);
        crate::debug_log!("[MLS-FFI] GroupId created: {}", hex::encode(gid.as_slice()));

        inner.with_group(&gid, |group, provider, _signer| {
            crate::debug_log!("[MLS-FFI] Inside with_group closure for process_message");
            crate::debug_log!("[MLS-FFI] Current group epoch: {:?}", group.epoch());
            crate::debug_log!("[MLS-FFI] Group ciphersuite: {:?}", group.ciphersuite());
            crate::debug_log!("[MLS-FFI] Group members count: {}", group.members().count());
            
            crate::debug_log!("[MLS-FFI] Deserializing MlsMessage...");
            let (mls_msg, remaining) = MlsMessageIn::tls_deserialize_bytes(&message_data)
                .map_err(|e| {
                    crate::error_log!("[MLS-FFI] ERROR: Failed to deserialize MlsMessage: {:?}", e);
                    MLSError::SerializationError
                })?;
            crate::debug_log!("[MLS-FFI] MlsMessage deserialized ({} bytes remaining)", remaining.len());

            crate::debug_log!("[MLS-FFI] Converting to ProtocolMessage...");
            let protocol_msg: ProtocolMessage = mls_msg.try_into()
                .map_err(|e| {
                    crate::error_log!("[MLS-FFI] ERROR: Failed to convert to ProtocolMessage: {:?}", e);
                    MLSError::DecryptionFailed
                })?;
            crate::debug_log!("[MLS-FFI] ProtocolMessage created");
            let message_epoch = protocol_msg.epoch();
            let current_epoch = group.epoch();
            crate::debug_log!("[MLS-FFI] Protocol message epoch: {:?}", message_epoch);
            crate::debug_log!("[MLS-FFI] Current group epoch: {:?}", current_epoch);
            crate::debug_log!("[MLS-FFI] Protocol message content type: {:?}", std::any::type_name_of_val(&protocol_msg));

            // Check for epoch mismatch BEFORE attempting to decrypt
            if message_epoch != current_epoch {
                crate::warn_log!("[MLS-FFI] ⚠️ EPOCH MISMATCH DETECTED!");
                crate::debug_log!("[MLS-FFI] Message is from epoch {} but group is at epoch {}", message_epoch.as_u64(), current_epoch.as_u64());
                crate::debug_log!("[MLS-FFI] This is expected MLS forward secrecy behavior - old epoch keys are deleted");
                return Err(MLSError::invalid_input(format!(
                    "Cannot decrypt message from epoch {} - group is at epoch {} (forward secrecy prevents decrypting old epochs)",
                    message_epoch.as_u64(),
                    current_epoch.as_u64()
                )));
            }

            crate::debug_log!("[MLS-FFI] Calling OpenMLS process_message...");
            let processed = group
                .process_message(provider, protocol_msg)
                .map_err(|e| {
                    crate::error_log!("[MLS-FFI] ERROR: OpenMLS process_message failed!");
                    crate::error_log!("[MLS-FFI] ERROR: Error details: {:?}", e);
                    crate::error_log!("[MLS-FFI] ERROR: Error type: {}", std::any::type_name_of_val(&e));
                    crate::error_log!("[MLS-FFI] ERROR: Current epoch: {:?}", group.epoch());
                    MLSError::DecryptionFailed
                })?;
            crate::debug_log!("[MLS-FFI] OpenMLS process_message succeeded!");

            crate::debug_log!("[MLS-FFI] Processing message content type...");

            // Extract sender credential BEFORE consuming the processed message
            let sender_credential = processed.credential();
            let sender = CredentialData {
                credential_type: format!("{:?}", sender_credential.credential_type()),
                identity: sender_credential.serialized_content().to_vec(),
            };
            crate::debug_log!("[MLS-FFI] Sender extracted: {} bytes identity", sender.identity.len());

            match processed.into_content() {
                ProcessedMessageContent::ApplicationMessage(app_msg) => {
                    let plaintext = app_msg.into_bytes();
                    crate::debug_log!("[MLS-FFI] ApplicationMessage processed: {} bytes", plaintext.len());

                    Ok(ProcessedContent::ApplicationMessage {
                        plaintext,
                        sender,
                    })
                },
                ProcessedMessageContent::ProposalMessage(proposal_msg) => {
                    crate::debug_log!("[MLS-FFI] ProposalMessage received, processing...");
                    let proposal = proposal_msg.proposal();

                    // Compute proposal reference by hashing the proposal
                    // Since proposal_reference() is pub(crate), we compute our own identifier
                    let proposal_bytes = proposal
                        .tls_serialize_detached()
                        .map_err(|e| {
                            crate::error_log!("[MLS-FFI] ERROR: Failed to serialize proposal: {:?}", e);
                            MLSError::SerializationError
                        })?;

                    let proposal_ref_bytes = provider.crypto()
                        .hash(group.ciphersuite().hash_algorithm(), &proposal_bytes)
                        .map_err(|e| {
                            crate::error_log!("[MLS-FFI] ERROR: Failed to hash proposal: {:?}", e);
                            MLSError::OpenMLSError
                        })?;

                    crate::debug_log!("[MLS-FFI] Proposal ref computed: {}", hex::encode(&proposal_ref_bytes));
                    
                    let proposal_info = match proposal {
                        Proposal::Add(add_proposal) => {
                            crate::debug_log!("[MLS-FFI] Add proposal detected");
                            let key_package = add_proposal.key_package();
                            let credential = key_package.leaf_node().credential();

                            let credential_info = CredentialData {
                                credential_type: format!("{:?}", credential.credential_type()),
                                identity: credential.serialized_content().to_vec(),
                            };

                            ProposalInfo::Add {
                                info: AddProposalInfo {
                                    credential: credential_info,
                                    key_package_ref: key_package.hash_ref(provider.crypto())
                                        .map_err(|_| MLSError::OpenMLSError)?
                                        .as_slice()
                                        .to_vec(),
                                }
                            }
                        },
                        Proposal::Remove(remove_proposal) => {
                            crate::debug_log!("[MLS-FFI] Remove proposal detected, index: {}", remove_proposal.removed().u32());
                            ProposalInfo::Remove {
                                info: RemoveProposalInfo {
                                    removed_index: remove_proposal.removed().u32(),
                                }
                            }
                        },
                        Proposal::Update(update_proposal) => {
                            crate::debug_log!("[MLS-FFI] Update proposal detected");
                            let leaf_node = update_proposal.leaf_node();
                            let credential = leaf_node.credential();

                            let credential_info = CredentialData {
                                credential_type: format!("{:?}", credential.credential_type()),
                                identity: credential.serialized_content().to_vec(),
                            };

                            let leaf_index = group.own_leaf_index().u32();
                            crate::debug_log!("[MLS-FFI] Update proposal leaf index: {}", leaf_index);

                            ProposalInfo::Update {
                                info: UpdateProposalInfo {
                                    leaf_index,
                                    old_credential: credential_info.clone(),
                                    new_credential: credential_info,
                                }
                            }
                        },
                        _ => {
                            crate::error_log!("[MLS-FFI] ERROR: Unsupported proposal type");
                            return Err(MLSError::invalid_input("Unsupported proposal type"));
                        }
                    };

                    crate::debug_log!("[MLS-FFI] Proposal processed successfully");
                    Ok(ProcessedContent::Proposal {
                        proposal: proposal_info,
                        proposal_ref: ProposalRef {
                            data: proposal_ref_bytes,
                        },
                    })
                },
                ProcessedMessageContent::ExternalJoinProposalMessage(_) => {
                    crate::error_log!("[MLS-FFI] ERROR: External join proposals not supported");
                    Err(MLSError::invalid_input("External join proposals not supported"))
                },
                ProcessedMessageContent::StagedCommitMessage(staged) => {
                    crate::debug_log!("[MLS-FFI] StagedCommitMessage received, processing...");
                    let new_epoch = staged.group_context().epoch().as_u64();

                    // Don't auto-merge - return staged commit info for validation
                    // The staged commit remains in the group's pending state
                    Ok(ProcessedContent::StagedCommit { new_epoch })
                },
            }
        })
    }

    pub fn create_key_package(
        &self,
        identity_bytes: Vec<u8>,
    ) -> Result<KeyPackageResult, MLSError> {
        let mut inner = self.inner.write()
            .map_err(|_| MLSError::ContextNotInitialized)?;

        let identity = String::from_utf8(identity_bytes)
            .map_err(|_| MLSError::invalid_input("Invalid UTF-8"))?;

        let credential = Credential::new(
            CredentialType::Basic,
            identity.as_bytes().to_vec()
        );
        let signature_keys = SignatureKeyPair::new(SignatureScheme::ED25519)
            .map_err(|_| MLSError::OpenMLSError)?;

        signature_keys.store(inner.provider().storage())
            .map_err(|_| MLSError::OpenMLSError)?;

        // CRITICAL: Register the signer for this identity so it can be found when processing Welcome messages
        let signer_public_key = signature_keys.public().to_vec();
        inner.register_signer(&identity, signer_public_key.clone());
        crate::debug_log!("[MLS-FFI] Registered signer for identity: {}", identity);

        let ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;
        let key_package_bundle = KeyPackage::builder()
            .build(
                ciphersuite,
                inner.provider(),
                &signature_keys,
                CredentialWithKey {
                    credential,
                    signature_key: signature_keys.public().into(),
                },
            )
            .map_err(|_| MLSError::OpenMLSError)?;

        // Serialize key package directly (raw format for compatibility)
        let key_package = key_package_bundle.key_package().clone();

        let key_package_data = key_package
            .tls_serialize_detached()
            .map_err(|_| MLSError::SerializationError)?;

        let hash_ref = key_package
            .hash_ref(inner.provider().crypto())
            .map_err(|_| MLSError::OpenMLSError)?
            .as_slice()
            .to_vec();

        // CRITICAL FIX: Store the bundle in the cache for serialization and Welcome message processing
        // This ensures the private key material is available when processing Welcome messages
        crate::debug_log!("[MLS-FFI] Storing key package bundle in cache (hash_ref: {})", hex::encode(&hash_ref));
        inner.key_package_bundles.insert(hash_ref.clone(), key_package_bundle);
        crate::debug_log!("[MLS-FFI] Bundle cached successfully, cache now has {} bundles", inner.key_package_bundles.len());

        Ok(KeyPackageResult { key_package_data, hash_ref })
    }

    pub fn process_welcome(
        &self,
        welcome_bytes: Vec<u8>,
        identity_bytes: Vec<u8>,
        config: Option<GroupConfig>,
    ) -> Result<WelcomeResult, MLSError> {
        crate::info_log!("[MLS-FFI] process_welcome: Starting with {} byte Welcome message", welcome_bytes.len());

        let mut inner = self.inner.write()
            .map_err(|_| MLSError::ContextNotInitialized)?;

        let identity = String::from_utf8(identity_bytes)
            .map_err(|_| MLSError::invalid_input("Invalid UTF-8"))?;
        crate::info_log!("[MLS-FFI] process_welcome: Identity = {}", identity);

        let (mls_msg, _) = MlsMessageIn::tls_deserialize_bytes(&welcome_bytes)
            .map_err(|e| {
                crate::error_log!("[MLS-FFI] ERROR: Failed to deserialize Welcome message: {:?}", e);
                MLSError::SerializationError
            })?;
        crate::debug_log!("[MLS-FFI] process_welcome: Welcome message deserialized successfully");

        let welcome = match mls_msg.extract() {
            MlsMessageBodyIn::Welcome(w) => w,
            _ => {
                crate::error_log!("[MLS-FFI] ERROR: MlsMessage is not a Welcome message");
                return Err(MLSError::invalid_input("Not a Welcome message"));
            }
        };

        // DIAGNOSTIC: Check key package bundle availability
        let bundle_count = inner.key_package_bundles.len();
        crate::info_log!("[MLS-FFI] process_welcome: Key package bundles in cache: {}", bundle_count);

        if bundle_count == 0 {
            crate::warn_log!("[MLS-FFI] ⚠️ WARNING: No key package bundles available!");
            crate::warn_log!("[MLS-FFI]   This indicates potential state desync (app reinstall/database loss)");
            crate::warn_log!("[MLS-FFI]   Triggering key package recovery flow...");

            // Try to extract group ID from Welcome for better error reporting
            // Welcome message secrets are encrypted, but we can try to get basic info
            let convo_id = format!("welcome_{}", hex::encode(&welcome_bytes[..16.min(welcome_bytes.len())]));

            return Err(MLSError::key_package_desync_detected(
                convo_id,
                "No key package bundles available - likely due to app reinstall or database loss"
            ));
        } else {
            crate::debug_log!("[MLS-FFI] process_welcome: Available bundle hash_refs:");
            for (i, hash_ref) in inner.key_package_bundles.keys().enumerate() {
                crate::debug_log!("[MLS-FFI]   Bundle {}: {}", i, hex::encode(hash_ref));
            }
        }

        let group_config = config.unwrap_or_default();
        crate::debug_log!("[MLS-FFI] process_welcome: Group config - max_past_epochs: {}, out_of_order_tolerance: {}, maximum_forward_distance: {}",
            group_config.max_past_epochs, group_config.out_of_order_tolerance, group_config.maximum_forward_distance);

        // Build join config with forward secrecy settings
        let join_config = MlsGroupJoinConfig::builder()
            .max_past_epochs(group_config.max_past_epochs as usize)
            .sender_ratchet_configuration(SenderRatchetConfiguration::new(
                group_config.out_of_order_tolerance,
                group_config.maximum_forward_distance,
            ))
            .wire_format_policy(PURE_CIPHERTEXT_WIRE_FORMAT_POLICY)
            .build();
        crate::debug_log!("[MLS-FFI] process_welcome: Join config created");

        crate::info_log!("[MLS-FFI] process_welcome: Calling StagedWelcome::new_from_welcome...");
        let group = StagedWelcome::new_from_welcome(
            inner.provider(),
            &join_config,
            welcome,
            None,
        )
        .map_err(|e| {
            crate::error_log!("[MLS-FFI] ❌ ERROR: StagedWelcome::new_from_welcome failed!");
            crate::error_log!("[MLS-FFI] ERROR: OpenMLS error details: {:?}", e);
            crate::error_log!("[MLS-FFI] ERROR: Error type: {}", std::any::type_name_of_val(&e));
            crate::error_log!("[MLS-FFI] DIAGNOSTIC: This is likely NoMatchingKeyPackage if bundle_count was 0");
            crate::error_log!("[MLS-FFI] DIAGNOSTIC: Check if storage was loaded before calling process_welcome");
            MLSError::OpenMLSError
        })?
        .into_group(inner.provider())
        .map_err(|e| {
            crate::error_log!("[MLS-FFI] ❌ ERROR: into_group failed!");
            crate::error_log!("[MLS-FFI] ERROR: OpenMLS error details: {:?}", e);
            MLSError::OpenMLSError
        })?;

        crate::info_log!("[MLS-FFI] process_welcome: Successfully joined group via Welcome");

        let group_id = group.group_id().as_slice().to_vec();

        // 🔍 DEBUG: Log initial member count after processing Welcome
        let initial_member_count = group.members().count();
        crate::debug_log!("[MLS-FFI] 🔍 DEBUG: Group created from Welcome with {} members at epoch {}",
            initial_member_count, group.epoch().as_u64());

        // CRITICAL: Export epoch secret immediately after joining
        // The group may already be at epoch > 0 when we join via Welcome
        let epoch_manager = inner.epoch_secret_manager().clone();
        crate::debug_log!("[MLS-FFI] process_welcome: Group joined at epoch {}", group.epoch().as_u64());
        if let Err(e) = epoch_manager.export_current_epoch_secret(&group, inner.provider()) {
            crate::warn_log!("[MLS-FFI] ⚠️ WARNING: Failed to export epoch secret after Welcome: {:?}", e);
        } else {
            crate::info_log!("[MLS-FFI] ✅ Exported epoch {} secret after processing Welcome", group.epoch().as_u64());
        }

        inner.add_group(group, &identity)?;

        Ok(WelcomeResult { group_id })
    }

    pub fn export_secret(
        &self,
        group_id: Vec<u8>,
        label: String,
        context: Vec<u8>,
        key_length: u64,
    ) -> Result<ExportedSecret, MLSError> {
        let mut inner = self.inner.write()
            .map_err(|_| MLSError::ContextNotInitialized)?;
        
        let gid = GroupId::from_slice(&group_id);
        
        let secret = inner.with_group(&gid, |group, provider, _signer| {
            group
                .export_secret(provider, &label, &context, key_length as usize)
                .map_err(|_| MLSError::SecretExportFailed)
        })?;
        
        Ok(ExportedSecret { secret: secret.to_vec() })
    }

    pub fn get_epoch(&self, group_id: Vec<u8>) -> Result<u64, MLSError> {
        crate::debug_log!("[MLS-FFI] get_epoch: Starting");
        crate::debug_log!("[MLS-FFI] Group ID: {}", hex::encode(&group_id));
        
        let inner = self.inner.read()
            .map_err(|e| {
                crate::error_log!("[MLS-FFI] ERROR: Failed to acquire read lock: {:?}", e);
                MLSError::ContextNotInitialized
            })?;
        
        let gid = GroupId::from_slice(&group_id);
        
        inner.with_group_ref(&gid, |group, _provider| {
            let epoch = group.epoch().as_u64();
            crate::debug_log!("[MLS-FFI] Current epoch: {}", epoch);
            Ok(epoch)
        })
    }

    pub fn process_commit(
        &self,
        group_id: Vec<u8>,
        commit_data: Vec<u8>,
    ) -> Result<ProcessCommitResult, MLSError> {
        let mut inner = self.inner.write()
            .map_err(|_| MLSError::ContextNotInitialized)?;

        let gid = GroupId::from_slice(&group_id);

        // Process commit as a message and extract Update proposals
        let update_proposals = inner.with_group(&gid, |group, provider, _signer| {
            let (mls_msg, _) = MlsMessageIn::tls_deserialize_bytes(&commit_data)
                .map_err(|_| MLSError::SerializationError)?;

            let protocol_msg: ProtocolMessage = mls_msg.try_into()
                .map_err(|_| MLSError::CommitProcessingFailed)?;

            let processed = group
                .process_message(provider, protocol_msg)
                .map_err(|_| MLSError::CommitProcessingFailed)?;

            match processed.into_content() {
                ProcessedMessageContent::StagedCommitMessage(staged) => {
                    // Extract Update proposals before merging
                    let updates: Vec<UpdateProposalInfo> = staged
                        .update_proposals()
                        .filter_map(|queued_proposal| {
                            let update_proposal = queued_proposal.update_proposal();
                            let leaf_node = update_proposal.leaf_node();
                            let new_credential = leaf_node.credential();

                            // Extract leaf index from sender
                            let leaf_index = match queued_proposal.sender() {
                                Sender::Member(leaf_index) => leaf_index.u32(),
                                _ => return None,
                            };

                            // Get old credential from current group state
                            if let Some(old_member) = group.members().find(|m| m.index.u32() == leaf_index) {
                                let old_cred_type = format!("{:?}", old_member.credential.credential_type());
                                let old_identity = old_member.credential.serialized_content().to_vec();

                                let new_cred_type = format!("{:?}", new_credential.credential_type());
                                let new_identity = new_credential.serialized_content().to_vec();

                                Some(UpdateProposalInfo {
                                    leaf_index,
                                    old_credential: CredentialData {
                                        credential_type: old_cred_type,
                                        identity: old_identity,
                                    },
                                    new_credential: CredentialData {
                                        credential_type: new_cred_type,
                                        identity: new_identity,
                                    },
                                })
                            } else {
                                None
                            }
                        })
                        .collect();

                    // Don't auto-merge - let caller validate first
                    // The staged commit remains in the group's pending state
                    Ok(updates)
                },
                _ => Err(MLSError::InvalidCommit),
            }
        })?;

        // Get new epoch
        let new_epoch = self.get_epoch(group_id)?;

        Ok(ProcessCommitResult {
            new_epoch,
            update_proposals
        })
    }

    /// Clear pending commit for a group
    /// This should be called when a commit is rejected by the delivery service
    /// to clean up pending state in OpenMLS
    pub fn clear_pending_commit(&self, group_id: Vec<u8>) -> Result<(), MLSError> {
        let mut inner = self.inner.write()
            .map_err(|_| MLSError::ContextNotInitialized)?;

        let gid = GroupId::from_slice(&group_id);

        inner.with_group(&gid, |group, provider, _signer| {
            group.clear_pending_commit(provider.storage())
                .map_err(|_| MLSError::OpenMLSError)?;
            Ok(())
        })
    }

    /// Store a proposal in the proposal queue after validation
    /// The application should inspect the proposal before storing it
    pub fn store_proposal(
        &self,
        group_id: Vec<u8>,
        _proposal_ref: ProposalRef,
    ) -> Result<(), MLSError> {
        let mut inner = self.inner.write()
            .map_err(|_| MLSError::ContextNotInitialized)?;

        let gid = GroupId::from_slice(&group_id);

        inner.with_group(&gid, |_group, _provider, _signer| {
            // In OpenMLS, proposals are already stored when processed
            // This function is a placeholder for explicit application control
            // The proposal was stored during process_message call
            // Application can maintain its own list of approved proposals
            Ok(())
        })
    }

    /// List all pending proposals for a group
    pub fn list_pending_proposals(
        &self,
        group_id: Vec<u8>,
    ) -> Result<Vec<ProposalRef>, MLSError> {
        let inner = self.inner.read()
            .map_err(|_| MLSError::ContextNotInitialized)?;

        let gid = GroupId::from_slice(&group_id);

        inner.with_group_ref(&gid, |group, provider| {
            let proposal_refs: Vec<ProposalRef> = group
                .pending_proposals()
                .filter_map(|queued_proposal| {
                    // Compute proposal reference by hashing the proposal
                    // Since proposal_reference() is pub(crate), we compute our own identifier
                    let proposal = queued_proposal.proposal();
                    let proposal_bytes = proposal
                        .tls_serialize_detached()
                        .ok()?;

                    let proposal_ref_bytes = provider.crypto()
                        .hash(group.ciphersuite().hash_algorithm(), &proposal_bytes)
                        .ok()?;

                    Some(ProposalRef {
                        data: proposal_ref_bytes,
                    })
                })
                .collect();

            Ok(proposal_refs)
        })
    }

    /// Remove a proposal from the proposal queue
    pub fn remove_proposal(
        &self,
        group_id: Vec<u8>,
        proposal_ref: ProposalRef,
    ) -> Result<(), MLSError> {
        let mut inner = self.inner.write()
            .map_err(|_| MLSError::ContextNotInitialized)?;

        let gid = GroupId::from_slice(&group_id);

        inner.with_group(&gid, |group, provider, _signer| {
            // Remove proposal from the store
            let proposal_reference = openmls::prelude::hash_ref::ProposalRef::tls_deserialize_exact_bytes(&proposal_ref.data)
                .map_err(|_| MLSError::OpenMLSError)?;
            group.remove_pending_proposal(provider.storage(), &proposal_reference)
                .map_err(|_| MLSError::OpenMLSError)?;
            Ok(())
        })
    }

    /// Commit all pending proposals that have been validated and stored
    pub fn commit_pending_proposals(
        &self,
        group_id: Vec<u8>,
    ) -> Result<Vec<u8>, MLSError> {
        let mut inner = self.inner.write()
            .map_err(|_| MLSError::ContextNotInitialized)?;

        let gid = GroupId::from_slice(&group_id);

        inner.with_group(&gid, |group, provider, signer| {
            // Commit all pending proposals
            let (commit_msg, _welcome, _group_info) = group
                .commit_to_pending_proposals(provider, signer)
                .map_err(|_| MLSError::OpenMLSError)?;

            // Merge the pending commit
            group.merge_pending_commit(provider)
                .map_err(|_| MLSError::OpenMLSError)?;

            // Serialize the commit
            let commit_data = commit_msg
                .tls_serialize_detached()
                .map_err(|_| MLSError::SerializationError)?;

            Ok(commit_data)
        })
    }

    /// Merge a pending commit after validation
    /// This should be called after the commit has been accepted by the delivery service
    pub fn merge_pending_commit(&self, group_id: Vec<u8>) -> Result<u64, MLSError> {
        let mut inner = self.inner.write()
            .map_err(|_| MLSError::ContextNotInitialized)?;

        let gid = GroupId::from_slice(&group_id);

        // CRITICAL: Export epoch secret BEFORE merging commit
        // This allows decrypting messages from the current epoch after the group advances
        let epoch_manager = inner.epoch_secret_manager().clone();

        inner.with_group(&gid, |group, provider, _signer| {
            // 🔍 DEBUG: Get member count BEFORE merge
            let member_count_before_merge = group.members().count();
            crate::debug_log!("[MLS-FFI] 🔍 DEBUG: Member count BEFORE merge_pending_commit: {}", member_count_before_merge);

            crate::debug_log!("[MLS-FFI] merge_pending_commit: Exporting current epoch secret before advancing");

            // Export current epoch secret before the commit advances the epoch
            if let Err(e) = epoch_manager.export_current_epoch_secret(group, provider) {
                crate::warn_log!("[MLS-FFI] ⚠️ WARNING: Failed to export epoch secret: {:?}", e);
                crate::debug_log!("[MLS-FFI]   This may cause decryption failures for delayed messages from current epoch");
                // Continue with merge - epoch secret export is best-effort
            }

            group.merge_pending_commit(provider)
                .map_err(|_| MLSError::MergeFailed)?;

            // 🔍 DEBUG: Get member count AFTER merge
            let member_count_after_merge = group.members().count();
            crate::debug_log!("[MLS-FFI] 🔍 DEBUG: Member count AFTER merge_pending_commit: {}", member_count_after_merge);

            if member_count_before_merge != member_count_after_merge {
                crate::warn_log!("[MLS-FFI] ⚠️ WARNING: Member count changed during merge! Before: {}, After: {}",
                    member_count_before_merge, member_count_after_merge);
            }

            let new_epoch = group.epoch().as_u64();
            crate::debug_log!("[MLS-FFI] merge_pending_commit: Advanced to epoch {}", new_epoch);
            Ok(new_epoch)
        })
    }

    /// Merge a staged commit after validation
    /// This should be called after validating incoming commits from other members
    pub fn merge_staged_commit(&self, group_id: Vec<u8>) -> Result<u64, MLSError> {
        // OpenMLS uses the same internal method for both pending and staged commits
        self.merge_pending_commit(group_id)
    }

    /// Check if a group exists in local storage
    /// - Parameters:
    ///   - group_id: Group identifier to check
    /// - Returns: true if group exists, false otherwise
    pub fn group_exists(&self, group_id: Vec<u8>) -> bool {
        let inner = match self.inner.read() {
            Ok(guard) => guard,
            Err(_) => return false,
        };
        inner.has_group(&group_id)
    }

    /// Get the current member count of a group
    ///
    /// - Parameters:
    ///   - group_id: Group identifier
    /// - Returns: Number of members in the group
    /// - Throws: MLSError if group not found
    pub fn get_group_member_count(&self, group_id: Vec<u8>) -> Result<u32, MLSError> {
        crate::debug_log!("[MLS-FFI] get_group_member_count: Starting for group {}", hex::encode(&group_id));

        let gid = GroupId::from_slice(&group_id);
        let mut inner = self.inner.write()
            .map_err(|_| MLSError::InvalidInput { message: "Failed to acquire lock".to_string() })?;

        inner.with_group(&gid, |group, _provider, _signer| {
            let member_count = group.members().count() as u32;
            crate::debug_log!("[MLS-FFI] get_group_member_count: Group has {} members", member_count);
            Ok(member_count)
        })
    }

    /// Get detailed debug information about all group members
    ///
    /// Returns information about each member including their leaf index,
    /// credential identity, and credential type. Useful for diagnosing
    /// member duplication issues.
    ///
    /// - Parameters:
    ///   - group_id: Group identifier
    /// - Returns: GroupDebugInfo with all member details
    /// - Throws: MLSError if group not found
    pub fn debug_group_members(&self, group_id: Vec<u8>) -> Result<GroupDebugInfo, MLSError> {
        crate::debug_log!("[MLS-FFI] 🔍 debug_group_members: Starting for group {}", hex::encode(&group_id));

        let gid = GroupId::from_slice(&group_id);
        let mut inner = self.inner.write()
            .map_err(|_| MLSError::InvalidInput { message: "Failed to acquire lock".to_string() })?;

        inner.with_group(&gid, |group, _provider, _signer| {
            let epoch = group.epoch().as_u64();
            let total_members = group.members().count() as u32;

            crate::debug_log!("[MLS-FFI] 🔍 Group epoch: {}", epoch);
            crate::debug_log!("[MLS-FFI] 🔍 Total members: {}", total_members);

            let mut members = Vec::new();
            let mut identity_counts = std::collections::HashMap::new();

            for (index, member) in group.members().enumerate() {
                let credential = member.credential;
                let identity = credential.serialized_content().to_vec();
                let credential_type = format!("{:?}", credential.credential_type());
                let leaf_index = member.index.u32();

                // Track duplicates
                let identity_hex = hex::encode(&identity);
                *identity_counts.entry(identity_hex.clone()).or_insert(0) += 1;

                crate::debug_log!("[MLS-FFI] 🔍 Member {}: leaf_index={}, identity={} ({} bytes), type={}",
                    index, leaf_index, &identity_hex[..16], identity.len(), credential_type);

                members.push(GroupMemberDebugInfo {
                    leaf_index,
                    credential_identity: identity,
                    credential_type,
                });
            }

            // Report duplicates
            crate::debug_log!("[MLS-FFI] 🔍 Unique identities: {}", identity_counts.len());
            for (identity, count) in identity_counts.iter() {
                if *count > 1 {
                    crate::warn_log!("[MLS-FFI] ⚠️ DUPLICATE: Identity {} appears {} times!", &identity[..16], count);
                }
            }

            Ok(GroupDebugInfo {
                group_id: group_id.clone(),
                epoch,
                total_members,
                members,
            })
        })
    }

    /// Export a group's state for persistent storage
    ///
    /// Returns serialized bytes that can be stored in the keychain
    /// and later restored with import_group_state.
    ///
    /// - Parameters:
    ///   - group_id: Group identifier to export
    /// - Returns: Serialized group state bytes
    /// - Throws: MLSError if group not found or serialization fails
    pub fn export_group_state(&self, group_id: Vec<u8>) -> Result<Vec<u8>, MLSError> {
        crate::debug_log!("[MLS-FFI] export_group_state: Starting");

        let inner = self.inner.read()
            .map_err(|_| MLSError::ContextNotInitialized)?;

        let state_bytes = inner.export_group_state(&group_id)?;

        crate::debug_log!("[MLS-FFI] export_group_state: Complete, {} bytes", state_bytes.len());
        Ok(state_bytes)
    }

    /// Import a group's state from persistent storage
    ///
    /// Restores a previously exported group state. The group will be
    /// available for all MLS operations after import.
    ///
    /// - Parameters:
    ///   - state_bytes: Serialized group state from export_group_state
    /// - Returns: Group ID of the imported group
    /// - Throws: MLSError if deserialization fails
    pub fn import_group_state(&self, state_bytes: Vec<u8>) -> Result<Vec<u8>, MLSError> {
        crate::debug_log!("[MLS-FFI] import_group_state: Starting with {} bytes", state_bytes.len());

        let mut inner = self.inner.write()
            .map_err(|_| MLSError::ContextNotInitialized)?;

        let group_id = inner.import_group_state(&state_bytes)?;

        crate::debug_log!("[MLS-FFI] import_group_state: Complete, group ID: {}", hex::encode(&group_id));
        Ok(group_id)
    }

    /// Serialize the entire MLS storage for persistence
    ///
    /// Exports all groups, keys, and cryptographic state to a byte blob
    /// that can be stored in Core Data or Keychain. This should be called
    /// when the app backgrounds or before termination.
    ///
    /// - Returns: Serialized storage bytes
    /// - Throws: MLSError if serialization fails
    pub fn serialize_storage(&self) -> Result<Vec<u8>, MLSError> {
        crate::debug_log!("[MLS-FFI] serialize_storage: Starting");

        let inner = self.inner.read()
            .map_err(|_| MLSError::ContextNotInitialized)?;

        let storage_bytes = inner.serialize_storage()?;

        crate::debug_log!("[MLS-FFI] serialize_storage: Complete, {} bytes", storage_bytes.len());
        Ok(storage_bytes)
    }

    /// Deserialize and restore MLS storage from persistent bytes
    ///
    /// Restores all groups, keys, and cryptographic state from a previously
    /// serialized storage blob. This should be called during app initialization
    /// BEFORE any other MLS operations.
    ///
    /// WARNING: This replaces the entire storage. Only call during initialization.
    ///
    /// - Parameters:
    ///   - storage_bytes: Serialized storage from serialize_storage
    /// - Throws: MLSError if deserialization fails
    pub fn deserialize_storage(&self, storage_bytes: Vec<u8>) -> Result<(), MLSError> {
        crate::debug_log!("[MLS-FFI] deserialize_storage: Starting with {} bytes", storage_bytes.len());

        let mut inner = self.inner.write()
            .map_err(|_| MLSError::ContextNotInitialized)?;

        inner.deserialize_storage(&storage_bytes)?;

        crate::debug_log!("[MLS-FFI] deserialize_storage: Complete");
        Ok(())
    }

    /// Get the number of key package bundles currently cached
    ///
    /// This provides a direct count of key package bundles available for
    /// processing Welcome messages. A count of 0 indicates that Welcome
    /// messages cannot be processed and bundles need to be created.
    ///
    /// - Returns: Number of cached key package bundles
    /// - Throws: MLSError if context is not initialized
    pub fn get_key_package_bundle_count(&self) -> Result<u64, MLSError> {
        let inner = self.inner.read()
            .map_err(|_| MLSError::ContextNotInitialized)?;

        let count = inner.key_package_bundles.len() as u64;
        crate::debug_log!("[MLS-FFI] get_key_package_bundle_count: {} bundles in cache", count);

        Ok(count)
    }

    /// Set the global MLS logger to receive Rust logs in Swift
    ///
    /// This allows forwarding internal MLS logs to OSLog or other Swift logging systems.
    /// The logger instance will be used for all subsequent MLS operations.
    ///
    /// - Parameters:
    ///   - logger: Logger implementation conforming to MLSLogger protocol
    pub fn set_logger(&self, logger: Box<dyn MLSLogger>) {
        crate::logging::set_logger(logger);
    }

    /// Compute the hash reference for a serialized KeyPackage
    ///
    /// Accepts either an MlsMessage-wrapped KeyPackage or raw KeyPackage bytes.
    /// This is useful when you need to compute a hash from KeyPackage bytes received from the server.
    ///
    /// - Parameters:
    ///   - key_package_bytes: Serialized KeyPackage data
    /// - Returns: Hash reference bytes
    /// - Throws: MLSError if deserialization or hashing fails
    pub fn compute_key_package_hash(&self, key_package_bytes: Vec<u8>) -> Result<Vec<u8>, MLSError> {
        use openmls::prelude::*;
        
        let inner = self.inner.read()
            .map_err(|_| MLSError::ContextNotInitialized)?;
        
        let provider = inner.provider();
        
        // Try MlsMessage-wrapped format first
        if let Ok((mls_msg, _)) = MlsMessageIn::tls_deserialize_bytes(&key_package_bytes) {
            if let MlsMessageBodyIn::KeyPackage(kp_in) = mls_msg.extract() {
                let kp = kp_in
                    .validate(provider.crypto(), ProtocolVersion::default())
                    .map_err(|_| MLSError::InvalidKeyPackage)?;
                return Ok(kp
                    .hash_ref(provider.crypto())
                    .map_err(|_| MLSError::OpenMLSError)?
                    .as_slice()
                    .to_vec());
            }
        }
        
        // Fallback: raw KeyPackage format
        let (kp_in, _remaining) = KeyPackageIn::tls_deserialize_bytes(&key_package_bytes)
            .map_err(|_| MLSError::SerializationError)?;
        let kp = kp_in
            .validate(provider.crypto(), ProtocolVersion::default())
            .map_err(|_| MLSError::InvalidKeyPackage)?;
        Ok(kp
            .hash_ref(provider.crypto())
            .map_err(|_| MLSError::OpenMLSError)?
            .as_slice()
            .to_vec())
    }
}

// Free functions exported to UniFFI

/// Set the global MLS logger to receive Rust logs in Swift
/// This allows forwarding internal MLS logs to OSLog or other Swift logging systems
#[uniffi::export]
pub fn mls_set_logger(logger: Box<dyn MLSLogger>) {
    crate::logging::set_logger(logger);
}

/// Compute the hash reference for a serialized KeyPackage
/// Accepts either an MlsMessage-wrapped KeyPackage or raw KeyPackage bytes
/// This is useful when you need to compute a hash from KeyPackage bytes received from the server
#[uniffi::export]
pub fn mls_compute_key_package_hash(key_package_bytes: Vec<u8>) -> Result<Vec<u8>, MLSError> {
    use openmls::prelude::*;
    use openmls_rust_crypto::OpenMlsRustCrypto;
    
    let provider = OpenMlsRustCrypto::default();
    
    // Try MlsMessage-wrapped format first
    if let Ok((mls_msg, _)) = MlsMessageIn::tls_deserialize_bytes(&key_package_bytes) {
        if let MlsMessageBodyIn::KeyPackage(kp_in) = mls_msg.extract() {
            let kp = kp_in
                .validate(provider.crypto(), ProtocolVersion::default())
                .map_err(|_| MLSError::InvalidKeyPackage)?;
            return Ok(kp
                .hash_ref(provider.crypto())
                .map_err(|_| MLSError::OpenMLSError)?
                .as_slice()
                .to_vec());
        }
    }
    
    // Fallback: raw KeyPackage format
    let (kp_in, _remaining) = KeyPackageIn::tls_deserialize_bytes(&key_package_bytes)
        .map_err(|_| MLSError::SerializationError)?;
    let kp = kp_in
        .validate(provider.crypto(), ProtocolVersion::default())
        .map_err(|_| MLSError::InvalidKeyPackage)?;
    Ok(kp
        .hash_ref(provider.crypto())
        .map_err(|_| MLSError::OpenMLSError)?
        .as_slice()
        .to_vec())
}
