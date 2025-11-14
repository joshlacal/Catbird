import Foundation
import CryptoKit

extension Data {
    /// Initialize Data from a hex-encoded string
    /// - Parameter hexEncoded: A hex string (e.g., "0123456789abcdef")
    /// - Returns: Data initialized from the hex string, or nil if invalid
    init?(hexEncoded string: String) {
        var hex = string
        var data = Data()

        // Ensure even number of characters
        if hex.count % 2 != 0 {
            return nil
        }

        while !hex.isEmpty {
            let subIndex = hex.index(hex.startIndex, offsetBy: 2)
            let c = String(hex[..<subIndex])
            hex = String(hex[subIndex...])

            guard let byte = UInt8(c, radix: 16) else {
                return nil
            }
            data.append(byte)
        }

        self = data
    }

    /// Encode this Data as a hex string
    /// - Returns: Hex-encoded string (e.g., "0123456789abcdef")
    func hexEncodedString() -> String {
        return map { String(format: "%02hhx", $0) }.joined()
    }

    /// Initialize Data from a base64url-encoded string
    /// - Parameter base64url: A base64url string (RFC 4648 Section 5)
    /// - Returns: Data initialized from the base64url string, or nil if invalid
    init?(base64urlEncoded string: String) {
        // Convert base64url to standard base64
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        // Add padding if needed
        let paddingLength = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: paddingLength)

        // Decode using standard base64
        guard let data = Data(base64Encoded: base64) else {
            return nil
        }

        self = data
    }

    /// Encode this Data as a base64url string
    /// - Returns: Base64url-encoded string (RFC 4648 Section 5)
    func base64urlEncodedString() -> String {
        return base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - SHA256 Digest Extension

extension SHA256.Digest {
    /// Encode this SHA256 digest as a hex string
    /// - Returns: Hex-encoded string
    func hexEncodedString() -> String {
        return map { String(format: "%02hhx", $0) }.joined()
    }
}
