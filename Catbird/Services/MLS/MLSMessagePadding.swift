import Foundation

/// Helper for padding MLS messages to fixed bucket sizes for traffic analysis resistance
///
/// Format: [4-byte BE length][actual MLS message][zero padding...]
///
/// Bucket sizes: 512, 1024, 2048, 4096, 8192, or multiples of 8192
enum MLSMessagePadding {
    /// Bucket sizes for message padding (in bytes)
    private static let bucketSizes = [512, 1024, 2048, 4096, 8192]

    /// Pad ciphertext to the next bucket size
    /// - Parameter ciphertext: Raw MLS ciphertext
    /// - Returns: Tuple of (paddedData, bucketSize)
    /// - Note: Format is [4-byte BE length][ciphertext][padding...]
    static func padCiphertextToBucket(_ ciphertext: Data) throws -> (Data, Int) {
        let actualLength = ciphertext.count
        let lengthPrefixSize = 4
        let totalActualSize = lengthPrefixSize + actualLength

        // Find the appropriate bucket size
        let bucketSize: Int
        if let matchingBucket = bucketSizes.first(where: { $0 >= totalActualSize }) {
            bucketSize = matchingBucket
        } else {
            // For messages larger than 8192, round up to next multiple of 8192
            bucketSize = ((totalActualSize + 8191) / 8192) * 8192
        }

        // Create padded data: [4-byte length][ciphertext][zero padding]
        var paddedData = Data(count: bucketSize)

        // Write length prefix (big-endian)
        let lengthBE = UInt32(actualLength).bigEndian
        withUnsafeBytes(of: lengthBE) { bytes in
            paddedData.replaceSubrange(0..<4, with: bytes)
        }

        // Write actual ciphertext
        paddedData.replaceSubrange(4..<(4 + actualLength), with: ciphertext)

        // Remaining bytes are already zeros (padding)

        return (paddedData, bucketSize)
    }

    /// Remove padding from received message
    /// - Parameter paddedData: Padded message data
    /// - Returns: Original ciphertext without padding
    /// - Note: This should match the format created by padCiphertextToBucket
    static func removePadding(_ paddedData: Data) throws -> Data {
        let (unpadded, stripped) = stripPaddingIfPresent(paddedData)
        guard stripped else {
            throw MLSError.operationFailed
        }
        return unpadded
    }

    /// Attempt to remove padding if present without throwing.
    /// - Parameter data: Possibly padded MLS payload
    /// - Returns: Tuple of (unpaddedData, didStripPadding)
    static func stripPaddingIfPresent(_ data: Data) -> (Data, Bool) {
        guard data.count >= 4 else {
            return (data, false)
        }

        // The message is padded if the first 4 bytes represent a valid length
        // for the rest of the message, and the byte after the length is a
        // valid MLS wire format byte (0-4).

        let actualLength = Int(data.prefix(4).withUnsafeBytes {
            $0.load(as: UInt32.self).bigEndian
        })

        // Check if length is plausible
        guard actualLength > 0, actualLength <= data.count - 4 else {
            // If length is not plausible, assume it's not a padded envelope
            return (data, false)
        }

        let startIndex = 4
        let endIndex = 4 + actualLength
        let slice = data[startIndex..<endIndex]

        // Validate that the stripped payload begins with a valid MLS wire format byte.
        // Based on FFI logs, the wire format byte can be 0.
        if let wireFormat = slice.first, (0...4).contains(wireFormat) {
            return (Data(slice), true)
        }

        // If it looks like it has a length prefix but the wire format byte is invalid,
        // it's ambiguous. The safest thing to do is assume it's not padded.
        return (data, false)
    }
}
