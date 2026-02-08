# Notification Service Extension Setup

This directory contains the source code and configuration for the `NotificationServiceExtension`, which handles the decryption of MLS (Messaging Layer Security) push notifications.

## Integration Instructions

To enable this extension in your Xcode project, follow these steps:

1.  **Open Xcode**: Open `Catbird.xcodeproj`.
2.  **Add Target**:
    *   Go to `File > New > Target...`.
    *   Select `Notification Service Extension` (under iOS > Application Extension).
    *   Click `Next`.
    *   **Product Name**: `NotificationServiceExtension`.
    *   **Language**: `Swift`.
    *   **Project**: `Catbird`.
    *   **Embed in Application**: `Catbird`.
    *   Click `Finish`.
    *   *Note*: If Xcode asks to activate the scheme, you can say "Cancel" or "Activate".

3.  **Replace Files**:
    *   Xcode will create default files (`NotificationService.swift`, `Info.plist`).
    *   **Delete** the default files created by Xcode in the `NotificationServiceExtension` group in the Project Navigator.
    *   **Drag and Drop** the files from this directory (`NotificationService.swift`, `Info.plist`, `NotificationServiceExtension.entitlements`) into the `NotificationServiceExtension` group in Xcode.
    *   Ensure "Copy items if needed" is **unchecked** (since they are already in the folder).
    *   Ensure "Add to targets" has `NotificationServiceExtension` checked.

4.  **Configure Entitlements**:
    *   Select the `NotificationServiceExtension` target.
    *   Go to the `Signing & Capabilities` tab.
    *   **App Groups**:
        *   Click `+ Capability` if "App Groups" is not listed.
        *   Add `group.blue.catbird.shared`.
        *   Ensure it is checked.
    *   **Keychain Sharing**:
        *   Click `+ Capability` if "Keychain Sharing" is not listed.
        *   Add `$(AppIdentifierPrefix)blue.catbird.shared`.
        *   **Important**: This MUST match the keychain group in the main app's entitlements.

5.  **Link Frameworks**:
    *   The extension needs access to `MLSClient` and `Petrel`.
    *   Since `MLSClient` is part of the `Catbird` app target, you might need to:
        *   **Option A (Shared Framework)**: If `MLSClient` is in a framework, link it.
        *   **Option B (Compile Sources)**: Add `MLSClient.swift` and its dependencies (GRDB, Petrel, etc.) to the `NotificationServiceExtension` target's "Compile Sources" build phase.
        *   *Recommendation*: Ensure `Petrel` package is linked to the Extension target in "Frameworks, Libraries, and Embedded Content".

6.  **Build Settings**:
    *   Ensure `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` match the main app.
    *   Set `IPHONEOS_DEPLOYMENT_TARGET` to match the main app (e.g., iOS 18.0).
    *   **Add Compilation Flag**:
        *   Select the `NotificationServiceExtension` target.
        *   Go to `Build Settings` > Search for "Swift Compiler - Custom Flags".
        *   Under "Active Compilation Conditions", add `APP_EXTENSION` to both Debug and Release.
        *   This ensures MLSClient compiles correctly for the extension context.

## How It Works

The NotificationServiceExtension intercepts incoming push notifications with type `mls_message` and:
1. Extracts the encrypted `ciphertext`, `convo_id`, `message_id`, and `recipient_did` from the payload
2. Initializes `MLSClient` with access to the shared App Group container and Keychain
3. Decrypts the message using the user's MLS context
4. Displays the plaintext message in the notification

### Preventing Duplicate Decryption

The extension integrates with MLSClient's built-in duplicate message detection:
- Each message has a unique `message_id` from the server
- MLSClient stores processed message IDs in the shared SQLite database
- When decrypting, it checks if the message was already processed
- Duplicate messages are rejected automatically to prevent state corruption

## Troubleshooting

### Decryption Failures

*   **Check Console Logs**: Open Console.app on your Mac while the device is connected. Filter by `blue.catbird.notification-service` or `NotificationService`.
*   **Verify Shared Storage**: Ensure the App Group ID `group.blue.catbird.shared` matches exactly between the App and Extension.
*   **Keychain Access**: Verify keychain sharing is enabled with `$(AppIdentifierPrefix)blue.catbird.shared` in both targets.
*   **Database Access**: Check that the extension can read/write to the shared SQLite database at:
    ```
    containerURL/mls-state/<did_hash>.db
    ```

### Build Issues

*   **Missing Types**: If `MLSClient`, `MLSError`, or `MLSMessagePayload` are not found:
    *   Ensure all required source files are added to the NotificationServiceExtension target's "Compile Sources".
    *   Verify Petrel package is linked to the extension target.
*   **Compilation Errors**: Ensure `APP_EXTENSION` is added to "Active Compilation Conditions".

### Runtime Issues

*   **"Shared container not accessible"**: The extension couldn't access the app group. Verify entitlements are configured correctly and the app group exists in your Apple Developer account.
*   **"Could not determine Team ID"**: The extension couldn't determine your Team ID for keychain access. Check that your provisioning profile is correctly configured.
*   **Extension timeout**: If decryption takes too long (>30 seconds), the system will terminate the extension. The fallback message "New Encrypted Message" will be shown.

### Testing

1. **Send a test notification** with the following payload structure:
   ```json
   {
     "aps": {
       "alert": {
         "title": "New Message",
         "body": "Encrypted content"
       },
       "mutable-content": 1
     },
     "type": "mls_message",
     "ciphertext": "<base64-encoded-encrypted-data>",
     "convo_id": "<hex-encoded-group-id>",
     "message_id": "<unique-message-id>",
     "recipient_did": "did:plc:..."
   }
   ```
2. **Monitor Console.app** for decryption logs
3. **Verify the notification** shows the decrypted plaintext
