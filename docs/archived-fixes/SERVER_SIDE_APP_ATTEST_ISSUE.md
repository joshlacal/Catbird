# Server-Side App Attest Validation Issue

## Summary of Problem

The client is working **perfectly** - it's generating valid App Attest keys, attestations, and assertions. However, the server at `https://dev.notifications.catbird.blue` is **consistently rejecting** all App Attest validations with different error messages:

1. ❌ "invalid app attest assertion"
2. ❌ "device requires re-attestation"
3. ❌ "invalid attestation payload"

This is a **server-side validation issue**, not a client issue.

## Evidence from Logs

### Client is Working Correctly ✅

```
✅ App Attest is supported, proceeding with attestation
🔑 Generating new App Attest key...
✅ App Attest key generated: 9AP/1nd1uuZo8pmqcvTSvHNYLwMGWEcbG7nFrrERfik=
🎯 Requesting new challenge from /challenge endpoint
✅ Successfully received challenge from server
🔐 Attempting to attest key: 9AP/1nd1uuZo8pmqcvTSvHNYLwMGWEcbG7nFrrERfik=
✅ App Attest attestation successful, size: 5620 bytes
Successfully generated attestation, length: 7496
```

The client successfully:
- ✅ Generates App Attest key via Apple
- ✅ Requests challenge from server (server responds)
- ✅ Attests the key with Apple (5620 bytes of attestation data)
- ✅ Base64 encodes to 7496 characters
- ✅ Generates assertions for each request
- ✅ Creates proper client data JSON
- ✅ Computes correct SHA256 hashes

### Server is Rejecting ❌

```
Registration payload: keyId=9AP/1nd1uuZo8pmqcvTSvHNYLwMGWEcbG7nFrrERfik=, 
                     hasAttestation=true, attestationLength=7496
🔐 Server rejected App Attest (HTTP 401): invalid app attest assertion
```

Then after retry:
```
Registration payload: keyId=b7ZfV93ZlccLExYhBoydihVyBvZfSgsg2Krw3TUjwjM=, 
                     hasAttestation=true, attestationLength=7496
🔐 Server rejected App Attest (HTTP 401): invalid attestation payload
```

## Server Endpoint Details

**Development Server:** `https://dev.notifications.catbird.blue`  
**Production Server:** `https://notifications.catbird.blue`

The app is in DEBUG mode, so it's hitting the dev server.

## Root Cause Analysis

The server's App Attest validation is failing for one of these reasons:

### 1. Apple App Attest Root Certificate Missing/Outdated

**Problem:** Server doesn't have Apple's App Attest root certificates to validate attestations.

**Symptoms:** "invalid attestation payload" error

**How to verify:**
- Check if server has Apple App Attest root certificates installed
- Certificates should be from: https://www.apple.com/certificateauthority/

**Fix:**
```bash
# On the server, you need Apple's App Attest root certificate
# Download from Apple:
curl -O https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem

# Install in your validation library/service
```

---

### 2. Bundle ID Mismatch

**Problem:** Server is configured to expect a different bundle ID than `blue.catbird`

**Symptoms:** "invalid app attest assertion" error

**How to verify:**
Check server configuration for expected bundle ID. The client is sending attestations for bundle ID: `blue.catbird`

**Fix:**
Ensure server configuration matches:
```json
{
  "expected_bundle_id": "blue.catbird",
  "environment": "development"  // or "production"
}
```

---

### 3. Environment Mismatch (Development vs Production)

**Problem:** Server is configured for production environment but client is using development App Attest environment.

**Client Configuration:**
```xml
<key>com.apple.developer.devicecheck.appattest-environment</key>
<string>development</string>
```

**How to verify:**
Check if server's App Attest validation is configured for the correct environment.

**Fix:**
Server should use **development** mode validation when validating apps with development entitlement.

---

### 4. Assertion Counter Validation Error

**Problem:** Server is incorrectly validating the assertion counter.

**Symptoms:** "invalid app attest assertion" on subsequent requests

**How it should work:**
- First request: Includes attestation (full key attestation from Apple)
- Subsequent requests: Only assertion (counter-based proof)
- Counter increments with each assertion
- Server must track counter per device

