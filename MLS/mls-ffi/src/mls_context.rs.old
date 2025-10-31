use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use openmls::prelude::MlsGroup;
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;

use crate::error::{MLSError, Result};

pub struct MLSContext {
    provider: OpenMlsRustCrypto,
    groups: Mutex<HashMap<Vec<u8>, MlsGroup>>,                        // group_id -> group state
    signers_by_group: Mutex<HashMap<Vec<u8>, Arc<SignatureKeyPair>>>, // group_id -> signer
    signers_by_identity: Mutex<HashMap<Vec<u8>, Arc<SignatureKeyPair>>>, // identity -> signer
    signers_by_key_package_ref: Mutex<HashMap<Vec<u8>, Arc<SignatureKeyPair>>>, // key_package_ref -> signer
}

impl MLSContext {
    pub fn new() -> Self {
        Self {
            provider: OpenMlsRustCrypto::default(),
            groups: Mutex::new(HashMap::new()),
            signers_by_group: Mutex::new(HashMap::new()),
            signers_by_identity: Mutex::new(HashMap::new()),
            signers_by_key_package_ref: Mutex::new(HashMap::new()),
        }
    }

    pub fn provider(&self) -> &OpenMlsRustCrypto {
        &self.provider
    }

    pub fn add_group(&self, group_id: Vec<u8>, group: MlsGroup, signer: Arc<SignatureKeyPair>) -> Result<()> {
        let mut groups = self.groups.lock()
            .map_err(|e| MLSError::ThreadSafety(e.to_string()))?;
        let mut signers = self.signers_by_group.lock()
            .map_err(|e| MLSError::ThreadSafety(e.to_string()))?;
        groups.insert(group_id.clone(), group);
        signers.insert(group_id, signer);
        Ok(())
    }

    pub fn set_identity_signer(&self, identity: Vec<u8>, signer: Arc<SignatureKeyPair>) -> Result<()> {
        let mut map = self.signers_by_identity.lock()
            .map_err(|e| MLSError::ThreadSafety(e.to_string()))?;
        map.insert(identity, signer);
        Ok(())
    }

    pub fn signer_for_group(&self, group_id: &[u8]) -> Result<Arc<SignatureKeyPair>> {
        let map = self.signers_by_group.lock()
            .map_err(|e| MLSError::ThreadSafety(e.to_string()))?;
        map.get(group_id)
            .cloned()
            .ok_or_else(|| MLSError::GroupNotFound(hex::encode(group_id)))
    }

    pub fn signer_for_identity(&self, identity: &[u8]) -> Result<Arc<SignatureKeyPair>> {
        let map = self.signers_by_identity.lock()
            .map_err(|e| MLSError::ThreadSafety(e.to_string()))?;
        map.get(identity)
            .cloned()
            .ok_or_else(|| MLSError::GroupNotFound(format!("identity:{}", hex::encode(identity))))
    }

    pub fn set_key_package_signer(&self, key_package_ref: Vec<u8>, signer: Arc<SignatureKeyPair>) -> Result<()> {
        let mut map = self.signers_by_key_package_ref.lock()
            .map_err(|e| MLSError::ThreadSafety(e.to_string()))?;
        map.insert(key_package_ref, signer);
        Ok(())
    }

    #[allow(dead_code)]
    pub fn signer_for_key_package(&self, key_package_ref: &[u8]) -> Result<Arc<SignatureKeyPair>> {
        let map = self.signers_by_key_package_ref.lock()
            .map_err(|e| MLSError::ThreadSafety(e.to_string()))?;
        map.get(key_package_ref)
            .cloned()
            .ok_or_else(|| MLSError::GroupNotFound(format!("key_package_ref:{}", hex::encode(key_package_ref))))
    }

    pub fn with_group<T, F: FnOnce(&mut MlsGroup) -> Result<T>>(&self, group_id: &[u8], f: F) -> Result<T> {
        let mut groups = self.groups.lock()
            .map_err(|e| MLSError::ThreadSafety(e.to_string()))?;
        let group = groups.get_mut(group_id)
            .ok_or_else(|| MLSError::GroupNotFound(hex::encode(group_id)))?;
        f(group)
    }

    #[allow(dead_code)]
    pub fn remove_group(&self, group_id: &[u8]) -> Result<()> {
        let mut groups = self.groups.lock()
            .map_err(|e| MLSError::ThreadSafety(e.to_string()))?;
        groups.remove(group_id);
        let mut signers = self.signers_by_group.lock()
            .map_err(|e| MLSError::ThreadSafety(e.to_string()))?;
        signers.remove(group_id);
        Ok(())
    }

    /// Validate that the group's current epoch matches the expected epoch.
    /// This prevents replay attacks and ensures epoch synchronization.
    #[allow(dead_code)]
    pub fn validate_epoch(&self, group_id: &[u8], expected_epoch: u64) -> Result<()> {
        let groups = self.groups.lock()
            .map_err(|e| MLSError::ThreadSafety(e.to_string()))?;
        let group = groups.get(group_id)
            .ok_or_else(|| MLSError::GroupNotFound(hex::encode(group_id)))?;
        
        let actual_epoch = group.epoch().as_u64();
        if actual_epoch != expected_epoch {
            return Err(MLSError::EpochMismatch {
                expected: expected_epoch,
                actual: actual_epoch,
            });
        }
        Ok(())
    }

    /// Get the current epoch for a group.
    #[allow(dead_code)]
    pub fn get_epoch(&self, group_id: &[u8]) -> Result<u64> {
        let groups = self.groups.lock()
            .map_err(|e| MLSError::ThreadSafety(e.to_string()))?;
        let group = groups.get(group_id)
            .ok_or_else(|| MLSError::GroupNotFound(hex::encode(group_id)))?;
        Ok(group.epoch().as_u64())
    }
}

impl Drop for MLSContext {
    fn drop(&mut self) {
        // Note: SignatureKeyPair doesn't implement Zeroize in openmls 0.5
        // This is a limitation of the current OpenMLS version.
        // Future: When OpenMLS adds zeroize support, uncomment below:
        
        // Clear all key material from memory
        // if let Ok(mut signers) = self.signers_by_group.lock() {
        //     for (_, signer) in signers.drain() {
        //         // Zeroize signature keys
        //         drop(signer);
        //     }
        // }
        // if let Ok(mut signers) = self.signers_by_identity.lock() {
        //     for (_, signer) in signers.drain() {
        //         drop(signer);
        //     }
        // }
        // if let Ok(mut signers) = self.signers_by_key_package_ref.lock() {
        //     for (_, signer) in signers.drain() {
        //         drop(signer);
        //     }
        // }
    }
}

impl Default for MLSContext {
    fn default() -> Self {
        Self::new()
    }
}
