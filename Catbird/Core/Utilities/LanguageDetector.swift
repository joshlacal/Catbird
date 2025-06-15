import Foundation
import NaturalLanguage
import OSLog

// MARK: - Language Detection Utility

class LanguageDetector {
    private let logger = Logger(subsystem: "blue.catbird", category: "LanguageDetector")
    static let shared = LanguageDetector()
    
    private let recognizer = NLLanguageRecognizer()
    private let minimumConfidence: Double = 0.5
    
    private init() {}
    
    /// Detect the language of a given text
    func detectLanguage(for text: String) -> String? {
        recognizer.reset()
        recognizer.processString(text)
        
        guard let language = recognizer.dominantLanguage else {
            return nil
        }
        
        // Get confidence scores
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        
        if let confidence = hypotheses[language], confidence >= minimumConfidence {
            return language.rawValue
        }
        
        return nil
    }
    
    /// Detect multiple possible languages with confidence scores
    func detectLanguages(for text: String, maxLanguages: Int = 3) -> [(language: String, confidence: Double)] {
        recognizer.reset()
        recognizer.processString(text)
        
        let hypotheses = recognizer.languageHypotheses(withMaximum: maxLanguages)
        
        return hypotheses.compactMap { (language, confidence) in
            if confidence >= 0.1 { // Lower threshold for multiple detection
                return (language.rawValue, confidence)
            }
            return nil
        }.sorted { $0.confidence > $1.confidence }
    }
    
    /// Check if a text matches any of the user's content languages
    func matchesContentLanguages(_ text: String, contentLanguages: [String]) -> Bool {
        // Empty text always matches
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }
        
        // If no language preferences set, show all content
        guard !contentLanguages.isEmpty else {
            return true
        }
        
        // Detect the language
        guard let detectedLanguage = detectLanguage(for: text) else {
            // If we can't detect the language, show the content
            return true
        }
        
        // Check if detected language matches any content language
        return contentLanguages.contains { lang in
            // Handle language variants (e.g., "en" matches "en-US", "en-GB", etc.)
            if detectedLanguage.hasPrefix(lang) || lang.hasPrefix(detectedLanguage) {
                return true
            }
            
            // Check for exact match
            return detectedLanguage == lang
        }
    }
    
    /// Get display name for a language code
    static func displayName(for languageCode: String) -> String {
        let locale = Locale.current
        if let name = locale.localizedString(forLanguageCode: languageCode) {
            return name
        }
        return languageCode.uppercased()
    }
    
    /// Get native name for a language code
    static func nativeName(for languageCode: String) -> String {
        let locale = Locale(identifier: languageCode)
        if let name = locale.localizedString(forLanguageCode: languageCode) {
            return name
        }
        return languageCode.uppercased()
    }
}

// MARK: - Content Language Filter

@MainActor
class ContentLanguageFilter: ObservableObject {
    @Published var isEnabled: Bool = true
    @Published var contentLanguages: [String] = []
    
    private let detector = LanguageDetector.shared
    
    init() {
        loadPreferences()
        
        // Listen for language preference changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languagePreferencesChanged),
            name: NSNotification.Name("LanguagePreferencesChanged"),
            object: nil
        )
    }
    
    private func loadPreferences() {
        let defaults = UserDefaults(suiteName: "group.blue.catbird.shared")
        contentLanguages = defaults?.stringArray(forKey: "contentLanguages") ?? ["en"]
        isEnabled = defaults?.bool(forKey: "enableLanguageFilter") ?? true
    }
    
    @objc private func languagePreferencesChanged() {
        loadPreferences()
    }
    
    /// Check if a post should be shown based on language filters
    func shouldShowPost(_ text: String?) -> Bool {
        guard isEnabled else { return true }
        guard let text = text else { return true }
        
        return detector.matchesContentLanguages(text, contentLanguages: contentLanguages)
    }
    
    /// Filter an array of posts based on language preferences
    func filterPosts<T>(_ posts: [T], textExtractor: (T) -> String?) -> [T] {
        guard isEnabled else { return posts }
        
        return posts.filter { post in
            shouldShowPost(textExtractor(post))
        }
    }
}

// MARK: - Language Statistics

struct LanguageStatistics {
    let languageCode: String
    let postCount: Int
    let percentage: Double
    
    var displayName: String {
        LanguageDetector.displayName(for: languageCode)
    }
}

extension ContentLanguageFilter {
    /// Analyze language distribution in a set of posts
    func analyzeLanguageDistribution<T>(_ posts: [T], textExtractor: (T) -> String?) -> [LanguageStatistics] {
        var languageCounts: [String: Int] = [:]
        var totalPosts = 0
        
        for post in posts {
            guard let text = textExtractor(post) else { continue }
            
            if let language = detector.detectLanguage(for: text) {
                languageCounts[language, default: 0] += 1
                totalPosts += 1
            }
        }
        
        return languageCounts.map { (language, count) in
            LanguageStatistics(
                languageCode: language,
                postCount: count,
                percentage: Double(count) / Double(totalPosts) * 100
            )
        }.sorted { $0.postCount > $1.postCount }
    }
}
