# MLS Key Package Management

## Overview

MLS (Messaging Layer Security) requires clients to maintain a **pool of pre-generated key packages** on the server. These are single-use cryptographic credentials that enable other users to add you to encrypted group conversations.

## Why 100+ Key Packages?

### Single-Use Constraint
- Each key package can only be used **once**
- When someone adds you to a group, they consume one of your key packages
- Once used, that key package is permanently invalid

### Availability Requirements
- If you have **0 key packages** on the server, nobody can add you to new groups
- If you have **< 10 key packages**, you risk running out during concurrent invitations
- **100 key packages** provides sufficient buffer for:
  - Concurrent group invitations
  - High activity periods
  - Time between automatic replenishment cycles

## Implementation

### Automatic Management
The system automatically manages your key package inventory:

```swift
// On initialization (app launch, login)
await manager.initialize()
// ↓
// Calls refreshKeyPackagesIfNeeded()
// ↓
// Checks server stats: getKeyPackageStats()
// ↓
// If available < threshold: uploadKeyPackageBatch(count: 100)
```

### Server Statistics
The server tracks your key package inventory:

```swift
struct KeyPackageStats {
    let available: Int      // Current count on server
    let threshold: Int      // Minimum recommended (typically 20)
}
```

### Batch Upload Process
When replenishment is needed:

1. **Batch Size**: 10 packages uploaded concurrently
2. **Total Batches**: 10 batches × 10 packages = 100 packages
3. **Rate Limiting**: 100ms delay between batches
4. **Error Handling**: Individual failures logged, batch continues
5. **Monitoring**: Success/failure counts reported

```swift
// Upload 100 key packages in batches of 10
try await uploadKeyPackageBatch(count: 100)

// Logs:
// 📦 Uploading batch 1: packages 1-10
// 📦 Uploading batch 2: packages 11-20
// ...
// ✅ Batch upload complete: 100 succeeded, 0 failed
```

### Periodic Monitoring
The system checks inventory:

- **On initialization**: Upload initial pool if first-time user
- **On periodic refresh**: Check stats every 24 hours
- **On manual refresh**: Call `refreshKeyPackagesIfNeeded()` anytime

### Thresholds

```
┌─────────────────────────────────────────┐
│  Key Package Inventory States          │
├─────────────────────────────────────────┤
│  100+ packages: ✅ Healthy              │
│  20-99 packages: ⚠️  Will replenish     │
│  1-19 packages: 🚨 Actively replenishing│
│  0 packages: ❌ Cannot join new groups  │
└─────────────────────────────────────────┘
```

## Server Architecture

### Storage
- PostgreSQL table: `mls_key_packages`
- Columns:
  - `did`: User's DID (indexed)
  - `key_package`: Binary TLS-serialized KeyPackage
  - `cipher_suite`: MLS cipher suite identifier
  - `expires_at`: Expiration timestamp
  - `created_at`: Creation timestamp

### API Endpoints

#### Upload Key Package
```
POST /xrpc/blue.catbird.mls.publishKeyPackage
{
  "keyPackage": "base64-encoded-bytes",
  "cipherSuite": "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519",
  "expires": "2025-02-09T12:00:00Z",
  "idempotencyKey": "uuid-v4"
}
```

#### Get Key Packages
```
GET /xrpc/blue.catbird.mls.getKeyPackages
?dids[]=did:plc:abc123
?dids[]=did:plc:def456
?cipherSuite=MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519

Response:
{
  "keyPackages": [
    {
      "did": "did:plc:abc123",
      "keyPackage": "base64-encoded-bytes",
      "cipherSuite": "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519"
    }
  ],
  "missing": ["did:plc:xyz789"]  // Users with no available packages
}
```

#### Check Statistics
```
GET /xrpc/blue.catbird.mls.getKeyPackageStats

Response:
{
  "available": 87,      // Your current package count
  "threshold": 20,      // Server-recommended minimum
  "total": 1234,        // Total packages ever uploaded
  "consumed": 1147      // Packages consumed by others
}
```

