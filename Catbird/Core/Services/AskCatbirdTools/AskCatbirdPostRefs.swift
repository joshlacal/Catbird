import Foundation
import os

/// Short names (`p1`, `p2`, …) for the posts one Ask Catbird turn shows the model.
///
/// A post's AT URI costs about 25 tokens, which adds up fast in a small context
/// window. Read results name posts by short id instead; tools resolve ids back to
/// URIs, and ids cited in the answer or kept in stored evidence are expanded so
/// nothing outside the turn ever sees them.
final class AskCatbirdPostRefs: Sendable {
  private struct State {
    var byURI: [String: String] = [:]
    var byRef: [String: String] = [:]
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  /// The id for a post, assigned on first use and stable for the turn.
  func ref(for uri: String) -> String {
    state.withLock { state in
      if let ref = state.byURI[uri] { return ref }
      let ref = "p\(state.byRef.count + 1)"
      state.byURI[uri] = ref
      state.byRef[ref] = uri
      return ref
    }
  }

  func uri(for ref: String) -> String? {
    state.withLock { $0.byRef[ref.lowercased()] }
  }

  /// The URI an id names, or the input unchanged when it is not a known id.
  func resolve(_ input: String) -> String {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    return uri(for: trimmed) ?? input
  }

  /// Replaces ids used as JSON string values, such as `"id":"p3"`, with their URIs.
  func expandJSON(_ text: String) -> String {
    var result = ""
    var string: String?
    var escaped = false
    for character in text {
      guard var value = string else {
        if character == "\"" { string = "" } else { result.append(character) }
        continue
      }
      if escaped {
        value.append(character)
        escaped = false
      } else if character == "\\" {
        value.append(character)
        escaped = true
      } else if character == "\"" {
        let expanded = Self.isRefShaped(value) ? uri(for: value) ?? value : value
        result += "\"" + expanded + "\""
        string = nil
        continue
      } else {
        value.append(character)
      }
      string = value
    }
    if let value = string { result += "\"" + value }
    return result
  }

  /// Replaces ids cited in answer text, as in `[@alice](p3)` or `(p3)`, with their URIs.
  /// `precededBy` is the character before `text`, for text that continues earlier output.
  func expandAnswer(_ text: String, precededBy: Character? = nil) -> String {
    var result = ""
    var previous = precededBy
    var index = text.startIndex
    while index < text.endIndex {
      let character = text[index]
      if character == "p", Self.opensRef(previous) {
        let digitsStart = text.index(after: index)
        let digitsEnd = text[digitsStart...].firstIndex { !($0.isASCII && $0.isNumber) } ?? text.endIndex
        if digitsEnd > digitsStart, Self.closesRef(digitsEnd < text.endIndex ? text[digitsEnd] : nil),
           let uri = uri(for: String(text[index..<digitsEnd])) {
          result += uri
          previous = text[text.index(before: digitsEnd)]
          index = digitsEnd
          continue
        }
      }
      result.append(character)
      previous = character
      index = text.index(after: index)
    }
    return result
  }

  static func isRefShaped(_ value: String) -> Bool {
    value.count >= 2 && value.first == "p" && value.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
  }

  static func opensRef(_ character: Character?) -> Bool {
    guard let character else { return true }
    return character.isWhitespace || character == "(" || character == "["
  }

  static func closesRef(_ character: Character?) -> Bool {
    guard let character else { return true }
    return character.isWhitespace || ")].,;:!?".contains(character)
  }
}

/// Expands post ids in a streamed answer without ever changing text already shown.
///
/// A trailing id may still grow (`p1` → `p12`), so it is held back until the
/// next snapshot or the end of the stream shows where it ends.
struct AskCatbirdRefStream {
  let refs: AskCatbirdPostRefs
  private var consumed = 0
  private var lastConsumed: Character?

  init(refs: AskCatbirdPostRefs) {
    self.refs = refs
  }

  /// The expanded text to append for a new cumulative snapshot of the raw answer.
  mutating func next(_ snapshot: String) -> String {
    let characters = Array(snapshot)
    guard characters.count > consumed else { return "" }
    var end = characters.count
    var start = end
    while start > consumed, characters[start - 1].isASCII, characters[start - 1].isNumber { start -= 1 }
    if start > consumed, characters[start - 1] == "p",
       AskCatbirdPostRefs.opensRef(start - 1 > 0 ? characters[start - 2] : nil) {
      end = start - 1
    }
    return emit(characters, upTo: end)
  }

  /// The expanded text still held back once the stream has ended.
  mutating func finish(_ snapshot: String) -> String {
    let characters = Array(snapshot)
    return emit(characters, upTo: characters.count)
  }

  private mutating func emit(_ characters: [Character], upTo end: Int) -> String {
    guard end > consumed else { return "" }
    let segment = String(characters[consumed..<end])
    let expanded = refs.expandAnswer(segment, precededBy: lastConsumed)
    lastConsumed = characters[end - 1]
    consumed = end
    return expanded
  }
}
