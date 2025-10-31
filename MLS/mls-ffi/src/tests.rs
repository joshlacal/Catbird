#[cfg(test)]
mod ffi_tests {
    use super::super::*;

    #[test]
    fn test_mls_init() {
        let context_id = mls_init();
        assert_ne!(context_id, 0, "Context ID should not be zero");
        mls_free_context(context_id);
    }

    #[test]
    fn test_create_group() {
        let context_id = mls_init();
        assert_ne!(context_id, 0);

        let identity = b"alice@example.com";
        let result = mls_create_group(
            context_id,
            identity.as_ptr(),
            identity.len(),
        );

        assert!(result.success, "Group creation should succeed");
        assert!(!result.data.is_null());
        assert!(result.data_len > 0);

        mls_free_result(result);
        mls_free_context(context_id);
    }

    #[test]
    fn test_create_key_package() {
        let context_id = mls_init();
        assert_ne!(context_id, 0);

        let identity = b"bob@example.com";
        let result = mls_create_key_package(
            context_id,
            identity.as_ptr(),
            identity.len(),
        );

        assert!(result.success, "Key package creation should succeed");
        assert!(!result.data.is_null());
        assert!(result.data_len > 0);

        mls_free_result(result);
        mls_free_context(context_id);
    }

    #[test]
    fn test_get_epoch() {
        let context_id = mls_init();
        assert_ne!(context_id, 0);

        let identity = b"alice@example.com";
        let create_result = mls_create_group(
            context_id,
            identity.as_ptr(),
            identity.len(),
        );

        assert!(create_result.success);
        
        let group_id = unsafe {
            std::slice::from_raw_parts(create_result.data, create_result.data_len)
        };

        let epoch = mls_get_epoch(
            context_id,
            group_id.as_ptr(),
            group_id.len(),
        );

        assert_eq!(epoch, 0, "Initial epoch should be 0");

        mls_free_result(create_result);
        mls_free_context(context_id);
    }

    #[test]
    fn test_export_secret() {
        let context_id = mls_init();
        assert_ne!(context_id, 0);

        let identity = b"alice@example.com";
        let create_result = mls_create_group(
            context_id,
            identity.as_ptr(),
            identity.len(),
        );

        assert!(create_result.success);
        
        let group_id = unsafe {
            std::slice::from_raw_parts(create_result.data, create_result.data_len)
        };

        let label = std::ffi::CString::new("test-export").unwrap();
        let context_data = b"test-context";
        let key_length = 32;

        let export_result = mls_export_secret(
            context_id,
            group_id.as_ptr(),
            group_id.len(),
            label.as_ptr(),
            context_data.as_ptr(),
            context_data.len(),
            key_length,
        );

        assert!(export_result.success, "Secret export should succeed");
        assert_eq!(export_result.data_len, key_length, "Exported secret should have requested length");

        mls_free_result(create_result);
        mls_free_result(export_result);
        mls_free_context(context_id);
    }

    #[test]
    fn test_null_pointer_handling() {
        let context_id = mls_init();
        assert_ne!(context_id, 0);

        let result = mls_create_group(
            context_id,
            std::ptr::null(),
            0,
        );

        assert!(!result.success, "Should fail with null pointer");
        assert!(!result.error_message.is_null(), "Should have error message");

        mls_free_result(result);
        mls_free_context(context_id);
    }

    #[test]
    fn test_invalid_context() {
        let invalid_context_id = 999999;
        let identity = b"test@example.com";
        
        let result = mls_create_group(
            invalid_context_id,
            identity.as_ptr(),
            identity.len(),
        );

        assert!(!result.success, "Should fail with invalid context");
        mls_free_result(result);
    }

    #[test]
    fn test_multiple_contexts() {
        let context1 = mls_init();
        let context2 = mls_init();
        
        assert_ne!(context1, 0);
        assert_ne!(context2, 0);
        assert_ne!(context1, context2, "Context IDs should be unique");

        mls_free_context(context1);
        mls_free_context(context2);
    }

    #[test]
    fn test_process_commit_invalid_context() {
        let invalid_context = 999999;
        let group_id = b"test-group-id";
        let commit_data = b"fake-commit-data";
        
        let result = mls_process_commit(
            invalid_context,
            group_id.as_ptr(),
            group_id.len(),
            commit_data.as_ptr(),
            commit_data.len(),
        );
        
        assert!(!result.success, "Should fail with invalid context");
        assert!(!result.error_message.is_null(), "Should have error message");
        
        mls_free_result(result);
    }

