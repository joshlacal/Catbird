#!/bin/bash

# Fix MLSConversationManager.swift compilation errors

FILE="/Users/joshlacalamito/Developer/Catbird+Petrel/Catbird/Catbird/Services/MLS/MLSConversationManager.swift"

echo "Fixing MLSConversationManager.swift..."

# 1. Add CryptoKit import for SHA256
sed -i.bak '4a\
import CryptoKit
' "$FILE"

# 2. Fix MLSConfiguration reference by using full module path
sed -i.bak 's/private let configuration: MLSConfiguration/private let configuration: Services.MLSConfiguration/g' "$FILE"
sed -i.bak 's/init(\(.*\)configuration: MLSConfiguration/init(\1configuration: Services.MLSConfiguration/g' "$FILE"

# 3. Remove MLSOperation usage (replace with a comment since it's not defined)
sed -i.bak 's/private var pendingOperations: \[MLSOperation\] = \[\]/\/\/ Pending operations queue (removed - MLSOperation not defined)/g' "$FILE"

# 4. Fix MLSConversationError.notInitialized (doesn't exist in MLSError.swift)
sed -i.bak 's/throw MLSConversationError.notInitialized/throw MLSError.operationFailed/g' "$FILE"

# 5. Remove duplicate decryptMessageWithSender method  (line 645)
# This is complex - we'll need to find and remove the duplicate

# 6. Fix CredentialData.senderId (doesn't exist)
# This line needs to be removed or the logic fixed

# 7. Fix apiClient.getWelcomeMessage (doesn't exist)
# Change to the correct method name

# 8. Remove duplicate DecryptedMLSMessage and MLSConfiguration structs at end of file
# These should be imported from their own files

echo "Backup created as $FILE.bak"
echo "Fixed $FILE"
echo ""
echo "Note: Manual fixes still needed for:"
echo "  - duplicate decryptMessageWithSender method"
echo "  - CredentialData.senderId reference"
echo "  - apiClient.getWelcomeMessage method"
echo "  - duplicate struct definitions"
echo "  - handleEpochUpdate reference"
echo "  - Proposal type definition"
