import Foundation
import NaturalLanguage

/// Only changes that can alter visible posts require a feed refresh.
struct ReadingLanguageFilterSignature: Equatable, Sendable {
  let hidesOtherLanguages: Bool
  let preferredBaseCodes: [String]

  init(hideOtherLanguages: Bool, preferredLanguages: [String]) {
    let codes = Set(preferredLanguages.compactMap(ReadingLanguagePolicy.supportedBaseCode)).sorted()
    hidesOtherLanguages = hideOtherLanguages && !codes.isEmpty
    preferredBaseCodes = hidesOtherLanguages ? codes : []
  }
}

/// Reusable pool of NLLanguageRecognizer instances to avoid repeated allocations.
final class LanguageRecognizerPool: @unchecked Sendable {
  static let shared = LanguageRecognizerPool()
  private let lock = NSLock()
  private var pool: [NLLanguageRecognizer] = []
  private let maxPoolSize = 8

  func withRecognizer<T>(_ body: (NLLanguageRecognizer) -> T) -> T {
    lock.lock()
    let recognizer = pool.popLast() ?? NLLanguageRecognizer()
    lock.unlock()

    defer {
      recognizer.reset()
      lock.lock()
      if pool.count < maxPoolSize {
        pool.append(recognizer)
      }
      lock.unlock()
    }

    return body(recognizer)
  }
}

/// Thread-safe LRU cache for detected languages of undeclared posts, keyed by uri and cid.
final class DetectedLanguageCache: @unchecked Sendable {
  static let shared = DetectedLanguageCache()
  private let lock = NSLock()
  private var storage: [String: String?] = [:]
  private var ring: [String?]
  private var ringIndex = 0
  private let capacity: Int

  init(capacity: Int = 2048) {
    self.capacity = capacity
    self.ring = Array(repeating: nil, count: capacity)
  }

  func get(uri: String, cid: String) -> (found: Bool, language: String?) {
    lock.lock()
    defer { lock.unlock() }
    let key = "\(uri)|\(cid)"
    if let value = storage[key] {
      return (true, value)
    }
    return (false, nil)
  }

  func set(_ language: String?, uri: String, cid: String) {
    lock.lock()
    defer { lock.unlock() }
    let key = "\(uri)|\(cid)"
    if storage[key] == nil {
      if let evicted = ring[ringIndex] {
        storage.removeValue(forKey: evicted)
      }
      ring[ringIndex] = key
      ringIndex = (ringIndex + 1) % capacity
    }
    storage[key] = language
  }

  func clear() {
    lock.lock()
    defer { lock.unlock() }
    storage.removeAll(keepingCapacity: true)
    ring = Array(repeating: nil, count: capacity)
    ringIndex = 0
  }
}

/// Reading-language filtering compares supported base codes and retains undecidable posts.
enum ReadingLanguagePolicy {
  private static let supportedCodes = Set(Locale.LanguageCode.isoLanguageCodes.map(\.identifier))

  static func supportedBaseCode(_ raw: String) -> String? {
    let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").first.map(String.init) ?? ""
    guard supportedCodes.contains(code), !["und", "mul", "zxx", "mis"].contains(code) else { return nil }
    return code
  }

  static func detectLanguage(text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return LanguageRecognizerPool.shared.withRecognizer { recognizer in
      recognizer.processString(trimmed)
      if let language = recognizer.dominantLanguage,
         let confidence = recognizer.languageHypotheses(withMaximum: 3)[language], confidence >= 0.5 {
        return language.rawValue
      }
      return nil
    }
  }

  static func detectedLanguage(uri: String, cid: String, text: String) -> String? {
    let cached = DetectedLanguageCache.shared.get(uri: uri, cid: cid)
    if cached.found {
      return cached.language
    }
    let detected = detectLanguage(text: text)
    DetectedLanguageCache.shared.set(detected, uri: uri, cid: cid)
    return detected
  }

  static func allows(declaredLanguages: [String], preferredBaseCodes: Set<String>, detectedLanguage: String?) -> Bool {
    guard !preferredBaseCodes.isEmpty else { return true }
    if !declaredLanguages.isEmpty {
      let declared = declaredLanguages.compactMap(supportedBaseCode)
      // An unknown declaration cannot establish that every language is unwanted.
      guard declared.count == declaredLanguages.count else { return true }
      return declared.contains(where: preferredBaseCodes.contains)
    }
    guard let detectedLanguage, let detected = supportedBaseCode(detectedLanguage) else { return true }
    return preferredBaseCodes.contains(detected)
  }

  static func allows(
    declaredLanguages: [String],
    preferredBaseCodes: Set<String>,
    uri: String,
    cid: String,
    text: String
  ) -> Bool {
    guard !preferredBaseCodes.isEmpty else { return true }
    if !declaredLanguages.isEmpty {
      let declared = declaredLanguages.compactMap(supportedBaseCode)
      guard declared.count == declaredLanguages.count else { return true }
      return declared.contains(where: preferredBaseCodes.contains)
    }
    guard let detected = detectedLanguage(uri: uri, cid: cid, text: text),
          let base = supportedBaseCode(detected)
    else { return true }
    return preferredBaseCodes.contains(base)
  }

  static func allows(declaredLanguages: [String], preferredLanguages: [String], detectedLanguage: String?) -> Bool {
    let preferred = Set(preferredLanguages.compactMap(supportedBaseCode))
    return allows(declaredLanguages: declaredLanguages, preferredBaseCodes: preferred, detectedLanguage: detectedLanguage)
  }

  static func allows(declaredLanguages: [String], preferredLanguages: [String], text: String) -> Bool {
    let preferred = Set(preferredLanguages.compactMap(supportedBaseCode))
    guard !preferred.isEmpty else { return true }
    if !declaredLanguages.isEmpty {
      let declared = declaredLanguages.compactMap(supportedBaseCode)
      guard declared.count == declaredLanguages.count else { return true }
      return declared.contains(where: preferred.contains)
    }
    let detected = detectLanguage(text: text)
    return allows(declaredLanguages: declaredLanguages, preferredBaseCodes: preferred, detectedLanguage: detected)
  }
}
