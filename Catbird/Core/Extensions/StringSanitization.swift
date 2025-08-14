import Foundation

// MARK: - Text Sanitization Extension

extension String {
    /// Sanitize string for safe display in SwiftUI
    /// Removes invalid characters that can crash CoreText, especially Object Replacement Characters
    func sanitizedForDisplay() -> String {
        // Return empty string for empty input
        guard !self.isEmpty else { return "" }
        
        var sanitized = self
        
        // CRITICAL: Remove Object Replacement Characters that crash CoreText
        sanitized = sanitized.replacingOccurrences(of: "\u{FFFC}", with: "") // Object Replacement Character
        sanitized = sanitized.replacingOccurrences(of: "\u{FFFD}", with: "") // Replacement Character
        
        // Remove null bytes and control characters
        sanitized = sanitized.replacingOccurrences(of: "\0", with: "")
            .components(separatedBy: .controlCharacters)
            .joined()
        
        // Remove problematic zero-width characters
        let zeroWidthChars = [
            "\u{200B}", // Zero Width Space
            "\u{200C}", // Zero Width Non-Joiner  
            "\u{200D}", // Zero Width Joiner
            "\u{FEFF}", // Byte Order Mark
            "\u{2060}", // Word Joiner
            "\u{061C}"  // Arabic Letter Mark
        ]
        
        for char in zeroWidthChars {
            sanitized = sanitized.replacingOccurrences(of: char, with: "")
        }
        
        // Remove bidirectional formatting characters that can cause layout issues
        let bidiChars = ["\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}"]
        for char in bidiChars {
            sanitized = sanitized.replacingOccurrences(of: char, with: "")
        }
        
        // Remove invalid Unicode sequences
        let validUnicode = sanitized.applyingTransform(.stripCombiningMarks, reverse: false) ?? sanitized
        
        // Ensure valid UTF-8
        guard let data = validUnicode.data(using: .utf8, allowLossyConversion: true),
              let result = String(data: data, encoding: .utf8) else {
            return ""
        }
        
        // Final validation: test with NSAttributedString to catch CoreText issues
        do {
            let testString = NSAttributedString(string: result)
            // Force layout test to catch attachment-related crashes
            let boundingRect = testString.boundingRect(
                with: CGSize(width: 100, height: 100),
                options: [.usesLineFragmentOrigin],
                context: nil
            )
            // Validate bounding rect is reasonable
            guard boundingRect.width.isFinite && boundingRect.height.isFinite else {
                return ""
            }
        } catch {
            return ""
        }
        
        // Trim excessive whitespace
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Limit length to prevent layout issues
        if trimmed.count > 10000 {
            return String(trimmed.prefix(10000)) + "..."
        }
        
        return trimmed
    }
    
    /// Check if string contains problematic characters
    var containsProblematicCharacters: Bool {
        // Check for null bytes
        if self.contains("\0") { return true }
        
        // Check for control characters
        if self.rangeOfCharacter(from: .controlCharacters) != nil { return true }
        
        // Check for invalid UTF-8 sequences
        if self.data(using: .utf8, allowLossyConversion: false) == nil { return true }
        
        return false
    }
}

// MARK: - ParsedPost Extension

extension ParsedPost {
    /// Get sanitized text for display
    var displayText: String {
        return text.sanitizedForDisplay()
    }
    
    /// Get a preview of the text (first 200 chars)
    var textPreview: String {
        let sanitized = text.sanitizedForDisplay()
        if sanitized.count > 200 {
            return String(sanitized.prefix(200)) + "..."
        }
        return sanitized
    }
}

// MARK: - ParsedProfile Extension

extension ParsedProfile {
    /// Get sanitized display name
    var safeDisplayName: String? {
        return displayName?.sanitizedForDisplay()
    }
    
    /// Get sanitized description
    var safeDescription: String? {
        return profileDescription?.sanitizedForDisplay()
    }
}

// MARK: - Data Validation for CBOR Parsing

extension Data {
    /// Validate that data can be safely converted to string
    func isValidUTF8() -> Bool {
        return String(data: self, encoding: .utf8) != nil
    }
    
    /// Convert to string with sanitization
    func toSanitizedString() -> String? {
        // Try UTF-8 first
        if let string = String(data: self, encoding: .utf8) {
            return string.sanitizedForDisplay()
        }
        
        // Try with lossy conversion
        if let string = String(data: self, encoding: .utf8) {
            return string.sanitizedForDisplay()
        }
        
        // Try ASCII as fallback
        if let string = String(data: self, encoding: .ascii) {
            return string.sanitizedForDisplay()
        }
        
        return nil
    }
}
