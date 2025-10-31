use std::collections::HashMap;
use openmls::prelude::*;
use openmls::group::PURE_CIPHERTEXT_WIRE_FORMAT_POLICY;
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;
use tls_codec::{Serialize as TlsSerialize, Deserialize as TlsDeserialize};
use serde::{Serialize, Deserialize};

use crate::error::MLSError;

/// Serializable metadata for persisting group state
#[derive(Serialize, Deserialize)]
struct GroupMetadata {
    group_id: Vec<u8>,
    signer_public_key: Vec<u8>,
}

/// Complete serialized state including storage and group metadata
#[derive(Serialize, Deserialize)]
struct SerializedState {
    storage_bytes: Vec<u8>,
    group_metadata: Vec<GroupMetadata>,
    signers_by_identity: Vec<(String, String)>, // hex-encoded key-value pairs
}

pub struct GroupState {
    pub group: MlsGroup,
    pub signer_public_key: Vec<u8>,
}

pub struct MLSContextInner {
    provider: OpenMlsRustCrypto,
    groups: HashMap<Vec<u8>, GroupState>,
    signers_by_identity: HashMap<Vec<u8>, Vec<u8>>, // identity -> public key bytes
    staged_welcomes: HashMap<String, StagedWelcome>,
    staged_commits: HashMap<String, Box<StagedCommit>>,
}

impl MLSContextInner {
    pub fn new() -> Self {
        Self {
            provider: OpenMlsRustCrypto::default(),
            groups: HashMap::new(),
            signers_by_identity: HashMap::new(),
            staged_welcomes: HashMap::new(),
            staged_commits: HashMap::new(),
        }
    }

    pub fn provider(&self) -> &OpenMlsRustCrypto {
        &self.provider
    }

    pub fn create_group(&mut self, identity: &str, config: crate::types::GroupConfig) -> Result<Vec<u8>, MLSError> {
        eprintln!("[MLS-CONTEXT] create_group: Starting for identity '{}'", identity);
        
        let credential = Credential::new(
            CredentialType::Basic,
            identity.as_bytes().to_vec()
        );
        eprintln!("[MLS-CONTEXT] Credential created");
        
        eprintln!("[MLS-CONTEXT] Generating signature keys...");
        let signature_keys = SignatureKeyPair::new(SignatureScheme::ED25519)
            .map_err(|e| {
                eprintln!("[MLS-CONTEXT] ERROR: Failed to create signature keys: {:?}", e);
                MLSError::OpenMLSError
            })?;
        eprintln!("[MLS-CONTEXT] Signature keys generated");

        eprintln!("[MLS-CONTEXT] Storing signature keys...");
        signature_keys.store(self.provider.storage())
            .map_err(|e| {
                eprintln!("[MLS-CONTEXT] ERROR: Failed to store signature keys: {:?}", e);
                MLSError::OpenMLSError
            })?;
        eprintln!("[MLS-CONTEXT] Signature keys stored");

        // Build group config with forward secrecy settings
        eprintln!("[MLS-CONTEXT] Building group config...");
        let group_config = MlsGroupCreateConfig::builder()
            .max_past_epochs(config.max_past_epochs as usize)
            .sender_ratchet_configuration(SenderRatchetConfiguration::new(
                config.out_of_order_tolerance,
                config.maximum_forward_distance,
            ))
            .wire_format_policy(PURE_CIPHERTEXT_WIRE_FORMAT_POLICY)
            .build();
        eprintln!("[MLS-CONTEXT] Group config built");

        eprintln!("[MLS-CONTEXT] Creating MLS group...");
        let group = MlsGroup::new(
            &self.provider,
            &signature_keys,
            &group_config,
            CredentialWithKey {
                credential,
                signature_key: signature_keys.public().into(),
            },
        )
        .map_err(|e| {
            eprintln!("[MLS-CONTEXT] ERROR: Failed to create MLS group: {:?}", e);
            MLSError::OpenMLSError
        })?;
        eprintln!("[MLS-CONTEXT] MLS group created successfully");

        let group_id = group.group_id().as_slice().to_vec();
        eprintln!("[MLS-CONTEXT] Group ID: {}", hex::encode(&group_id));

        self.groups.insert(group_id.clone(), GroupState {
            group,
            signer_public_key: signature_keys.public().to_vec(),
        });
        eprintln!("[MLS-CONTEXT] Group state stored");

        self.signers_by_identity.insert(identity.as_bytes().to_vec(), signature_keys.public().to_vec());
        eprintln!("[MLS-CONTEXT] Signer mapped to identity");

        eprintln!("[MLS-CONTEXT] create_group: Completed successfully");
        Ok(group_id)
    }