## Client Implementation

### Key Methods

#### `publishKeyPackage(expiresAt:)`
Uploads a single key package to the server.

```swift
let keyPackage = try await manager.publishKeyPackage(
    expiresAt: Date(timeIntervalSinceNow: 30 * 24 * 60 * 60)  // 30 days
)
```

#### `uploadKeyPackageBatch(count:)`
Uploads multiple key packages in parallel batches.

```swift
// Upload 100 key packages
try await manager.uploadKeyPackageBatch(count: 100)

// Custom count
try await manager.uploadKeyPackageBatch(count: 50)
```

#### `refreshKeyPackagesIfNeeded()`
Checks server stats and replenishes if below threshold.

```swift
// Called automatically on initialize()
try await manager.refreshKeyPackagesIfNeeded()

// Can also be called manually
try await manager.refreshKeyPackagesIfNeeded()
```

### Logging

```
📊 Key package inventory: available=87, threshold=20
✅ Key packages are sufficient: 87 available

⚠️ Key package count (15) below threshold (20) - replenishing...
🔄 Uploading batch of 85 key packages...
📦 Uploading batch 1: packages 1-10
📦 Uploading batch 2: packages 11-20
...
✅ Batch upload complete: 85 succeeded, 0 failed
```

## Best Practices

### Initial Setup
```swift
// On first app launch or after login
let manager = MLSConversationManager(apiClient: client, userDid: userDid)
try await manager.initialize()
// ↓ Automatically uploads 100 key packages if needed
```

### Periodic Refresh
```swift
// Check and refresh every 24 hours
try await manager.refreshKeyPackagesBasedOnInterval()
```

### Manual Trigger
```swift
// Force immediate check and refresh
try await manager.refreshKeyPackagesIfNeeded()
```

### Monitoring
```swift
// Check your current inventory
let stats = try await apiClient.getKeyPackageStats()
print("Available: \(stats.available), Threshold: \(stats.threshold)")
```

## Troubleshooting

### No Key Packages Available
**Symptom**: Users cannot add you to groups

**Solution**:
```swift
// Force upload new packages
try await manager.uploadKeyPackageBatch(count: 100)
```

### Upload Failures
**Symptom**: Batch upload reports failures

**Check**:
1. Network connectivity
2. Server authentication (valid session)
3. Server rate limits
4. Logs for specific error messages

**Retry**:
```swift
// Retry failed uploads
try await manager.refreshKeyPackagesIfNeeded()
```

### Slow Uploads
**Symptom**: Uploading 100 packages takes too long

**Tuning**:
- Batch size is currently 10 (configurable)
- Delay between batches is 100ms (configurable)
- Total time ≈ (100 / 10 batches) × 100ms = ~1 second

## Security Considerations

### Key Package Generation
- Each key package contains a **unique ephemeral key pair**
- Private keys stored securely in MLS client context
- Public keys published to server

### Expiration
- Default: 30 days from upload
- Server automatically purges expired packages
- Client should refresh periodically to maintain pool

### Rate Limiting
- Server may enforce upload rate limits
- Current implementation: 10 packages/batch, 100ms delay
- Prevents abuse while allowing legitimate replenishment

## Future Improvements

### Smart Replenishment
- Monitor consumption rate
- Predict when threshold will be reached
- Proactive background uploads

### Adaptive Batch Sizes
- Increase batch size for high-activity users
- Decrease for low-activity users
- Balance server load vs. latency

### Push Notifications
- Server notifies client when inventory < threshold
- Triggers immediate background refresh
- Prevents running out unexpectedly

## References

- MLS RFC: https://www.rfc-editor.org/rfc/rfc9420.html
- Key Package Format: Section 5.1 of MLS RFC
- Best Practices: Section 15.3 (Key Package Pool Management)
