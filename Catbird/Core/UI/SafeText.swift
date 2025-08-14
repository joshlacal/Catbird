import SwiftUI
import OSLog

// MARK: - Safe Text View Wrapper

/// A SwiftUI Text view wrapper that prevents CoreText crashes from corrupted text data
/// This wrapper provides multiple layers of protection against text rendering crashes
struct SafeText: View {
    private let text: String
    private let fallback: String
    private let logger = Logger(subsystem: "blue.catbird.core", category: "SafeText")
    
    init(_ text: String, fallback: String = "[Invalid Text]") {
        self.text = text
        self.fallback = fallback
    }
    
    var body: some View {
        Group {
            if let safeText = createSafeText() {
                Text(safeText)
            } else {
                Text(fallback)
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
    }
    
    /// Creates safe text with multiple validation layers
    private func createSafeText() -> String? {
        // Layer 1: Basic validation
        guard !text.isEmpty else { return nil }
        
        // Layer 2: Sanitization using existing extension
        let sanitized = text.sanitizedForDisplay()
        guard !sanitized.isEmpty else { return nil }
        
        // The sanitizedForDisplay() function now includes NSAttributedString validation
        // so we can return the sanitized text directly
        return sanitized
    }
}

// MARK: - Safe Text Modifiers

extension SafeText {
    func font(_ font: Font) -> some View {
        Group {
            if let safeText = createSafeText() {
                Text(safeText).font(font)
            } else {
                Text(fallback)
                    .font(font)
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
    }
    
    func foregroundColor(_ color: Color) -> some View {
        Group {
            if let safeText = createSafeText() {
                Text(safeText).foregroundColor(color)
            } else {
                Text(fallback)
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
    }
    
    func lineLimit(_ limit: Int?) -> some View {
        Group {
            if let safeText = createSafeText() {
                Text(safeText).lineLimit(limit)
            } else {
                Text(fallback)
                    .lineLimit(limit)
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
    }
}

// MARK: - View Extension for Easy Usage

extension View {
    /// Replaces Text(string) with SafeText(string) for crash prevention
    func safeText(_ text: String, fallback: String = "[Invalid Text]") -> SafeText {
        return SafeText(text, fallback: fallback)
    }
}

// MARK: - SwiftUI Text Extension

extension Text {
    /// Creates a safe Text view from potentially corrupted string data
    static func safe(_ text: String, fallback: String = "[Invalid Text]") -> Text {
        let sanitized = text.sanitizedForDisplay()
        let safeText = sanitized.isEmpty ? fallback : sanitized
        return Text(safeText)
    }
    
    /// Creates a verbatim safe Text view (bypasses localization)
    static func safeVerbatim(_ text: String, fallback: String = "[Invalid Text]") -> Text {
        let sanitized = text.sanitizedForDisplay()
        let safeText = sanitized.isEmpty ? fallback : sanitized
        return Text(verbatim: safeText)
    }
}
