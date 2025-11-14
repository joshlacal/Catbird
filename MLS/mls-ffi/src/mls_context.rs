use std::collections::HashMap;
use std::sync::Arc;
use openmls::prelude::*;
use openmls::ciphersuite::hash_ref::HashReference;
use openmls::group::PURE_CIPHERTEXT_WIRE_FORMAT_POLICY;
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;
use openmls_traits::storage::StorageProvider;
use serde::{Serialize, Deserialize};

use crate::error::MLSError;
use crate::epoch_storage::EpochSecretManager;

/// Serializable metadata for persisting group state
#[derive(Serialize, Deserialize)]
struct GroupMetadata {
    group_id: Vec<u8>,
    signer_public_key: Vec<u8>,
}

/// Serializable key package bundle (hash_ref and serialized bundle)
#[derive(Serialize, Deserialize)]
struct SerializedKeyPackageBundle {
    hash_ref: Vec<u8>,
    bundle_bytes: Vec<u8>,
}

/// Complete serialized state including storage and group metadata
#[derive(Serialize, Deserialize)]
struct SerializedState {
    storage_bytes: Vec<u8>,
    group_metadata: Vec<GroupMetadata>,
    signers_by_identity: Vec<(String, String)>, // hex-encoded key-value pairs
    key_package_bundles: Vec<SerializedKeyPackageBundle>, // CRITICAL: Must persist bundles for Welcome processing
}

pub struct GroupState {
    pub group: MlsGroup,
    pub signer_public_key: Vec<u8>,
}

pub struct MLSContextInner {
    provider: OpenMlsRustCrypto,
    groups: HashMap<Vec<u8>, GroupState>,
    signers_by_identity: HashMap<Vec<u8>, Vec<u8>>, // identity -> public key bytes
    pub(crate) key_package_bundles: HashMap<Vec<u8>, KeyPackageBundle>, // hash_ref -> bundle
    staged_welcomes: HashMap<String, StagedWelcome>,
    staged_commits: HashMap<String, Box<StagedCommit>>,
    epoch_secret_manager: Arc<EpochSecretManager>,
}

impl MLSContextInner {
    pub fn new() -> Self {
        Self {
            provider: OpenMlsRustCrypto::default(),
            groups: HashMap::new(),
            signers_by_identity: HashMap::new(),
            key_package_bundles: HashMap::new(),
            staged_welcomes: HashMap::new(),
            staged_commits: HashMap::new(),
            epoch_secret_manager: Arc::new(EpochSecretManager::new()),
        }
    }

    /// Get reference to epoch secret manager for setting storage backend
    pub fn epoch_secret_manager(&self) -> &Arc<EpochSecretManager> {
        &self.epoch_secret_manager
    }

    pub fn provider(&self) -> &OpenMlsRustCrypto {
        &self.provider
    }