    pub fn add_group(&mut self, group: MlsGroup, identity: &str) -> Result<(), MLSError> {
        let signer_pk = self.signers_by_identity
            .get(identity.as_bytes())
            .ok_or_else(|| MLSError::group_not_found(format!("No signer for identity: {}", identity)))?
            .clone();
        
        let group_id = group.group_id().as_slice().to_vec();
        self.groups.insert(group_id, GroupState { 
            group, 
            signer_public_key: signer_pk 
        });
        Ok(())
    }

    pub fn signer_for_group(&self, group_id: &GroupId) -> Result<SignatureKeyPair, MLSError> {
        let state = self.groups
            .get(group_id.as_slice())
            .ok_or_else(|| MLSError::group_not_found(hex::encode(group_id.as_slice())))?;
        
        // Load signer from storage using public key
        SignatureKeyPair::read(
            self.provider.storage(), 
            &state.signer_public_key,
            SignatureScheme::ED25519
        )
            .ok_or_else(|| MLSError::OpenMLSError)
    }

    pub fn with_group<T, F: FnOnce(&mut MlsGroup, &OpenMlsRustCrypto, &SignatureKeyPair) -> Result<T, MLSError>>(
        &mut self,
        group_id: &GroupId,
        f: F,
    ) -> Result<T, MLSError> {
        eprintln!("[MLS-CONTEXT] with_group: Looking up group {}", hex::encode(group_id.as_slice()));
        
        // Check if group exists first (before mutable borrow)
        if !self.groups.contains_key(group_id.as_slice()) {
            eprintln!("[MLS-CONTEXT] ERROR: Group not found: {}", hex::encode(group_id.as_slice()));
            let available: Vec<String> = self.groups.keys().map(|k| hex::encode(k)).collect();
            eprintln!("[MLS-CONTEXT] Available groups: {:?}", available);
            return Err(MLSError::group_not_found(hex::encode(group_id.as_slice())));
        }
        
        // Now safe to get mutable reference
        let state = match self.groups.get_mut(group_id.as_slice()) {
            Some(s) => s,
            None => return Err(MLSError::group_not_found(hex::encode(group_id.as_slice()))),
        };
        eprintln!("[MLS-CONTEXT] Group found");
        
        // Load signer from storage
        eprintln!("[MLS-CONTEXT] Loading signer from storage...");
        let signer = SignatureKeyPair::read(
            self.provider.storage(), 
            &state.signer_public_key,
            SignatureScheme::ED25519
        )
            .ok_or_else(|| {
                eprintln!("[MLS-CONTEXT] ERROR: Failed to load signer from storage");
                MLSError::OpenMLSError
            })?;
        eprintln!("[MLS-CONTEXT] Signer loaded successfully");
        
        f(&mut state.group, &self.provider, &signer)
    }

    pub fn with_group_ref<T, F: FnOnce(&MlsGroup, &OpenMlsRustCrypto) -> Result<T, MLSError>>(
        &self,
        group_id: &GroupId,
        f: F,
    ) -> Result<T, MLSError> {
        let state = self.groups
            .get(group_id.as_slice())
            .ok_or_else(|| MLSError::group_not_found(hex::encode(group_id.as_slice())))?;
        f(&state.group, &self.provider)
    }

    pub fn store_staged_welcome(&mut self, id: String, staged: StagedWelcome) {
        self.staged_welcomes.insert(id, staged);
    }

    pub fn take_staged_welcome(&mut self, id: &str) -> Result<StagedWelcome, MLSError> {
        self.staged_welcomes.remove(id)
            .ok_or_else(|| MLSError::invalid_input("Staged welcome not found"))
    }

    pub fn store_staged_commit(&mut self, id: String, staged: Box<StagedCommit>) {
        self.staged_commits.insert(id, staged);
    }

    pub fn take_staged_commit(&mut self, id: &str) -> Result<Box<StagedCommit>, MLSError> {
        self.staged_commits.remove(id)
            .ok_or_else(|| MLSError::invalid_input("Staged commit not found"))
    }

    /// Check if a group exists in the context
    pub fn has_group(&self, group_id: &[u8]) -> bool {
        self.groups.contains_key(group_id)
    }

