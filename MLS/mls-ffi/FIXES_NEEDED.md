# OpenMLS 0.6 API Compatibility Fixes Needed

## Compilation Errors to Fix:

### 1. ProposalRef Import (line 585)
**Error**: `could not find ProposalRef in prelude`
**Fix**: Import from `openmls::prelude::hash_ref::ProposalRef` or use storage traits

### 2. WireFormatPolicy Ambiguity (line 373, 375)
**Error**: Ambiguous between `openmls::prelude::WireFormatPolicy` and `crate::types::WireFormatPolicy`
**Fix**: Rename our custom enum to `WireFormat` or `WireFormatPolicyType`

### 3. Credential.identity() Missing (lines 232, 258)
**Error**: `no method named identity found for &Credential`
**Fix**: Use `credential.serialized_content()` or appropriate OpenMLS 0.6 method

### 4. CredentialData.clone() Missing (line 266)
**Error**: `method clone not found`
**Fix**: Derive Clone for CredentialData in types.rs

### 5. StagedCommit.epoch() Missing (line 287)
**Error**: `no method named epoch found for Box<StagedCommit>`
**Fix**: Access epoch differently in OpenMLS 0.6

### 6. KeyPackageResult Missing hash_ref (line 338)
**Error**: `missing field hash_ref in initializer`
**Fix**: Add hash_ref computation

### 7. Type Conversion u32 -> usize (line 366)
**Error**: `expected usize, found u32`
**Fix**: Use `.try_into().unwrap()` or `as usize`

### 8. WireFormatPolicy Constructor (line 373+)
**Error**: `no function named new_ciphertext`
**Fix**: Use correct OpenMLS 0.6 WireFormatPolicy constants