    #[test]
    fn test_process_commit_null_group_id() {
        let context_id = mls_init();
        assert_ne!(context_id, 0);
        
        let commit_data = b"fake-commit-data";
        
        let result = mls_process_commit(
            context_id,
            std::ptr::null(),
            0,
            commit_data.as_ptr(),
            commit_data.len(),
        );
        
        assert!(!result.success, "Should fail with null group_id");
        assert!(!result.error_message.is_null(), "Should have error message");
        
        mls_free_result(result);
        mls_free_context(context_id);
    }

    #[test]
    fn test_process_commit_null_commit_data() {
        let context_id = mls_init();
        assert_ne!(context_id, 0);
        
        let identity = b"alice@example.com";
        let create_result = mls_create_group(
            context_id,
            identity.as_ptr(),
            identity.len(),
        );
        
        assert!(create_result.success);
        
        let group_id = unsafe {
            std::slice::from_raw_parts(create_result.data, create_result.data_len)
        };
        
        let result = mls_process_commit(
            context_id,
            group_id.as_ptr(),
            group_id.len(),
            std::ptr::null(),
            0,
        );
        
        assert!(!result.success, "Should fail with null commit data");
        assert!(!result.error_message.is_null(), "Should have error message");
        
        mls_free_result(create_result);
        mls_free_result(result);
        mls_free_context(context_id);
    }

    #[test]
    fn test_process_commit_invalid_tls_data() {
        let context_id = mls_init();
        assert_ne!(context_id, 0);
        
        let identity = b"alice@example.com";
        let create_result = mls_create_group(
            context_id,
            identity.as_ptr(),
            identity.len(),
        );
        
        assert!(create_result.success);
        
        let group_id = unsafe {
            std::slice::from_raw_parts(create_result.data, create_result.data_len)
        };
        
        // Invalid TLS data that will fail deserialization
        let invalid_commit = b"this-is-not-valid-tls-encoded-data";
        
        let result = mls_process_commit(
            context_id,
            group_id.as_ptr(),
            group_id.len(),
            invalid_commit.as_ptr(),
            invalid_commit.len(),
        );
        
        assert!(!result.success, "Should fail with invalid TLS data");
        assert!(!result.error_message.is_null(), "Should have error message");
        
        // Verify error message mentions TLS or deserialization
        let error_msg = unsafe {
            std::ffi::CStr::from_ptr(result.error_message)
                .to_string_lossy()
                .into_owned()
        };
        assert!(
            error_msg.to_lowercase().contains("deserialize") || 
            error_msg.to_lowercase().contains("tls"),
            "Error message should mention deserialization: {}", 
            error_msg
        );
        
        mls_free_result(create_result);
        mls_free_result(result);
        mls_free_context(context_id);
    }

    #[test]
    fn test_epoch_increments_after_add_member() {
        let context_id = mls_init();
        assert_ne!(context_id, 0);
        
        // Create group as Alice
        let alice_identity = b"alice@example.com";
        let create_result = mls_create_group(
            context_id,
            alice_identity.as_ptr(),
            alice_identity.len(),
        );
        
        assert!(create_result.success);
        
        let group_id = unsafe {
            std::slice::from_raw_parts(create_result.data, create_result.data_len)
        };
        
        // Check initial epoch
        let initial_epoch = mls_get_epoch(
            context_id,
            group_id.as_ptr(),
            group_id.len(),
        );
        assert_eq!(initial_epoch, 0, "Initial epoch should be 0");
        
        // Create key package for Bob
        let bob_identity = b"bob@example.com";
        let key_package_result = mls_create_key_package(
            context_id,
            bob_identity.as_ptr(),
            bob_identity.len(),
        );
        
        assert!(key_package_result.success);
        
        let key_package = unsafe {
            std::slice::from_raw_parts(key_package_result.data, key_package_result.data_len)
        };
        
        // Add Bob to the group
        let add_result = mls_add_member(
            context_id,
            group_id.as_ptr(),
            group_id.len(),
            key_package.as_ptr(),
            key_package.len(),
        );
        
        assert!(add_result.success, "Adding member should succeed");
        
        // Check epoch after adding member
        let new_epoch = mls_get_epoch(
            context_id,
            group_id.as_ptr(),
            group_id.len(),
        );
        
        assert_eq!(new_epoch, 1, "Epoch should increment to 1 after adding member");
        
        mls_free_result(create_result);
        mls_free_result(key_package_result);
        mls_free_result(add_result);
        mls_free_context(context_id);
    }

    #[test]
    fn test_get_epoch_invalid_group() {
        let context_id = mls_init();
        assert_ne!(context_id, 0);
        
        let fake_group_id = b"nonexistent-group-id";
        
        let epoch = mls_get_epoch(
            context_id,
            fake_group_id.as_ptr(),
            fake_group_id.len(),
        );
        
        // Should return 0 for invalid group (as per function implementation)
        assert_eq!(epoch, 0, "Should return 0 for invalid group");
        
        mls_free_context(context_id);
    }
}