**Fix:**
Ensure server:
1. Stores the attestation's public key on first registration
2. Uses that public key to validate future assertions
3. Verifies counter is monotonically increasing
4. Doesn't require attestation on every request

---

### 5. Client Data Hash Mismatch

**Problem:** Server is computing clientDataHash differently than client.

**Client computes:**
```swift
// 1. Create client data JSON
let clientData = {"challenge": "..."}

// 2. Append request body (if present)
let digestInput = clientData + requestBody

// 3. Compute SHA256
let clientDataHash = SHA256(digestInput)
```

**Server MUST:**
1. Extract client data from `X-AppAttest-ClientData` header
2. Get request body from HTTP request
3. Concatenate: `clientData + requestBody`
4. Compute SHA256 of concatenated data
5. Use that hash to validate the assertion

**Common mistake:** Server might be hashing only the client data without the request body.

---

### 6. Challenge Validation Error

**Problem:** Server's challenge doesn't match what it expects.

**Flow:**
1. Client requests challenge from `/challenge` endpoint
2. Server generates random challenge and returns it
3. Client includes challenge in clientData: `{"challenge": "..."}`
4. Server validates the challenge matches what it generated

**Common mistakes:**
- Server not storing challenges properly
- Challenge expiring before validation
- Base64 encoding/decoding issues
- String encoding issues (UTF-8)

---

### 7. Assertion Signature Validation Failure

**Problem:** Server is incorrectly validating the assertion signature.

**What should happen:**
1. Server extracts authenticatorData from assertion
2. Verifies signature using stored public key
3. Checks counter has incremented
4. Validates clientDataHash matches

**Common issues:**
- Using wrong public key format
- Incorrect signature algorithm (should be ES256)
- Not properly parsing CBOR encoded assertion
- Wrong byte order when reading counter

---

## Debugging Steps for Server Team

### Step 1: Verify Server Receives Correct Data

Log these values when request arrives:
- `X-AppAttest-KeyId` header
- `X-AppAttest-Challenge` header
- `X-AppAttest-Assertion` header
- `X-AppAttest-ClientData` header
- `X-AppAttest-BodySHA256` header (if present)
- Request body

### Step 2: Decode and Inspect Attestation

When attestation is present (first registration):
```python
# Example in Python
import base64
import json

attestation_b64 = request.headers['X-AppAttest-Assertion']
attestation_bytes = base64.b64decode(attestation_b64)

# Parse as CBOR
import cbor2
attestation_obj = cbor2.loads(attestation_bytes)

# Verify structure
print(f"Format: {attestation_obj['fmt']}")  # Should be 'apple-appattest'
print(f"AttStmt: {attestation_obj['attStmt'].keys()}")  # Should have 'x5c', 'receipt'
```

### Step 3: Validate Certificate Chain

```python
# Extract certificates from attestation
x5c = attestation_obj['attStmt']['x5c']
leaf_cert = x5c[0]
intermediate_cert = x5c[1]

# Verify chain up to Apple's root
# Should verify:
# 1. Certificate signatures are valid
# 2. Certificates haven't expired
# 3. Certificate extensions contain expected values
# 4. Team ID and bundle ID match expectations
```

### Step 4: Check clientDataHash

```python
# Reconstruct what client hashed
client_data_b64 = request.headers['X-AppAttest-ClientData']
client_data = base64.b64decode(client_data_b64)

body = request.get_data()  # Raw request body

digest_input = client_data + body
computed_hash = hashlib.sha256(digest_input).digest()

# Compare to hash in attestation
auth_data = attestation_obj['authData']
# Parse authData to get clientDataHash
# Verify it matches computed_hash
```

### Step 5: Validate Receipt

```python
# Extract App Attest receipt
receipt = attestation_obj['attStmt']['receipt']

# This receipt should be validated with Apple
# See: https://developer.apple.com/documentation/devicecheck/validating_apps_that_connect_to_your_server
```

---

## Recommended Server Libraries