    pub fn create_group(&mut self, identity: &str, config: crate::types::GroupConfig) -> Result<Vec<u8>, MLSError> {
        crate::debug_log!("[MLS-CONTEXT] create_group: Starting for identity '{}'", identity);
        
        let credential = Credential::new(
            CredentialType::Basic,
            identity.as_bytes().to_vec()
        );
        crate::debug_log!("[MLS-CONTEXT] Credential created");
        
        crate::debug_log!("[MLS-CONTEXT] Generating signature keys...");
        let signature_keys = SignatureKeyPair::new(SignatureScheme::ED25519)
            .map_err(|e| {
                crate::debug_log!("[MLS-CONTEXT] ERROR: Failed to create signature keys: {:?}", e);
                MLSError::OpenMLSError
            })?;
        crate::debug_log!("[MLS-CONTEXT] Signature keys generated");

        crate::debug_log!("[MLS-CONTEXT] Storing signature keys...");
        signature_keys.store(self.provider.storage())
            .map_err(|e| {
                crate::debug_log!("[MLS-CONTEXT] ERROR: Failed to store signature keys: {:?}", e);
                MLSError::OpenMLSError
            })?;
        crate::debug_log!("[MLS-CONTEXT] Signature keys stored");

        // Build group config with forward secrecy settings
        crate::debug_log!("[MLS-CONTEXT] Building group config...");

        // Configure required capabilities to include ratchet tree extension
        // This ensures Welcome messages include the ratchet tree for new members
        let capabilities = Capabilities::new(
            None,  // Default proposals
            None,  // Default credentials
            Some(&[ExtensionType::RatchetTree]),  // REQUIRED: Include ratchet tree in Welcome
            None,  // Default proposals (repeated)
            None,  // Default credential types
        );

        let group_config = MlsGroupCreateConfig::builder()
            .max_past_epochs(config.max_past_epochs as usize)
            .sender_ratchet_configuration(SenderRatchetConfiguration::new(
                config.out_of_order_tolerance,
                config.maximum_forward_distance,
            ))
            .wire_format_policy(PURE_CIPHERTEXT_WIRE_FORMAT_POLICY)
            .capabilities(capabilities)  // Set required capabilities
            .use_ratchet_tree_extension(true)  // CRITICAL: Include ratchet tree in Welcome messages
            .build();
        crate::debug_log!("[MLS-CONTEXT] Group config built with ratchet tree extension capability");

        crate::debug_log!("[MLS-CONTEXT] Creating MLS group...");
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
            crate::debug_log!("[MLS-CONTEXT] ERROR: Failed to create MLS group: {:?}", e);
            MLSError::OpenMLSError
        })?;
        crate::debug_log!("[MLS-CONTEXT] MLS group created successfully");

        // 🔍 DEBUG: Check initial member count (should be 1 - just the creator)
        let initial_member_count = group.members().count();
        crate::debug_log!("[MLS-CONTEXT] 🔍 Initial member count: {} (expected: 1)", initial_member_count);
        if initial_member_count != 1 {
            crate::debug_log!("[MLS-CONTEXT] ⚠️ WARNING: Unexpected initial member count! Expected 1, got {}", initial_member_count);
        }

        let group_id = group.group_id().as_slice().to_vec();
        crate::debug_log!("[MLS-CONTEXT] Group ID: {}", hex::encode(&group_id));

        // CRITICAL: Export epoch 0 secret immediately after group creation
        // This ensures we can decrypt messages sent at epoch 0 even if the group advances
        let current_epoch = group.epoch().as_u64();
        crate::debug_log!("[MLS-CONTEXT] Exporting epoch {} secret after group creation", current_epoch);
        if let Err(e) = self.epoch_secret_manager.export_current_epoch_secret(&group, &self.provider) {
            crate::debug_log!("[MLS-CONTEXT] ⚠️ WARNING: Failed to export epoch secret: {:?}", e);
        } else {
            crate::debug_log!("[MLS-CONTEXT] ✅ Exported epoch {} secret successfully", current_epoch);
        }

        self.groups.insert(group_id.clone(), GroupState {
            group,
            signer_public_key: signature_keys.public().to_vec(),
        });
        crate::debug_log!("[MLS-CONTEXT] Group state stored");

        self.signers_by_identity.insert(identity.as_bytes().to_vec(), signature_keys.public().to_vec());
        crate::debug_log!("[MLS-CONTEXT] Signer mapped to identity");

        crate::debug_log!("[MLS-CONTEXT] create_group: Completed successfully");
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

    /// Register a signer public key for an identity
    /// This must be called when creating key packages so the signer can be found when processing Welcome messages
    pub fn register_signer(&mut self, identity: &str, signer_public_key: Vec<u8>) {
        self.signers_by_identity.insert(identity.as_bytes().to_vec(), signer_public_key);
        crate::debug_log!("[MLS-CONTEXT] Registered signer for identity: {}", identity);
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
        crate::debug_log!("[MLS-CONTEXT] with_group: Looking up group {}", hex::encode(group_id.as_slice()));
        
        // Check if group exists first (before mutable borrow)
        if !self.groups.contains_key(group_id.as_slice()) {
            crate::debug_log!("[MLS-CONTEXT] ERROR: Group not found: {}", hex::encode(group_id.as_slice()));
            let available: Vec<String> = self.groups.keys().map(|k| hex::encode(k)).collect();
            crate::debug_log!("[MLS-CONTEXT] Available groups: {:?}", available);
            return Err(MLSError::group_not_found(hex::encode(group_id.as_slice())));
        }
        
        // Now safe to get mutable reference
        let state = match self.groups.get_mut(group_id.as_slice()) {
            Some(s) => s,
            None => return Err(MLSError::group_not_found(hex::encode(group_id.as_slice()))),
        };
        crate::debug_log!("[MLS-CONTEXT] Group found");
        
        // Load signer from storage
        crate::debug_log!("[MLS-CONTEXT] Loading signer from storage...");
        let signer = SignatureKeyPair::read(
            self.provider.storage(), 
            &state.signer_public_key,
            SignatureScheme::ED25519
        )
            .ok_or_else(|| {
                crate::debug_log!("[MLS-CONTEXT] ERROR: Failed to load signer from storage");
                MLSError::OpenMLSError
            })?;
        crate::debug_log!("[MLS-CONTEXT] Signer loaded successfully");
        
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

    /// Delete a group from the context
    /// Returns true if the group was found and removed, false otherwise
    pub fn delete_group(&mut self, group_id: &[u8]) -> bool {
        self.groups.remove(group_id).is_some()
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
        crate::debug_log!("[MLS-CONTEXT] export_group_state: Starting for group {}", hex::encode(group_id));

        let state = self.groups
            .get(group_id)
            .ok_or_else(|| {
                crate::debug_log!("[MLS-CONTEXT] ERROR: Group not found for export");
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

        crate::debug_log!("[MLS-CONTEXT] export_group_state: Complete, total {} bytes", result.len());
        Ok(result)
    }

    /// Import a group's state from persistent storage
    ///
    /// NOTE: This is a placeholder for the singleton approach.
    /// Groups are already in memory, so this just validates the group exists.
    pub fn import_group_state(&mut self, state_bytes: &[u8]) -> Result<Vec<u8>, MLSError> {
        crate::debug_log!("[MLS-CONTEXT] import_group_state: Starting with {} bytes", state_bytes.len());

        if state_bytes.len() < 8 {
            crate::debug_log!("[MLS-CONTEXT] ERROR: State bytes too short");
            return Err(MLSError::invalid_input("State bytes too short"));
        }

        // Parse: [group_id_len: u32][group_id][signer_key_len: u32][signer_key]
        let gid_len = u32::from_le_bytes([
            state_bytes[0], state_bytes[1], state_bytes[2], state_bytes[3]
        ]) as usize;

        if state_bytes.len() < 4 + gid_len + 4 {
            crate::debug_log!("[MLS-CONTEXT] ERROR: Invalid state format");
            return Err(MLSError::invalid_input("Invalid state format"));
        }

        let group_id = state_bytes[4..4+gid_len].to_vec();
        crate::debug_log!("[MLS-CONTEXT] Group ID from state: {}", hex::encode(&group_id));

        // Check if group exists (singleton keeps it in memory)
        if self.has_group(&group_id) {
            crate::debug_log!("[MLS-CONTEXT] Group already loaded in memory");
            Ok(group_id)
        } else {
            crate::debug_log!("[MLS-CONTEXT] Group not found - needs reconstruction from Welcome");
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
        crate::debug_log!("[MLS-CONTEXT] serialize_storage: Starting");

        // Serialize the raw storage
        let mut storage_buffer = Vec::new();
        self.provider.storage()
            .serialize(&mut storage_buffer)
            .map_err(|e| {
                crate::debug_log!("[MLS-CONTEXT] ERROR: Failed to serialize storage: {:?}", e);
                MLSError::invalid_input(format!("Serialization failed: {}", e))
            })?;

        crate::debug_log!("[MLS-CONTEXT] Serialized storage: {} bytes", storage_buffer.len());

        // Collect group metadata
        let group_metadata: Vec<GroupMetadata> = self.groups.iter()
            .map(|(group_id, state)| GroupMetadata {
                group_id: group_id.clone(),
                signer_public_key: state.signer_public_key.clone(),
            })
            .collect();

        crate::debug_log!("[MLS-CONTEXT] Collected metadata for {} groups", group_metadata.len());

        // Convert signers_by_identity to hex-encoded strings for JSON serialization
        crate::debug_log!("[MLS-CONTEXT] Converting {} signers_by_identity entries to hex...", self.signers_by_identity.len());
        let signers_by_identity_hex: Vec<(String, String)> = self.signers_by_identity.iter()
            .enumerate()
            .map(|(i, (k, v))| {
                let k_hex = hex::encode(k);
                let v_hex = hex::encode(v);
                crate::debug_log!("[MLS-CONTEXT]   Entry {}: key={} ({} bytes), value={} ({} bytes)", 
                    i, k_hex, k.len(), v_hex, v.len());
                (k_hex, v_hex)
            })
            .collect();
        crate::debug_log!("[MLS-CONTEXT] Hex conversion complete: {} entries", signers_by_identity_hex.len());

        // CRITICAL: Serialize key package bundles (needed to decrypt Welcome messages)
        // These bundles MUST be in provider storage before we serialize the storage
        // The bundle references in our cache point to bundles in the provider
        crate::debug_log!("[MLS-CONTEXT] Ensuring {} key package bundles are in provider storage...", self.key_package_bundles.len());

        if self.key_package_bundles.is_empty() {
            crate::debug_log!("[MLS-CONTEXT] ⚠️ WARNING: No key package bundles in cache to serialize!");
            crate::debug_log!("[MLS-CONTEXT]   This will prevent processing Welcome messages on next app launch");
            crate::debug_log!("[MLS-CONTEXT]   Key packages must be re-uploaded after deserialization");
        }

        let mut serialized_bundles = Vec::new();

        for (i, (hash_ref, bundle)) in self.key_package_bundles.iter().enumerate() {
            crate::debug_log!("[MLS-CONTEXT]   Bundle {}: hash_ref={}", i, hex::encode(hash_ref));

            // CRITICAL FIX: Ensure bundle is stored in provider storage before serialization
            // The provider storage serialization will include all stored bundles
            // FAIL LOUDLY if storage fails - bundles are critical for Welcome processing
            let hash_ref_value = HashReference::from_slice(hash_ref);
            match self.provider.storage().write_key_package(&hash_ref_value, bundle) {
                Ok(_) => {
                    crate::debug_log!("[MLS-CONTEXT]     ✅ Bundle stored/updated in provider storage");
                }
                Err(e) => {
                    crate::debug_log!("[MLS-CONTEXT]     ❌ FATAL: Failed to store bundle {}: {:?}", i, e);
                    crate::debug_log!("[MLS-CONTEXT]       Cannot serialize - bundle persistence is CRITICAL for Welcome processing");
                    return Err(MLSError::invalid_input(format!(
                        "Bundle storage failed for hash {}: {:?}",
                        hex::encode(hash_ref), e
                    )));
                }
            }

            serialized_bundles.push(SerializedKeyPackageBundle {
                hash_ref: hash_ref.clone(),
                bundle_bytes: Vec::new(), // Bundles are in storage_bytes via provider, not duplicated here
            });
        }
        crate::debug_log!("[MLS-CONTEXT] Recorded {} key package bundle references", serialized_bundles.len());

        // Create complete serialized state
        let serialized_state = SerializedState {
            storage_bytes: storage_buffer,
            group_metadata,
            signers_by_identity: signers_by_identity_hex,
            key_package_bundles: serialized_bundles,
        };

        // Serialize to JSON
        let json_bytes = serde_json::to_vec(&serialized_state)
            .map_err(|e| {
                crate::debug_log!("[MLS-CONTEXT] ERROR: Failed to serialize state to JSON: {:?}", e);
                MLSError::invalid_input(format!("JSON serialization failed: {}", e))
            })?;

        crate::debug_log!("[MLS-CONTEXT] serialize_storage: Complete, {} bytes total", json_bytes.len());
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
        crate::debug_log!("[MLS-CONTEXT] deserialize_storage: Starting with {} bytes", json_bytes.len());

        // Deserialize the JSON state
        let serialized_state: SerializedState = serde_json::from_slice(json_bytes)
            .map_err(|e| {
                crate::debug_log!("[MLS-CONTEXT] ERROR: Failed to deserialize JSON: {:?}", e);
                MLSError::invalid_input(format!("JSON deserialization failed: {}", e))
            })?;

        crate::debug_log!("[MLS-CONTEXT] Deserialized {} groups metadata", serialized_state.group_metadata.len());

        // Deserialize the raw storage
        use std::io::Cursor;
        let mut cursor = Cursor::new(&serialized_state.storage_bytes);

        let loaded_storage = openmls_rust_crypto::MemoryStorage::deserialize(&mut cursor)
            .map_err(|e| {
                crate::debug_log!("[MLS-CONTEXT] ERROR: Failed to deserialize storage: {:?}", e);
                MLSError::invalid_input(format!("Storage deserialization failed: {}", e))
            })?;

        // Replace the HashMap in the existing storage
        let mut current_values = self.provider.storage().values.write().unwrap();
        let loaded_values = loaded_storage.values.read().unwrap();

        current_values.clear();
        current_values.extend(loaded_values.clone());
        drop(current_values); // Release write lock

        crate::debug_log!("[MLS-CONTEXT] Restored {} storage entries", loaded_values.len());

        // Restore groups HashMap by loading each group from storage
        self.groups.clear();
        for metadata in serialized_state.group_metadata {
            let group_id_bytes = metadata.group_id;
            let group_id = GroupId::from_slice(&group_id_bytes);

            // Load the MlsGroup from storage
            match MlsGroup::load(self.provider.storage(), &group_id) {
                Ok(Some(group)) => {
                    crate::debug_log!("[MLS-CONTEXT] Loaded group: {}", hex::encode(&group_id_bytes));
                    self.groups.insert(group_id_bytes, GroupState {
                        group,
                        signer_public_key: metadata.signer_public_key,
                    });
                }
                Ok(None) => {
                    crate::debug_log!("[MLS-CONTEXT] WARNING: Group {} in metadata but not in storage", hex::encode(&group_id_bytes));
                }
                Err(e) => {
                    crate::debug_log!("[MLS-CONTEXT] ERROR: Failed to load group {}: {:?}", hex::encode(&group_id_bytes), e);
                }
            }
        }

        crate::debug_log!("[MLS-CONTEXT] Restored {} groups", self.groups.len());

        // Restore identity-to-signer mappings by decoding hex strings
        self.signers_by_identity.clear();
        for (key_hex, value_hex) in serialized_state.signers_by_identity {
            let key = hex::decode(&key_hex)
                .map_err(|e| {
                    crate::debug_log!("[MLS-CONTEXT] ERROR: Failed to decode hex key: {:?}", e);
                    MLSError::invalid_input(format!("Failed to decode identity key: {}", e))
                })?;
            let value = hex::decode(&value_hex)
                .map_err(|e| {
                    crate::debug_log!("[MLS-CONTEXT] ERROR: Failed to decode hex value: {:?}", e);
                    MLSError::invalid_input(format!("Failed to decode signer public key: {}", e))
                })?;
            self.signers_by_identity.insert(key, value);
        }
        crate::debug_log!("[MLS-CONTEXT] Restored {} identity mappings", self.signers_by_identity.len());

        // CRITICAL: Restore key package bundles from provider storage
        // After deserialization, the key package bundles are in the provider storage
        // We need to rebuild the cache HashMap by iterating through the saved hash_refs
        self.key_package_bundles.clear();
        crate::debug_log!("[MLS-CONTEXT] Rebuilding key package bundle cache from {} stored references...",
            serialized_state.key_package_bundles.len());

        if serialized_state.key_package_bundles.is_empty() {
            crate::debug_log!("[MLS-CONTEXT] ⚠️ No key package bundle references to restore");
            crate::debug_log!("[MLS-CONTEXT]   This is normal for new users or after key package expiration");
            crate::debug_log!("[MLS-CONTEXT]   New key packages will be created during initialization");
        }

        let mut _restored_count = 0;
        let mut missing_count = 0;

        for (i, serialized_bundle) in serialized_state.key_package_bundles.iter().enumerate() {
            // The hash_ref bytes are the raw bytes returned by hash_ref.as_slice()
            // Reconstruct the HashReference from the raw bytes
            let hash_ref_value = HashReference::from_slice(&serialized_bundle.hash_ref);

            // Query the storage for the key package bundle using the hash reference
            // The storage layer handles the KEY_PACKAGE_LABEL prefixing and serialization
            // Bundles were stored in provider storage during serialization (via bundle.store())
            match self.provider.storage().key_package::<HashReference, KeyPackageBundle>(&hash_ref_value) {
                Ok(Some(bundle)) => {
                    self.key_package_bundles.insert(serialized_bundle.hash_ref.clone(), bundle);
                    crate::debug_log!("[MLS-CONTEXT]   ✅ Restored bundle {}: hash_ref={}",
                        i, hex::encode(&serialized_bundle.hash_ref));
                    _restored_count += 1;
                }
                Ok(None) => {
                    crate::debug_log!("[MLS-CONTEXT]   ❌ Bundle {} NOT FOUND in storage (hash_ref={})",
                        i, hex::encode(&serialized_bundle.hash_ref));
                    crate::debug_log!("[MLS-CONTEXT]      This indicates the key package bundle was not properly stored before serialization");
                    crate::debug_log!("[MLS-CONTEXT]      Possible causes:");
                    crate::debug_log!("[MLS-CONTEXT]        1. Bundle.store() failed during serialization");
                    crate::debug_log!("[MLS-CONTEXT]        2. Storage corruption occurred");
                    crate::debug_log!("[MLS-CONTEXT]        3. Bundle was removed from storage before deserialization");
                    missing_count += 1;
                }
                Err(e) => {
                    crate::debug_log!("[MLS-CONTEXT]   ❌ ERROR: Failed to query storage for bundle {}: {:?}", i, e);
                    missing_count += 1;
                }
            }
        }

        let restored_count = self.key_package_bundles.len();
        let expected_count = serialized_state.key_package_bundles.len();

        crate::debug_log!("[MLS-CONTEXT] 📊 Bundle restoration summary:");
        crate::debug_log!("[MLS-CONTEXT]   - Expected bundles: {}", expected_count);
        crate::debug_log!("[MLS-CONTEXT]   - Restored bundles: {}", restored_count);
        crate::debug_log!("[MLS-CONTEXT]   - Missing bundles:  {}", missing_count);

        if missing_count > 0 {
            crate::debug_log!("[MLS-CONTEXT] ⚠️ WARNING: {} key package bundles were missing from storage!", missing_count);
            crate::debug_log!("[MLS-CONTEXT]   This will cause NoMatchingKeyPackage errors for pending Welcome messages");
            crate::debug_log!("[MLS-CONTEXT]   IMMEDIATE ACTION REQUIRED: Force-create bundles in Swift layer (ensureLocalKeyPackageBundles)");
        } else if expected_count > 0 {
            crate::debug_log!("[MLS-CONTEXT] ✅ All {} key package bundles restored successfully - Welcome processing ready", restored_count);
        } else {
            crate::debug_log!("[MLS-CONTEXT] ℹ️ No bundles to restore - bundles will be created during initialization");
        }

        crate::debug_log!("[MLS-CONTEXT] deserialize_storage: Complete");
        Ok(())
    }
}