    /// Export a group's state for persistent storage
    ///
    /// Uses OpenMLS's built-in load/save mechanism.
    /// Returns just the group ID and signer key - the group state
    /// is persisted in OpenMLS's internal storage which is memory-based.
    ///
    /// NOTE: This is a simplified implementation. For true persistence,
    /// we'd need to implement a custom StorageProvider that writes to disk.
    pub fn export_group_state(&self, group_id: &[u8]) -> Result<Vec<u8>, MLSError> {
        eprintln!("[MLS-CONTEXT] export_group_state: Starting for group {}", hex::encode(group_id));

        let state = self.groups
            .get(group_id)
            .ok_or_else(|| {
                eprintln!("[MLS-CONTEXT] ERROR: Group not found for export");
                MLSError::group_not_found(hex::encode(group_id))
            })?;

        // For now, just return the signer public key and group ID
        // The actual group state is in OpenMLS's provider storage (memory)
        // This is sufficient for the singleton approach

        // Format: [group_id_len: u32][group_id][signer_key_len: u32][signer_key]
        let mut result = Vec::new();
        let gid_len = group_id.len() as u32;
        let key_len = state.signer_public_key.len() as u32;

        result.extend_from_slice(&gid_len.to_le_bytes());
        result.extend_from_slice(group_id);
        result.extend_from_slice(&key_len.to_le_bytes());
        result.extend_from_slice(&state.signer_public_key);

        eprintln!("[MLS-CONTEXT] export_group_state: Complete, total {} bytes", result.len());
        Ok(result)
    }

    /// Import a group's state from persistent storage
    ///
    /// NOTE: This is a placeholder for the singleton approach.
    /// Groups are already in memory, so this just validates the group exists.
    pub fn import_group_state(&mut self, state_bytes: &[u8]) -> Result<Vec<u8>, MLSError> {
        eprintln!("[MLS-CONTEXT] import_group_state: Starting with {} bytes", state_bytes.len());

        if state_bytes.len() < 8 {
            eprintln!("[MLS-CONTEXT] ERROR: State bytes too short");
            return Err(MLSError::invalid_input("State bytes too short"));
        }

        // Parse: [group_id_len: u32][group_id][signer_key_len: u32][signer_key]
        let gid_len = u32::from_le_bytes([
            state_bytes[0], state_bytes[1], state_bytes[2], state_bytes[3]
        ]) as usize;

        if state_bytes.len() < 4 + gid_len + 4 {
            eprintln!("[MLS-CONTEXT] ERROR: Invalid state format");
            return Err(MLSError::invalid_input("Invalid state format"));
        }

        let group_id = state_bytes[4..4+gid_len].to_vec();
        eprintln!("[MLS-CONTEXT] Group ID from state: {}", hex::encode(&group_id));

        // Check if group exists (singleton keeps it in memory)
        if self.has_group(&group_id) {
            eprintln!("[MLS-CONTEXT] Group already loaded in memory");
            Ok(group_id)
        } else {
            eprintln!("[MLS-CONTEXT] Group not found - needs reconstruction from Welcome");
            Err(MLSError::group_not_found(hex::encode(&group_id)))
        }
    }

    /// Serialize the entire OpenMLS storage and group metadata to bytes for persistence
    ///
    /// This serializes:
    /// 1. All groups, keys, and secrets stored in the provider's MemoryStorage
    /// 2. Group metadata (group IDs and their associated signer public keys)
    /// 3. Identity-to-signer mappings
    ///
    /// The resulting bytes can be saved to Core Data/Keychain and restored on app restart.
    pub fn serialize_storage(&self) -> Result<Vec<u8>, MLSError> {
        eprintln!("[MLS-CONTEXT] serialize_storage: Starting");

        // Serialize the raw storage
        let mut storage_buffer = Vec::new();
        self.provider.storage()
            .serialize(&mut storage_buffer)
            .map_err(|e| {
                eprintln!("[MLS-CONTEXT] ERROR: Failed to serialize storage: {:?}", e);
                MLSError::invalid_input(format!("Serialization failed: {}", e))
            })?;

        eprintln!("[MLS-CONTEXT] Serialized storage: {} bytes", storage_buffer.len());

        // Collect group metadata
        let group_metadata: Vec<GroupMetadata> = self.groups.iter()
            .map(|(group_id, state)| GroupMetadata {
                group_id: group_id.clone(),
                signer_public_key: state.signer_public_key.clone(),
            })
            .collect();

        eprintln!("[MLS-CONTEXT] Collected metadata for {} groups", group_metadata.len());

        // Convert signers_by_identity to hex-encoded strings for JSON serialization
        eprintln!("[MLS-CONTEXT] Converting {} signers_by_identity entries to hex...", self.signers_by_identity.len());
        let signers_by_identity_hex: Vec<(String, String)> = self.signers_by_identity.iter()
            .enumerate()
            .map(|(i, (k, v))| {
                let k_hex = hex::encode(k);
                let v_hex = hex::encode(v);
                eprintln!("[MLS-CONTEXT]   Entry {}: key={} ({} bytes), value={} ({} bytes)", 
                    i, k_hex, k.len(), v_hex, v.len());
                (k_hex, v_hex)
            })
            .collect();
        eprintln!("[MLS-CONTEXT] Hex conversion complete: {} entries", signers_by_identity_hex.len());

        // Create complete serialized state
        let serialized_state = SerializedState {
            storage_bytes: storage_buffer,
            group_metadata,
            signers_by_identity: signers_by_identity_hex,
        };

        // Serialize to JSON
        let json_bytes = serde_json::to_vec(&serialized_state)
            .map_err(|e| {
                eprintln!("[MLS-CONTEXT] ERROR: Failed to serialize state to JSON: {:?}", e);
                MLSError::invalid_input(format!("JSON serialization failed: {}", e))
            })?;

        eprintln!("[MLS-CONTEXT] serialize_storage: Complete, {} bytes total", json_bytes.len());
        Ok(json_bytes)
    }