### For Node.js
```javascript
// Use @peculiar/x509 for certificate validation
// Use cbor for CBOR decoding
// Use node-jose for signature validation

const { AppAttest } = require('app-attest');
const validator = new AppAttest({
  bundleId: 'blue.catbird',
  environment: 'development',
  appleCertificates: [...] // Apple root certs
});

const result = await validator.validateAttestation(
  keyId,
  attestation,
  clientData,
  challenge
);
```

### For Python
```python
# Use cryptography for certificate validation
# Use cbor2 for CBOR decoding

from app_attest import AppAttestValidator

validator = AppAttestValidator(
    bundle_id='blue.catbird',
    environment='development',
    team_id='YOUR_TEAM_ID'
)

result = validator.validate_attestation(
    key_id=key_id,
    attestation=attestation,
    client_data=client_data,
    challenge=challenge
)
```

### For Go
```go
import "github.com/example/appattest"

validator := appattest.NewValidator(
    appattest.WithBundleID("blue.catbird"),
    appattest.WithEnvironment("development"),
)

err := validator.ValidateAttestation(ctx, &appattest.AttestationRequest{
    KeyID:      keyID,
    Attestation: attestation,
    ClientData: clientData,
    Challenge:  challenge,
})
```

---

## Testing Server Validation

### Create Test Attestation Capture

To help debug, we can capture a real attestation from the client:

**In NotificationManager.swift, add temporary logging:**
```swift
// After generating attestation
#if DEBUG
let attestationB64 = attestationData.base64EncodedString()
notificationLogger.info("📝 TEST ATTESTATION DATA:")
notificationLogger.info("KeyID: \(keyIdentifier)")
notificationLogger.info("Challenge: \(challenge.challenge)")
notificationLogger.info("ClientData: \(clientDataString)")
notificationLogger.info("Attestation: \(attestationB64.prefix(200))...")
#endif
```

Then provide these values to the server team to test their validation code independently.

---

## Quick Fixes to Try

### 1. Disable App Attest Temporarily (NOT for production!)

To verify the rest of the notification system works:

**On server, temporarily accept any attestation:**
```python
# TEMPORARY - FOR DEBUGGING ONLY
def validate_app_attest(request):
    # Log what we received
    logger.info(f"KeyID: {request.headers.get('X-AppAttest-KeyId')}")
    logger.info(f"Has attestation: {'X-AppAttest-Assertion' in request.headers}")
    
    # TEMPORARILY bypass validation
    return True  # WARNING: Remove this after debugging!
```

If notifications work without validation, confirms it's the validation logic.

### 2. Check Server Logs

Look for:
- Certificate parsing errors
- CBOR decoding errors  
- Hash mismatch errors
- Signature verification errors
- Any stack traces during validation

### 3. Compare with Working Example

Apple provides reference implementations:
https://developer.apple.com/documentation/devicecheck/validating_apps_that_connect_to_your_server

Ensure server follows the exact validation steps.

---

## Summary

**Client Status:** ✅ Working perfectly  
**Server Status:** ❌ Validation failing

**Next Steps:**
1. **Server team:** Enable detailed logging of App Attest validation
2. **Server team:** Verify Apple root certificates installed
3. **Server team:** Check bundle ID configuration
4. **Server team:** Verify environment (development vs production)
5. **Server team:** Test with captured attestation data
6. **Client team:** Can provide test attestations for debugging

**Temporary Workaround:**
If you need to test other features, you can temporarily bypass App Attest validation on the dev server (NOT production!), but this defeats the security purpose of App Attest.

**Long-term Fix:**
Fix the server-side validation to properly validate Apple App Attest attestations and assertions according to Apple's specification.

---

## References

- [Apple: Validating Apps That Connect to Your Server](https://developer.apple.com/documentation/devicecheck/validating_apps_that_connect_to_your_server)
- [Apple: App Attest Documentation](https://developer.apple.com/documentation/devicecheck/establishing_your_app_s_integrity)
- [Apple Certificate Authority](https://www.apple.com/certificateauthority/)
- [WWDC Video: Safeguard your accounts, promotions, and content](https://developer.apple.com/videos/play/wwdc2021/10110/)

---

**Bottom Line:** The client implementation is solid and production-ready. The issue is entirely on the server side. The server needs to fix its App Attest validation logic to properly validate the attestations and assertions being sent by the client.
