# MLS Message Padding and Serialization Fix

## Problem

MLS message decryption was failing with error: `UnknownValue(170)` during deserialization.

### Root Cause

The server pads MLS messages to fixed bucket sizes (512, 1024, 2048, 4096, 8192 bytes) for traffic analysis resistance and prepends a 4-byte big-endian length prefix:

```
Format: [4-byte BE length][actual MLS message][zero padding...]
Example: [00 00 00 aa][170 bytes of MLS data][342 bytes of zeros] = 512 total
```

**The issue:** OpenMLS's `tls_deserialize_bytes()` expects raw MLS messages starting with the wire format discriminant (`0x01`-`0x04`), but was receiving:
- Position 0-3: Length prefix `00 00 00 aa` (170 in big-endian)
- Position 4+: Actual MLS message

OpenMLS tried to interpret byte 3 (`0xaa` = 170) as the wire format type, which is invalid.

## Solution

### Client-Side Implementation

#### 1. **Sending Messages** (`MLSMessagePadding.swift`)
Created padding helper to wrap messages before sending:

```swift
enum MLSMessagePadding {
    static func padCiphertextToBucket(_ ciphertext: Data) -> (Data, Int) {
        // Format: [4-byte BE length][ciphertext][zero padding]
        // Bucket sizes: 512, 1024, 2048, 4096, 8192, or multiples of 8192
    }
}
```

Usage in `MLSConversationManager.sendMessage()`:
```swift
let (paddedCiphertext, paddedSize) = try MLSMessagePadding.padCiphertextToBucket(ciphertext)
// Send paddedCiphertext to server
```

#### 2. **Receiving Messages** (`MLSClient.swift`)
Added envelope unwrapping in three locations:

**`processMessage()` (line 538-561):**
```swift
// Strip padding envelope before processing
if messageData.count >= 4 {
    let actualLength = Int(messageData.prefix(4).withUnsafeBytes {
        $0.load(as: UInt32.self).bigEndian
    })
    if actualLength > 0 && actualLength <= messageData.count - 4 {
        let processedData = messageData[4..<(4 + actualLength)]
        // Pass processedData to OpenMLS
    }
}
```

**`decryptMessage()` (line 289-299):** Same envelope stripping before decryption

**`processCommit()` (line 435-445):** Same envelope stripping for commit messages

### Message Flow

#### Sending
1. Encrypt plaintext → 170 bytes of MLS ciphertext
2. Wrap with padding: `[00 00 00 aa][170 bytes MLS][342 bytes zeros]` = 512 bytes
3. Send 512 bytes to server
4. Server stores 512 bytes

#### Receiving
1. Server returns 512 bytes
2. Client reads 4-byte length prefix: `0x000000aa` = 170
3. Extract bytes 4-173 (170 bytes of actual MLS message)
4. Discard bytes 174-511 (padding)
5. Pass 170 bytes to OpenMLS for processing

## Testing

Run the app and check logs for:
```
📍 [MLSClient.processMessage] Actual length: 170, total (with padding): 512
📍 [MLSClient.processMessage] Stripped envelope - actual message: 170 bytes (removed 342 bytes of padding)
✅ [MLSClient.processMessage] Success - content type: ApplicationMessage
```

## Benefits

1. **Traffic analysis resistance:** All messages appear as fixed bucket sizes (512, 1024, etc.)
2. **Privacy:** Actual message size hidden from network observers
3. **Compatibility:** Works with OpenMLS's standard TLS deserialization
4. **Efficiency:** Minimal overhead (4 bytes) for length encoding

## Future Improvements

Consider moving padding to server-side:
- Server could strip padding before storing
- Client receives raw MLS messages
- Simpler client implementation
- Still maintains traffic analysis resistance on the wire
