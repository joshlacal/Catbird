import Foundation

/// Exact byte slices of a JSON document, for records handed to the FFI.
///
/// Swift never re-encodes a record it passes to `catbird-mls`: Petrel's typed
/// encoders add nested `$type` fields and drop unknown ones, while the Rust
/// record definitions are `deny_unknown_fields`. Responses are decoded twice
/// instead: typed for Swift's own use, and sliced here for the FFI.
///
/// The scanner is deliberately small: it validates structure only as far as
/// needed to find member and element boundaries (strings with escapes, nesting
/// depth). Anything it cannot delimit returns nil; duplicate member names
/// return nil rather than guess which copy a decoder would pick.
enum RawJSON {
  /// The exact bytes of top-level member `name` of the object in `data`.
  static func member(_ name: String, in data: Data) -> Data? {
    let bytes = [UInt8](data)
    guard let members = objectMembers(bytes) else { return nil }
    let matches = members.filter { $0.name == name }
    guard matches.count == 1, let range = matches.first?.value else { return nil }
    return Data(bytes[range])
  }

  /// The exact bytes of each element of the array in `data`.
  static func elements(in data: Data) -> [Data]? {
    let bytes = [UInt8](data)
    var index = skipWhitespace(bytes, 0)
    guard index < bytes.count, bytes[index] == UInt8(ascii: "[") else { return nil }
    index = skipWhitespace(bytes, index + 1)
    var result: [Data] = []
    if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
      return skipWhitespace(bytes, index + 1) == bytes.count ? result : nil
    }
    while index < bytes.count {
      guard let end = valueEnd(bytes, index) else { return nil }
      result.append(Data(bytes[index..<end]))
      index = skipWhitespace(bytes, end)
      guard index < bytes.count else { return nil }
      if bytes[index] == UInt8(ascii: ",") {
        index = skipWhitespace(bytes, index + 1)
      } else if bytes[index] == UInt8(ascii: "]") {
        return skipWhitespace(bytes, index + 1) == bytes.count ? result : nil
      } else {
        return nil
      }
    }
    return nil
  }

  /// `member` as UTF-8 text.
  static func memberString(_ name: String, in data: Data) -> String? {
    member(name, in: data).flatMap { String(data: $0, encoding: .utf8) }
  }

  // MARK: Scanner

  private struct Member {
    let name: String
    let value: Range<Int>
  }

  private static func objectMembers(_ bytes: [UInt8]) -> [Member]? {
    var index = skipWhitespace(bytes, 0)
    guard index < bytes.count, bytes[index] == UInt8(ascii: "{") else { return nil }
    index = skipWhitespace(bytes, index + 1)
    var members: [Member] = []
    if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
      return skipWhitespace(bytes, index + 1) == bytes.count ? members : nil
    }
    while index < bytes.count {
      guard bytes[index] == UInt8(ascii: "\""), let keyEnd = stringEnd(bytes, index),
            let name = try? JSONDecoder().decode(String.self, from: Data(bytes[index..<keyEnd]))
      else { return nil }
      index = skipWhitespace(bytes, keyEnd)
      guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
      index = skipWhitespace(bytes, index + 1)
      guard let end = valueEnd(bytes, index) else { return nil }
      members.append(Member(name: name, value: index..<end))
      index = skipWhitespace(bytes, end)
      guard index < bytes.count else { return nil }
      if bytes[index] == UInt8(ascii: ",") {
        index = skipWhitespace(bytes, index + 1)
      } else if bytes[index] == UInt8(ascii: "}") {
        return skipWhitespace(bytes, index + 1) == bytes.count ? members : nil
      } else {
        return nil
      }
    }
    return nil
  }

  private static func skipWhitespace(_ bytes: [UInt8], _ start: Int) -> Int {
    var index = start
    while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    return index
  }

  /// One past the closing quote of the string starting at `start`.
  private static func stringEnd(_ bytes: [UInt8], _ start: Int) -> Int? {
    var index = start + 1
    while index < bytes.count {
      switch bytes[index] {
      case UInt8(ascii: "\\"): index += 2
      case UInt8(ascii: "\""): return index + 1
      default: index += 1
      }
    }
    return nil
  }

  /// One past the end of the value starting at `start`.
  private static func valueEnd(_ bytes: [UInt8], _ start: Int) -> Int? {
    guard start < bytes.count else { return nil }
    switch bytes[start] {
    case UInt8(ascii: "\""):
      return stringEnd(bytes, start)
    case UInt8(ascii: "{"), UInt8(ascii: "["):
      var depth = 0
      var index = start
      while index < bytes.count {
        switch bytes[index] {
        case UInt8(ascii: "\""):
          guard let end = stringEnd(bytes, index) else { return nil }
          index = end
          continue
        case UInt8(ascii: "{"), UInt8(ascii: "["):
          depth += 1
        case UInt8(ascii: "}"), UInt8(ascii: "]"):
          depth -= 1
          if depth == 0 { return index + 1 }
        default:
          break
        }
        index += 1
      }
      return nil
    default:
      var index = start
      while index < bytes.count,
            ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
        index += 1
      }
      return index > start ? index : nil
    }
  }
}