    /// Deserialize and restore OpenMLS storage and group metadata from bytes
    ///
    /// This restores:
    /// 1. All groups, keys, and secrets from the storage
    /// 2. Group metadata (group IDs and their associated signer public keys)
    /// 3. Identity-to-signer mappings
    ///
    /// Must be called before any other operations if restoring from persistent storage.
    ///
    /// NOTE: This replaces the entire storage, so it should only be called
    /// during initialization, not after groups are already created.
    pub fn deserialize_storage(&mut self, json_bytes: &[u8]) -> Result<(), MLSError> {
        eprintln!("[MLS-CONTEXT] deserialize_storage: Starting with {} bytes", json_bytes.len());

        // Deserialize the JSON state
        let serialized_state: SerializedState = serde_json::from_slice(json_bytes)
            .map_err(|e| {
                eprintln!("[MLS-CONTEXT] ERROR: Failed to deserialize JSON: {:?}", e);
                MLSError::invalid_input(format!("JSON deserialization failed: {}", e))
            })?;

        eprintln!("[MLS-CONTEXT] Deserialized {} groups metadata", serialized_state.group_metadata.len());

        // Deserialize the raw storage
        use std::io::Cursor;
        let mut cursor = Cursor::new(&serialized_state.storage_bytes);

        let loaded_storage = openmls_rust_crypto::MemoryStorage::deserialize(&mut cursor)
            .map_err(|e| {
                eprintln!("[MLS-CONTEXT] ERROR: Failed to deserialize storage: {:?}", e);
                MLSError::invalid_input(format!("Storage deserialization failed: {}", e))
            })?;

        // Replace the HashMap in the existing storage
        let mut current_values = self.provider.storage().values.write().unwrap();
        let loaded_values = loaded_storage.values.read().unwrap();

        current_values.clear();
        current_values.extend(loaded_values.clone());
        drop(current_values); // Release write lock

        eprintln!("[MLS-CONTEXT] Restored {} storage entries", loaded_values.len());

        // Restore groups HashMap by loading each group from storage
        self.groups.clear();
        for metadata in serialized_state.group_metadata {
            let group_id_bytes = metadata.group_id;
            let group_id = GroupId::from_slice(&group_id_bytes);

            // Load the MlsGroup from storage
            match MlsGroup::load(self.provider.storage(), &group_id) {
                Ok(Some(group)) => {
                    eprintln!("[MLS-CONTEXT] Loaded group: {}", hex::encode(&group_id_bytes));
                    self.groups.insert(group_id_bytes, GroupState {
                        group,
                        signer_public_key: metadata.signer_public_key,
                    });
                }
                Ok(None) => {
                    eprintln!("[MLS-CONTEXT] WARNING: Group {} in metadata but not in storage", hex::encode(&group_id_bytes));
                }
                Err(e) => {
                    eprintln!("[MLS-CONTEXT] ERROR: Failed to load group {}: {:?}", hex::encode(&group_id_bytes), e);
                }
            }
        }

        eprintln!("[MLS-CONTEXT] Restored {} groups", self.groups.len());

        // Restore identity-to-signer mappings by decoding hex strings
        self.signers_by_identity.clear();
        for (key_hex, value_hex) in serialized_state.signers_by_identity {
            let key = hex::decode(&key_hex)
                .map_err(|e| {
                    eprintln!("[MLS-CONTEXT] ERROR: Failed to decode hex key: {:?}", e);
                    MLSError::invalid_input(format!("Failed to decode identity key: {}", e))
                })?;
            let value = hex::decode(&value_hex)
                .map_err(|e| {
                    eprintln!("[MLS-CONTEXT] ERROR: Failed to decode hex value: {:?}", e);
                    MLSError::invalid_input(format!("Failed to decode signer public key: {}", e))
                })?;
            self.signers_by_identity.insert(key, value);
        }
        eprintln!("[MLS-CONTEXT] Restored {} identity mappings", self.signers_by_identity.len());

        eprintln!("[MLS-CONTEXT] deserialize_storage: Complete");
        Ok(())
    }
}
