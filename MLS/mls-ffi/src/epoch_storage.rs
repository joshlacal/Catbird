// epoch_storage.rs
//
// Epoch secret storage and retrieval for forward secrecy with message history
//
// This module provides the bridge between Rust OpenMLS and Swift encrypted storage
// for retaining epoch secrets beyond OpenMLS's in-memory retention policy.

use std::sync::{Arc, RwLock};
use openmls::prelude::*;
use crate::error::MLSError;
use crate::types::EpochSecretStorage;

/// Epoch secret manager coordinating storage operations
pub struct EpochSecretManager {
    storage: Arc<RwLock<Option<Arc<dyn EpochSecretStorage>>>>,
}

impl EpochSecretManager {
    pub fn new() -> Self {
        Self {
            storage: Arc::new(RwLock::new(None)),
        }
    }

    /// Set the storage backend
    pub fn set_storage(&self, storage: Arc<dyn EpochSecretStorage>) {
        let mut lock = self.storage.write().unwrap();
        *lock = Some(storage);
    }

    /// Export epoch secret for a group before epoch advance
    ///
    /// This should be called BEFORE processing a commit that advances the epoch.
    /// The exported secret allows decrypting messages from the current epoch
    /// even after the group has advanced to a new epoch.
    pub fn export_current_epoch_secret(
        &self,
        group: &MlsGroup,
        provider: &impl OpenMlsProvider,
    ) -> Result<Vec<u8>, MLSError> {
        let group_id_hex = hex::encode(group.group_id().as_slice());
        let current_epoch = group.epoch().as_u64();

        crate::debug_log!("[EPOCH-STORAGE] Exporting epoch secret for group {} epoch {}",
            group_id_hex, current_epoch);

        // Export the epoch secret using OpenMLS export_secret API
        // This derives a secret from the current epoch's key schedule
        let label = format!("epoch_secret_{}", current_epoch);
        let context = group_id_hex.as_bytes();

        let secret = group
            .export_secret(provider, &label, context, 32) // 32 bytes = 256 bits
            .map_err(|e| {
                crate::error_log!("[EPOCH-STORAGE] ERROR: Failed to export epoch secret: {:?}", e);
                MLSError::SecretExportFailed
            })?;

        crate::debug_log!("[EPOCH-STORAGE] Exported {} bytes for epoch {}", secret.len(), current_epoch);

        // Store in Swift encrypted storage
        if let Ok(guard) = self.storage.read() {
            if let Some(storage) = guard.as_ref() {
                if storage.store_epoch_secret(
                    group_id_hex.clone(),
                    current_epoch,
                    secret.to_vec(),
                ) {
                    crate::info_log!("[EPOCH-STORAGE] ✅ Stored epoch secret: group={}, epoch={}",
                        group_id_hex, current_epoch);
                } else {
                    crate::warn_log!("[EPOCH-STORAGE] ⚠️ Failed to store epoch secret");
                    return Err(MLSError::StorageFailed);
                }
            }
        }

        Ok(secret.to_vec())
    }

    /// Retrieve stored epoch secret
    pub fn get_epoch_secret(
        &self,
        group_id: &[u8],
        epoch: u64,
    ) -> Option<Vec<u8>> {
        let group_id_hex = hex::encode(group_id);

        if let Ok(guard) = self.storage.read() {
            if let Some(storage) = guard.as_ref() {
                return storage.get_epoch_secret(group_id_hex, epoch);
            }
        }

        None
    }

    /// Delete epoch secret (for retention policy cleanup)
    pub fn delete_epoch_secret(
        &self,
        group_id: &[u8],
        epoch: u64,
    ) -> bool {
        let group_id_hex = hex::encode(group_id);

        if let Ok(guard) = self.storage.read() {
            if let Some(storage) = guard.as_ref() {
                return storage.delete_epoch_secret(group_id_hex, epoch);
            }
        }

        false
    }
}

impl Default for EpochSecretManager {
    fn default() -> Self {
        Self::new()
    }
}
