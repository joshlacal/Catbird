import Foundation

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
}
