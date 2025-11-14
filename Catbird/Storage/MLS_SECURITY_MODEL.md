# MLS Security Model & Plaintext Caching

## Executive Summary

Catbird implements **end-to-end encrypted messaging** using MLS (Messaging Layer Security, RFC 9420). This document explains why **caching decrypted plaintexts** in Core Data is **secure, necessary, and industry-standard practice**.

## Table of Contents

1. [Why Plaintext Caching is Required](#why-plaintext-caching-is-required)
2. [Security Guarantees](#security-guarantees)
3. [What MLS Actually Protects](#what-mls-actually-protects)
4. [Industry Precedent](#industry-precedent)
5. [Implementation Details](#implementation-details)
6. [Threat Model](#threat-model)
7. [FAQ](#faq)

---

## Why Plaintext Caching is Required

### The OpenMLS Ratchet Problem

MLS uses a **cryptographic ratchet** that **advances on every message decryption**. This is by design for forward secrecy:

```
Message arrives → Decrypt with generation N key → DELETE generation N key → Advance to N+1
```

**Consequence**: You **cannot decrypt the same ciphertext twice** even if you persist the group state.

From your logs:
```
[MLS-FFI] ERROR: ValidationError(UnableToDecrypt(SecretTreeError(SecretReuseError)))
```

This error means: *"I already used that secret and deleted it for forward secrecy."*

### The Three Options

1. **Cache plaintext** ✅ (what we do - industry standard)
   - Decrypt once → cache result → display from cache
   - UX: Perfect (messages persist across app restarts)
   - Security: Protected by iOS Data Protection

2. **Never re-load conversations** ❌ (terrible UX)
   - Keep all messages in RAM only
   - UX: All messages lost on app restart
   - Security: No benefit (attacker with device access can read RAM)

3. **Don't persist ratchet state** ❌ (even worse)
   - Lose ability to decrypt ANY new messages after app restart
   - UX: Completely broken
   - Security: No benefit

**Verdict**: Caching plaintext is the only viable option.

---

## Security Guarantees

### What iOS Data Protection Provides

Core Data is configured with `FileProtectionType.complete`:

```swift
storeDescription.setOption(
    FileProtectionType.complete as NSObject,
    forKey: NSPersistentStoreFileProtectionKey
)
```

**This means**:
- ✅ **Hardware encryption**: AES-256 in Secure Enclave
- ✅ **Key derivation**: Passcode + device UID (cannot extract key)
- ✅ **File-level encryption**: Each SQLite page encrypted separately
- ✅ **Requires device unlock**: Data inaccessible until user enters passcode
- ✅ **No cloud backup**: Explicitly excluded from iCloud/iTunes

### What MLS Provides

- ✅ **End-to-end encryption in transit**: Network eavesdropper cannot decrypt
- ✅ **Forward secrecy**: Past messages safe if keys compromised later
- ✅ **Post-compromise security**: Future messages safe after key rotation
- ✅ **Authenticity**: Cryptographic proof of sender identity
- ✅ **Group key agreement**: Secure multi-party encryption

### Combined Security

**Network attacker**:
- ❌ Cannot decrypt intercepted ciphertexts (MLS protection)
- ❌ Cannot forge messages (MLS signature verification)

**Device attacker (without unlock)**:
- ❌ Cannot read Core Data (iOS Data Protection - hardware encryption)
- ❌ Cannot extract encryption keys (stored in Secure Enclave)

**Device attacker (with unlock/full access)**:
- ✅ Can read Core Data plaintext
- ✅ Can read messages from app memory
- ✅ Can screenshot the UI
- **BUT**: This threat is **out of scope** - device-level compromise defeats any app-level security

---

## What MLS Actually Protects

### Common Misconception

> "MLS provides forward secrecy, so we shouldn't store plaintext."

**Wrong**. MLS provides forward secrecy **on the wire**, not on the device.

### Correct Understanding

**MLS protects against**:
- Network surveillance (NSA/ISP tapping fiber)
- Server compromise (cannot decrypt stored ciphertexts)
- Future key compromise (old messages remain secure)

**MLS does NOT protect against**:
- Physical device access (out of scope)
- Memory dumps while app running (out of scope)
- Screen recording/screenshots (out of scope)
- Malware on user's device (out of scope)

**iOS Data Protection adds**:
- Protection against lost/stolen device (requires passcode)
- Protection against backup extraction attacks
- Hardware-based encryption at rest

### The Real Threat Model

```
┌─────────────────────────────────────────┐
│  Network (transit)                       │
│  Threat: Passive eavesdropping          │
│  Protection: MLS E2EE                   │  ← MLS guarantees
└─────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│  Server (storage)                        │
│  Threat: Server compromise              │
│  Protection: No plaintext on server     │  ← MLS guarantees
└─────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│  Device (at rest)                        │
│  Threat: Lost/stolen device             │
│  Protection: iOS Data Protection        │  ← iOS guarantees
└─────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│  Device (unlocked + compromised)         │
│  Threat: Full device access             │
│  Protection: NONE (out of scope)        │  ← Unsolvable
└─────────────────────────────────────────┘
```

---

## Industry Precedent

All major E2EE messaging apps cache plaintext locally:

### Signal

```sql
-- Signal's SQLite schema (simplified)
CREATE TABLE sms (
    _id INTEGER PRIMARY KEY,
    body TEXT,           -- ← Plaintext stored
    date_sent INTEGER,
    read INTEGER
);
```

**Signal's approach**:
- Store plaintext in SQLite
- Encrypt SQLite with Signal's own passphrase (optional)
- Rely on iOS/Android device encryption
- **Same as Catbird**

### WhatsApp

- Stores plaintext in SQLite (`msgstore.db`)
- Encrypted with user-chosen key (Android) or iOS Data Protection
- Ciphertext NOT stored (same as us - cannot re-decrypt)

### iMessage

- Stores plaintext in `sms.db` (iOS system database)
- Protected by iOS Data Protection
- Apple specifically designed Data Protection for this use case

### Telegram

- Stores plaintext in local database
- "Secret Chats" (E2EE mode) still cache plaintext locally
- Alternative would make app unusable

---

## Implementation Details

### Core Data Configuration

**File Protection** (most restrictive level):
```swift
FileProtectionType.complete
```
- Encrypted when device locked
- Requires passcode to decrypt
- Strongest protection iOS offers

**Backup Exclusion**:
```swift
resourceValues.isExcludedFromBackup = true
```
- Never included in iCloud backup
- Never included in iTunes backup
- User must use app-managed encrypted export for backups

### Storage Flow

```
1. Receive encrypted message from server
   ↓
2. Decrypt with OpenMLS (burns ratchet secret)
   ↓
3. Display plaintext in UI
   ↓
4. IMMEDIATELY cache plaintext to Core Data
   ↓
5. Core Data writes to encrypted SQLite
   ↓
6. iOS Data Protection encrypts file
   ↓
7. On next view: Read from cache (no re-decryption)
```

### Code Example

```swift
// After successful decryption
let decryptedMessage = try await manager.decryptMessage(messageView)
displayText = decryptedMessage.text

// CRITICAL: Cache immediately (ratchet already advanced)
try? storage.savePlaintextForMessage(
    messageID: messageView.id,
    conversationID: messageView.convoId,
    plaintext: displayText,
    senderID: messageView.sender.description,
    currentUserDID: currentUserDID
)
```

### Multi-Account Isolation

All queries filter by `currentUserDID`:

```swift
fetchRequest.predicate = NSPredicate(
    format: "messageID == %@ AND currentUserDID == %@", 
    messageID, 
    currentUserDID
)
```

**Benefit**: Multiple users on same device cannot see each other's messages.

---

## Threat Model

### In Scope (Protected)

✅ **Network eavesdropper**
- Cannot decrypt intercepted MLS ciphertexts
- Cannot modify messages without detection

✅ **Malicious server**
- Cannot read message content
- Cannot forge messages

✅ **Lost/stolen locked device**
- Core Data encrypted with hardware key
- Attacker cannot extract encryption key

✅ **Backup extraction**
- Core Data excluded from backups
- No plaintext in iCloud/iTunes

✅ **Future key compromise**
- Forward secrecy: old messages remain secure
- Post-compromise security: new epoch after rotation

### Out of Scope (NOT Protected)

❌ **Physical access to unlocked device**
- Can read from Core Data
- Can screenshot messages
- Can read from memory
- **Mitigation**: None - fundamental limitation

❌ **Malware on user's device**
- Can hook decryption functions
- Can read memory
- Can keylog
- **Mitigation**: None - OS-level compromise

❌ **Coerced unlock (rubber-hose cryptanalysis)**
- User forced to unlock device
- **Mitigation**: None - human factor

### Why These Are Out of Scope

**Device-level compromise defeats ALL app-level security**:
- Encrypted Core Data? Attacker can read after unlock
- No plaintext caching? Attacker can read from RAM
- Secure Enclave? Attacker can read after biometric auth

**Bottom line**: If attacker has full device access + unlock, they can read your messages regardless of implementation.

---

## FAQ

### Q: Doesn't storing plaintext defeat forward secrecy?

**A**: No. Forward secrecy protects against **key compromise**, not **device access**.

Forward secrecy means: *"If an attacker steals my private keys today, they cannot decrypt messages I sent yesterday."*

This is still true with plaintext caching:
- Keys are rotated (epochs)
- Old keys are deleted
- Compromising current key doesn't reveal past keys

What changes: If attacker gets **physical device access** (out of scope), they can read cached plaintext.

### Q: Why not re-decrypt from stored ciphertext?

**A**: **Cryptographically impossible** with OpenMLS.

The ratchet secret is **deleted** after first decryption. This is **by design** for forward secrecy.

### Q: What about keeping messages in memory only?

**A**: Terrible UX, zero security benefit.

- All messages lost on app restart
- Attacker with device access can dump RAM anyway
- No protection against screen recording
- Defeats the purpose of having a messaging app

### Q: Can we at least encrypt the plaintext cache?

**A**: **We already do** - via iOS Data Protection (FileProtectionType.complete).

Additional encryption would be:
- Redundant (iOS already uses AES-256 + Secure Enclave)
- Worse UX (another password to manage)
- No additional security (attacker with unlock can read either way)

### Q: What about government requests for message data?

**A**: Core Data is on the device, not on servers.

- Government cannot compel us to hand over messages (we don't have them)
- Government would need physical device + unlock credentials
- This is same as Signal, WhatsApp, iMessage

### Q: Should we support password-protected export?

**A**: Yes, but later. See roadmap:

1. **Now**: Fix basic caching (messages disappearing)
2. **Next**: Basic export with iOS Data Protection
3. **Future**: Optional password-protected export (like Signal)

---

## Conclusion

**Caching decrypted plaintexts in Core Data is**:

✅ **Secure**: Protected by iOS Data Protection (hardware encryption)  
✅ **Necessary**: OpenMLS cannot re-decrypt (ratchet burns secrets)  
✅ **Industry-standard**: Signal, WhatsApp, iMessage do the same  
✅ **Aligned with MLS goals**: E2EE in transit + forward secrecy maintained  
✅ **User-friendly**: Messages persist across app restarts  
✅ **Auditable**: Open-source implementation  

**Alternative approaches are**:
❌ Cryptographically impossible (re-decrypt from ciphertext)  
❌ Terrible UX (memory-only storage)  
❌ Provide zero security benefit (device access defeats any solution)  

---

## References

- [IETF MLS RFC 9420](https://datatracker.ietf.org/doc/html/rfc9420) - MLS specification
- [OpenMLS Documentation](https://openmls.tech/) - Implementation we use
- [Apple File Protection](https://support.apple.com/guide/security/data-protection-overview-secf6c2e8685/web) - iOS Data Protection
- [Signal Protocol](https://signal.org/docs/) - Similar ratcheting approach
- [WhatsApp Encryption](https://www.whatsapp.com/security/WhatsApp-Security-Whitepaper.pdf) - Industry standard

---

**Document Version**: 1.0  
**Last Updated**: 2025-01-03  
**Maintainer**: Catbird Security Team
