import Foundation

/// Caps the exact text returned by a read, with a token counter supplied by the active local model.
enum CopilotToolResult {
  static let maximumTokens = 512

  static func bounded(
    _ text: String,
    tokenCount: @Sendable (String) async throws -> Int
  ) async throws -> (text: String, wasTruncated: Bool) {
    try Task.checkCancellation()
    let count = try await tokenCount(text)
    try Task.checkCancellation()
    guard count > maximumTokens else { return (text, false) }
    if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
       object is [String: Any] || object is [Any] {
      return try await boundedJSON(object, tokenCount: tokenCount)
    }
    let notice = "Partial tool result (truncated; omitted contents are unknown):\n"
    var prefix = text
    // Geometric reduction bounds tokenizer work even for adversarially large results.
    while !prefix.isEmpty {
      prefix = String(prefix.prefix(prefix.count / 2))
      let candidate = notice + prefix
      let candidateCount = try await tokenCount(candidate)
      try Task.checkCancellation()
      if candidateCount <= maximumTokens { return (candidate, true) }
    }
    return ("Tool result omitted because it exceeded the context budget.", true)
  }

  /// Reduce complete JSON values, never raw serialized prefixes. Identities and
  /// field names survive reduction; the envelope discloses omitted data.
  private static func boundedJSON(
    _ object: Any, tokenCount: @Sendable (String) async throws -> Int
  ) async throws -> (text: String, wasTruncated: Bool) {
    for (stringLimit, arrayLimit) in [(256, 6), (128, 3), (64, 2), (32, 1), (8, 1)] {
      try Task.checkCancellation()
      var payload = reduced(object, stringLimit: stringLimit, arrayLimit: arrayLimit) as? [String: Any]
        ?? ["result": reduced(object, stringLimit: stringLimit, arrayLimit: arrayLimit)]
      payload["toolResultStatus"] = "Partial result: strings or arrays truncated; omitted contents are unknown."
      let candidate = try serialized(payload)
      let candidateCount = try await tokenCount(candidate)
      try Task.checkCancellation()
      if candidateCount <= maximumTokens { return (candidate, true) }
    }
    // Even an identity or schema can exceed the budget. Return a complete, truthful
    // JSON status instead of a misleading fragment of a post's contents.
    let omitted = #"{"toolResultStatus":"Result omitted: context budget exceeded; contents are unknown."}"#
    let omittedCount = try await tokenCount(omitted)
    try Task.checkCancellation()
    return (omittedCount <= maximumTokens ? omitted : "{}", true)
  }

  private static func reduced(_ object: Any, key: String = "", stringLimit: Int, arrayLimit: Int) -> Any {
    if let dictionary = object as? [String: Any] {
      var result = dictionary.reduce(into: [String: Any]()) { result, pair in
        result[pair.key] = reduced(pair.value, key: pair.key, stringLimit: stringLimit, arrayLimit: arrayLimit)
      }
      if let originalText = dictionary["text"] as? String, originalText != result["text"] as? String {
        result["textTruncated"] = true
      }
      if dictionary["kind"] != nil {
        var fields = dictionary["truncatedFields"] as? [String] ?? []
        for field in ["altText", "title", "description"] {
          if let original = dictionary[field] as? String, original != result[field] as? String, !fields.contains(field) {
            fields.append(field)
          }
        }
        if !fields.isEmpty { result["truncatedFields"] = fields }
      }
      for (field, value) in dictionary {
        if let array = value as? [Any], array.count > arrayLimit {
          result[field + "OmittedCount"] = array.count - arrayLimit
          if field == "posts", let previous = dictionary["omittedReturnedItems"] as? Int {
            result["omittedReturnedItems"] = previous + array.count - arrayLimit
          }
        }
      }
      return result
    }
    if let array = object as? [Any] {
      return array.prefix(arrayLimit).map { reduced($0, key: key, stringLimit: stringLimit, arrayLimit: arrayLimit) }
    }
    if let string = object as? String {
      let identities = ["id", "uri", "cid", "authorDID", "replyTo", "replyToURI", "root", "rootURI", "quotedPostURI", "kind", "role", "contentStatus"]
      guard !identities.contains(key), string.count > stringLimit else { return string }
      return String(string.prefix(stringLimit)) + "…"
    }
    return object
  }

  private static func serialized(_ object: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
      .replacingOccurrences(of: "<", with: #"\u003C"#)
      .replacingOccurrences(of: ">", with: #"\u003E"#)
  }

}
