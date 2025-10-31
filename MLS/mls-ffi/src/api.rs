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

    pub fn create_group(&self, identity_bytes: Vec<u8>, config: Option<GroupConfig>) -> Result<GroupCreationResult, MLSError> {
        eprintln!("[MLS-FFI] create_group: Starting");
        eprintln!("[MLS-FFI] Identity bytes: {} bytes", identity_bytes.len());
        
        let mut inner = self.inner.write()
            .map_err(|e| {
                eprintln!("[MLS-FFI] ERROR: Failed to acquire write lock: {:?}", e);
                MLSError::ContextNotInitialized
            })?;

        let identity = String::from_utf8(identity_bytes)
            .map_err(|e| {
                eprintln!("[MLS-FFI] ERROR: Invalid UTF-8 in identity: {:?}", e);
                MLSError::invalid_input("Invalid UTF-8")
            })?;
        eprintln!("[MLS-FFI] Identity: {}", identity);

        let group_config = config.unwrap_or_default();
        eprintln!("[MLS-FFI] Group config - max_past_epochs: {}, out_of_order_tolerance: {}, maximum_forward_distance: {}", 
            group_config.max_past_epochs, group_config.out_of_order_tolerance, group_config.maximum_forward_distance);
        
        let group_id = inner.create_group(&identity, group_config)?;
        eprintln!("[MLS-FFI] Group created successfully, ID: {}", hex::encode(&group_id));

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
        
        eprintln!("[MLS] add_members: Processing {} key packages", key_packages.len());
        for (i, kp) in key_packages.iter().enumerate() {
            eprintln!("[MLS] KeyPackage {}: {} bytes", i, kp.data.len());
        }
        
        // Deserialize key packages from TLS format
        // Try both MlsMessage-wrapped format and raw KeyPackage format
        let kps: Vec<KeyPackage> = key_packages
            .iter()
            .enumerate()
            .map(|(idx, kp_data)| {
                eprintln!("[MLS] Deserializing key package {}: {} bytes, first 16 bytes = {:02x?}", 
                    idx, kp_data.data.len(), &kp_data.data[..kp_data.data.len().min(16)]);
                
                // First try: MlsMessage-wrapped format (server might send this)
                if let Ok((mls_msg, _)) = MlsMessageIn::tls_deserialize_bytes(&kp_data.data) {
                    eprintln!("[MLS] Key package {} deserialized as MlsMessage", idx);
                    match mls_msg.extract() {
                        MlsMessageBodyIn::KeyPackage(kp_in) => {
                            eprintln!("[MLS] Extracted KeyPackage from MlsMessage");
                            return kp_in.validate(inner.provider().crypto(), ProtocolVersion::default())
                                .map_err(|e| {
                                    eprintln!("[MLS] Key package {} validation failed: {:?}", idx, e);
                                    MLSError::InvalidKeyPackage
                                });
                        }
                        other => {
                            eprintln!("[MLS] MlsMessage contained unexpected type: {:?}, trying raw format", 
                                std::mem::discriminant(&other));
                        }
                    }
                }
                
                // Second try: Raw KeyPackage format
                eprintln!("[MLS] Trying raw KeyPackage deserialization for key package {}", idx);
                let (kp_in, remaining) = KeyPackageIn::tls_deserialize_bytes(&kp_data.data)
                    .map_err(|e| {
                        eprintln!("[MLS] Both deserialization methods failed for key package {}: {:?}", idx, e);
                        MLSError::SerializationError
                    })?;
                
                eprintln!("[MLS] Key package {} deserialized as raw KeyPackage ({} bytes remaining)", idx, remaining.len());
                
                // Validate the key package
                kp_in.validate(inner.provider().crypto(), ProtocolVersion::default())
                    .map_err(|e| {
                        eprintln!("[MLS] Key package {} validation failed: {:?}", idx, e);
                        MLSError::InvalidKeyPackage
                    })
            })
            .collect::<Result<Vec<_>, _>>()?;

        if kps.is_empty() {
            return Err(MLSError::InvalidKeyPackage);
        }

        let gid = GroupId::from_slice(&group_id);
        
        let (commit_data, welcome_data) = inner.with_group(&gid, |group, provider, signer| {
            let (commit, welcome, _group_info) = group
                .add_members(provider, signer, &kps)
                .map_err(|_| MLSError::AddMembersFailed)?;

            // Don't auto-merge - let Swift validate and confirm with server first
            // The pending commit remains staged until explicitly merged

            let commit_bytes = commit
                .tls_serialize_detached()
                .map_err(|_| MLSError::SerializationError)?;
            
            let welcome_bytes = welcome
                .tls_serialize_detached()
                .map_err(|_| MLSError::SerializationError)?;
            
            Ok((commit_bytes, welcome_bytes))
        })?;

        Ok(AddMembersResult {
            commit_data,
            welcome_data,
        })
    }

    pub fn encrypt_message(
        &self,
        group_id: Vec<u8>,
        plaintext: Vec<u8>,
    ) -> Result<EncryptResult, MLSError> {
        eprintln!("[MLS-FFI] encrypt_message: Starting");
        eprintln!("[MLS-FFI] Group ID: {} ({} bytes)", hex::encode(&group_id), group_id.len());
        eprintln!("[MLS-FFI] Plaintext size: {} bytes", plaintext.len());
        
        let mut inner = self.inner.write()
            .map_err(|e| {
                eprintln!("[MLS-FFI] ERROR: Failed to acquire write lock: {:?}", e);
                MLSError::ContextNotInitialized
            })?;
        
        let gid = GroupId::from_slice(&group_id);
        eprintln!("[MLS-FFI] GroupId created");
        
        let ciphertext = inner.with_group(&gid, |group, provider, signer| {
            eprintln!("[MLS-FFI] Inside with_group for encryption");
            eprintln!("[MLS-FFI] Current epoch: {:?}", group.epoch());
            
            eprintln!("[MLS-FFI] Creating encrypted message...");
            let msg = group
                .create_message(provider, signer, &plaintext)
                .map_err(|e| {
                    eprintln!("[MLS-FFI] ERROR: Failed to create message: {:?}", e);
                    MLSError::EncryptionFailed
                })?;
            eprintln!("[MLS-FFI] Message created successfully");
            
            eprintln!("[MLS-FFI] Serializing message...");
            msg.tls_serialize_detached()
                .map_err(|e| {
                    eprintln!("[MLS-FFI] ERROR: Failed to serialize message: {:?}", e);
                    MLSError::SerializationError
                })
        })?;

        eprintln!("[MLS-FFI] encrypt_message: Completed successfully, ciphertext size: {} bytes", ciphertext.len());
        Ok(EncryptResult { ciphertext })
    }

    pub fn decrypt_message(
        &self,
        group_id: Vec<u8>,
        ciphertext: Vec<u8>,
    ) -> Result<DecryptResult, MLSError> {
        eprintln!("[MLS-FFI] decrypt_message: Starting decryption");
        eprintln!("[MLS-FFI] Group ID: {} ({} bytes)", hex::encode(&group_id), group_id.len());
        eprintln!("[MLS-FFI] Ciphertext size: {} bytes", ciphertext.len());
        eprintln!("[MLS-FFI] Ciphertext first 32 bytes: {:02x?}", &ciphertext[..ciphertext.len().min(32)]);
        
        let mut inner = self.inner.write()
            .map_err(|e| {
                eprintln!("[MLS-FFI] ERROR: Failed to acquire write lock: {:?}", e);
                MLSError::ContextNotInitialized
            })?;
        
        let gid = GroupId::from_slice(&group_id);
        eprintln!("[MLS-FFI] GroupId created from slice");
        
        let plaintext = inner.with_group(&gid, |group, provider, _signer| {
            eprintln!("[MLS-FFI] Inside with_group closure");
            eprintln!("[MLS-FFI] Current group epoch: {:?}", group.epoch());
            eprintln!("[MLS-FFI] Group ciphersuite: {:?}", group.ciphersuite());
            
            eprintln!("[MLS-FFI] Attempting to deserialize MlsMessage...");
            let (mls_msg, remaining) = MlsMessageIn::tls_deserialize_bytes(&ciphertext)
                .map_err(|e| {
                    eprintln!("[MLS-FFI] ERROR: Failed to deserialize MlsMessage: {:?}", e);
                    MLSError::SerializationError
                })?;
            eprintln!("[MLS-FFI] MlsMessage deserialized successfully ({} bytes remaining)", remaining.len());
            
            eprintln!("[MLS-FFI] Converting MlsMessage to ProtocolMessage...");
            let protocol_msg: ProtocolMessage = mls_msg.try_into()
                .map_err(|e| {
                    eprintln!("[MLS-FFI] ERROR: Failed to convert to ProtocolMessage: {:?}", e);
                    MLSError::DecryptionFailed
                })?;
            eprintln!("[MLS-FFI] ProtocolMessage created successfully");
            eprintln!("[MLS-FFI] Protocol message epoch: {:?}", protocol_msg.epoch());
            
            eprintln!("[MLS-FFI] Calling OpenMLS process_message...");
            let processed = group
                .process_message(provider, protocol_msg)
                .map_err(|e| {
                    eprintln!("[MLS-FFI] ERROR: OpenMLS process_message failed: {:?}", e);
                    eprintln!("[MLS-FFI] ERROR: Error type: {}", std::any::type_name_of_val(&e));
                    MLSError::DecryptionFailed
                })?;
            eprintln!("[MLS-FFI] OpenMLS process_message succeeded");
            
            eprintln!("[MLS-FFI] Processing message content...");
            match processed.into_content() {
                ProcessedMessageContent::ApplicationMessage(app_msg) => {
                    let bytes = app_msg.into_bytes();
                    eprintln!("[MLS-FFI] ApplicationMessage processed: {} bytes", bytes.len());
                    Ok(bytes)
                },
                ProcessedMessageContent::ProposalMessage(prop) => {
                    eprintln!("[MLS-FFI] ProposalMessage received: {:?}", std::any::type_name_of_val(&prop));
                    Ok(vec![]) // Proposals don't have plaintext
                },
                ProcessedMessageContent::ExternalJoinProposalMessage(ext) => {
                    eprintln!("[MLS-FFI] ExternalJoinProposalMessage received: {:?}", std::any::type_name_of_val(&ext));
                    Ok(vec![])
                },
                ProcessedMessageContent::StagedCommitMessage(staged) => {
                    eprintln!("[MLS-FFI] StagedCommitMessage received: {:?}", std::any::type_name_of_val(&staged));
                    // Don't auto-merge - let Swift validate first
                    // Return empty vec to indicate staged commit (Swift will use process_message instead)
                    Ok(vec![])
                },
            }
        })?;

        eprintln!("[MLS-FFI] decrypt_message: Completed successfully, plaintext size: {} bytes", plaintext.len());
        Ok(DecryptResult { plaintext })
    }

    pub fn process_message(
        &self,
        group_id: Vec<u8>,
        message_data: Vec<u8>,
    ) -> Result<ProcessedContent, MLSError> {
        eprintln!("[MLS-FFI] process_message: Starting");
        eprintln!("[MLS-FFI] Group ID: {} ({} bytes)", hex::encode(&group_id), group_id.len());
        eprintln!("[MLS-FFI] Message data size: {} bytes", message_data.len());
        eprintln!("[MLS-FFI] Message data first 32 bytes: {:02x?}", &message_data[..message_data.len().min(32)]);
        
        let mut inner = self.inner.write()
            .map_err(|e| {
                eprintln!("[MLS-FFI] ERROR: Failed to acquire write lock: {:?}", e);
                MLSError::ContextNotInitialized
            })?;

        let gid = GroupId::from_slice(&group_id);
        eprintln!("[MLS-FFI] GroupId created: {}", hex::encode(gid.as_slice()));

        inner.with_group(&gid, |group, provider, _signer| {
            eprintln!("[MLS-FFI] Inside with_group closure for process_message");
            eprintln!("[MLS-FFI] Current group epoch: {:?}", group.epoch());
            eprintln!("[MLS-FFI] Group ciphersuite: {:?}", group.ciphersuite());
            eprintln!("[MLS-FFI] Group members count: {}", group.members().count());
            
            eprintln!("[MLS-FFI] Deserializing MlsMessage...");
            let (mls_msg, remaining) = MlsMessageIn::tls_deserialize_bytes(&message_data)
                .map_err(|e| {
                    eprintln!("[MLS-FFI] ERROR: Failed to deserialize MlsMessage: {:?}", e);
                    MLSError::SerializationError
                })?;
            eprintln!("[MLS-FFI] MlsMessage deserialized ({} bytes remaining)", remaining.len());

            eprintln!("[MLS-FFI] Converting to ProtocolMessage...");
            let protocol_msg: ProtocolMessage = mls_msg.try_into()
                .map_err(|e| {
                    eprintln!("[MLS-FFI] ERROR: Failed to convert to ProtocolMessage: {:?}", e);
                    MLSError::DecryptionFailed
                })?;
            eprintln!("[MLS-FFI] ProtocolMessage created");
            eprintln!("[MLS-FFI] Protocol message epoch: {:?}", protocol_msg.epoch());
            eprintln!("[MLS-FFI] Protocol message content type: {:?}", std::any::type_name_of_val(&protocol_msg));

            eprintln!("[MLS-FFI] Calling OpenMLS process_message...");
            let processed = group
                .process_message(provider, protocol_msg)
                .map_err(|e| {
                    eprintln!("[MLS-FFI] ERROR: OpenMLS process_message failed!");
                    eprintln!("[MLS-FFI] ERROR: Error details: {:?}", e);
                    eprintln!("[MLS-FFI] ERROR: Error type: {}", std::any::type_name_of_val(&e));
                    eprintln!("[MLS-FFI] ERROR: Current epoch: {:?}", group.epoch());
                    MLSError::DecryptionFailed
                })?;
            eprintln!("[MLS-FFI] OpenMLS process_message succeeded!");

            eprintln!("[MLS-FFI] Processing message content type...");
            match processed.into_content() {
                ProcessedMessageContent::ApplicationMessage(app_msg) => {
                    let plaintext = app_msg.into_bytes();
                    eprintln!("[MLS-FFI] ApplicationMessage processed: {} bytes", plaintext.len());
                    Ok(ProcessedContent::ApplicationMessage {
                        plaintext,
                    })
                },
                ProcessedMessageContent::ProposalMessage(proposal_msg) => {
                    eprintln!("[MLS-FFI] ProposalMessage received, processing...");
                    let proposal = proposal_msg.proposal();

                    // Compute proposal reference by hashing the proposal
                    // Since proposal_reference() is pub(crate), we compute our own identifier
                    let proposal_bytes = proposal
                        .tls_serialize_detached()
                        .map_err(|e| {
                            eprintln!("[MLS-FFI] ERROR: Failed to serialize proposal: {:?}", e);
                            MLSError::SerializationError
                        })?;

                    let proposal_ref_bytes = provider.crypto()
                        .hash(group.ciphersuite().hash_algorithm(), &proposal_bytes)
                        .map_err(|e| {
                            eprintln!("[MLS-FFI] ERROR: Failed to hash proposal: {:?}", e);
                            MLSError::OpenMLSError
                        })?;

                    eprintln!("[MLS-FFI] Proposal ref computed: {}", hex::encode(&proposal_ref_bytes));
                    
                    let proposal_info = match proposal {
                        Proposal::Add(add_proposal) => {
                            eprintln!("[MLS-FFI] Add proposal detected");
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
                            eprintln!("[MLS-FFI] Remove proposal detected, index: {}", remove_proposal.removed().u32());
                            ProposalInfo::Remove {
                                info: RemoveProposalInfo {
                                    removed_index: remove_proposal.removed().u32(),
                                }
                            }
                        },
                        Proposal::Update(update_proposal) => {
                            eprintln!("[MLS-FFI] Update proposal detected");
                            let leaf_node = update_proposal.leaf_node();
                            let credential = leaf_node.credential();

                            let credential_info = CredentialData {
                                credential_type: format!("{:?}", credential.credential_type()),
                                identity: credential.serialized_content().to_vec(),
                            };

                            let leaf_index = group.own_leaf_index().u32();
                            eprintln!("[MLS-FFI] Update proposal leaf index: {}", leaf_index);

                            ProposalInfo::Update {
                                info: UpdateProposalInfo {
                                    leaf_index,
                                    old_credential: credential_info.clone(),
                                    new_credential: credential_info,
                                }
                            }
                        },
                        _ => {
                            eprintln!("[MLS-FFI] ERROR: Unsupported proposal type");
                            return Err(MLSError::invalid_input("Unsupported proposal type"));
                        }
                    };

                    eprintln!("[MLS-FFI] Proposal processed successfully");
                    Ok(ProcessedContent::Proposal {
                        proposal: proposal_info,
                        proposal_ref: ProposalRef {
                            data: proposal_ref_bytes,
                        },
                    })
                },
                ProcessedMessageContent::ExternalJoinProposalMessage(_) => {
                    eprintln!("[MLS-FFI] ERROR: External join proposals not supported");
                    Err(MLSError::invalid_input("External join proposals not supported"))
                },
                ProcessedMessageContent::StagedCommitMessage(staged) => {
                    eprintln!("[MLS-FFI] StagedCommitMessage received, processing...");
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
        let inner = self.inner.read()
            .map_err(|_| MLSError::ContextNotInitialized)?;
        
        let identity = String::from_utf8(identity_bytes)
            .map_err(|_| MLSError::invalid_input("Invalid UTF-8"))?;
        
        let credential = Credential::new(
            CredentialType::Basic,
            identity.into_bytes()
        );
        let signature_keys = SignatureKeyPair::new(SignatureScheme::ED25519)
            .map_err(|_| MLSError::OpenMLSError)?;
        
        signature_keys.store(inner.provider().storage())
            .map_err(|_| MLSError::OpenMLSError)?;
        
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

        Ok(KeyPackageResult { key_package_data, hash_ref })
    }

    pub fn process_welcome(
        &self,
        welcome_bytes: Vec<u8>,
        identity_bytes: Vec<u8>,
        config: Option<GroupConfig>,
    ) -> Result<WelcomeResult, MLSError> {
        let mut inner = self.inner.write()
            .map_err(|_| MLSError::ContextNotInitialized)?;

        let identity = String::from_utf8(identity_bytes)
            .map_err(|_| MLSError::invalid_input("Invalid UTF-8"))?;

        let (mls_msg, _) = MlsMessageIn::tls_deserialize_bytes(&welcome_bytes)
            .map_err(|_| MLSError::SerializationError)?;

        let welcome = match mls_msg.extract() {
            MlsMessageBodyIn::Welcome(w) => w,
            _ => return Err(MLSError::invalid_input("Not a Welcome message")),
        };

        let group_config = config.unwrap_or_default();

        // Build join config with forward secrecy settings
        let join_config = MlsGroupJoinConfig::builder()
            .max_past_epochs(group_config.max_past_epochs as usize)
            .sender_ratchet_configuration(SenderRatchetConfiguration::new(
                group_config.out_of_order_tolerance,
                group_config.maximum_forward_distance,
            ))
            .wire_format_policy(PURE_CIPHERTEXT_WIRE_FORMAT_POLICY)
            .build();

        let group = StagedWelcome::new_from_welcome(
            inner.provider(),
            &join_config,
            welcome,
            None,
        )
        .map_err(|_| MLSError::OpenMLSError)?
        .into_group(inner.provider())
        .map_err(|_| MLSError::OpenMLSError)?;

        let group_id = group.group_id().as_slice().to_vec();

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
        eprintln!("[MLS-FFI] get_epoch: Starting");
        eprintln!("[MLS-FFI] Group ID: {}", hex::encode(&group_id));
        
        let inner = self.inner.read()
            .map_err(|e| {
                eprintln!("[MLS-FFI] ERROR: Failed to acquire read lock: {:?}", e);
                MLSError::ContextNotInitialized
            })?;
        
        let gid = GroupId::from_slice(&group_id);
        
        inner.with_group_ref(&gid, |group, _provider| {
            let epoch = group.epoch().as_u64();
            eprintln!("[MLS-FFI] Current epoch: {}", epoch);
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
        proposal_ref: ProposalRef,
    ) -> Result<(), MLSError> {
        let mut inner = self.inner.write()
            .map_err(|_| MLSError::ContextNotInitialized)?;

        let gid = GroupId::from_slice(&group_id);

        inner.with_group(&gid, |group, provider, _signer| {
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

        inner.with_group(&gid, |group, provider, _signer| {
            group.merge_pending_commit(provider)
                .map_err(|_| MLSError::MergeFailed)?;

            let new_epoch = group.epoch().as_u64();
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
        eprintln!("[MLS-FFI] export_group_state: Starting");

        let inner = self.inner.read()
            .map_err(|_| MLSError::ContextNotInitialized)?;

        let state_bytes = inner.export_group_state(&group_id)?;

        eprintln!("[MLS-FFI] export_group_state: Complete, {} bytes", state_bytes.len());
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
        eprintln!("[MLS-FFI] import_group_state: Starting with {} bytes", state_bytes.len());

        let mut inner = self.inner.write()
            .map_err(|_| MLSError::ContextNotInitialized)?;

        let group_id = inner.import_group_state(&state_bytes)?;

        eprintln!("[MLS-FFI] import_group_state: Complete, group ID: {}", hex::encode(&group_id));
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
        eprintln!("[MLS-FFI] serialize_storage: Starting");

        let inner = self.inner.read()
            .map_err(|_| MLSError::ContextNotInitialized)?;

        let storage_bytes = inner.serialize_storage()?;

        eprintln!("[MLS-FFI] serialize_storage: Complete, {} bytes", storage_bytes.len());
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
        eprintln!("[MLS-FFI] deserialize_storage: Starting with {} bytes", storage_bytes.len());

        let mut inner = self.inner.write()
            .map_err(|_| MLSError::ContextNotInitialized)?;

        inner.deserialize_storage(&storage_bytes)?;

        eprintln!("[MLS-FFI] deserialize_storage: Complete");
        Ok(())
    }
}
