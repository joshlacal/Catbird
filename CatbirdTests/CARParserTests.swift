import Testing
import Foundation
@testable import Catbird

@Suite("CAR Parser Tests")
struct CARParserTests {

  // MARK: - CARParsingError Tests

  @Test("CARParsingError.invalidCARFormat provides descriptive message")
  func testInvalidCARFormatError() {
    let error = CARParsingError.invalidCARFormat("Missing header")
    #expect(error.errorDescription?.contains("Invalid CAR format") == true)
    #expect(error.errorDescription?.contains("Missing header") == true)
  }

  @Test("CARParsingError.invalidCBORData provides descriptive message")
  func testInvalidCBORDataError() {
    let error = CARParsingError.invalidCBORData("Truncated data")
    #expect(error.errorDescription?.contains("Invalid CBOR data") == true)
    #expect(error.errorDescription?.contains("Truncated data") == true)
  }

  @Test("CARParsingError.unsupportedRecordType provides descriptive message")
  func testUnsupportedRecordTypeError() {
    let error = CARParsingError.unsupportedRecordType("app.bsky.unknown.type")
    #expect(error.errorDescription?.contains("Unsupported record type") == true)
    #expect(error.errorDescription?.contains("app.bsky.unknown.type") == true)
  }

  // MARK: - BackupStatus Codable Round-trip

  @Test("BackupStatus encodes and decodes correctly", arguments: BackupStatus.allCases)
  func testStatusCodable(status: BackupStatus) throws {
    let encoder = JSONEncoder()
    let data = try encoder.encode(status)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(BackupStatus.self, from: data)

    #expect(decoded == status)
  }

  @Test("BackupStatus raw values are stable strings")
  func testStatusRawValues() {
    #expect(BackupStatus.inProgress.rawValue == "in_progress")
    #expect(BackupStatus.completed.rawValue == "completed")
    #expect(BackupStatus.failed.rawValue == "failed")
    #expect(BackupStatus.verifying.rawValue == "verifying")
    #expect(BackupStatus.verified.rawValue == "verified")
    #expect(BackupStatus.corrupted.rawValue == "corrupted")
  }

  // MARK: - String Sanitization Tests

  @Test("sanitizedForDisplay strips null bytes")
  func testSanitizeNullBytes() {
    let input = "Hello\0World"
    let result = input.sanitizedForDisplay()
    #expect(!result.contains("\0"))
  }

  @Test("sanitizedForDisplay strips Object Replacement Character")
  func testSanitizeObjectReplacementChar() {
    let input = "Hello\u{FFFC}World"
    let result = input.sanitizedForDisplay()
    #expect(!result.contains("\u{FFFC}"))
  }

  @Test("sanitizedForDisplay handles empty string")
  func testSanitizeEmpty() {
    let result = "".sanitizedForDisplay()
    #expect(result == "")
  }

  @Test("sanitizedForDisplay preserves normal text")
  func testSanitizeNormalText() {
    let input = "Hello, World!"
    let result = input.sanitizedForDisplay()
    #expect(result == "Hello, World!")
  }

  @Test("sanitizedForDisplay truncates very long strings")
  func testSanitizeTruncation() {
    let input = String(repeating: "a", count: 20000)
    let result = input.sanitizedForDisplay()
    #expect(result.count <= 10003) // 10000 + "..."
  }

  @Test("containsProblematicCharacters detects null bytes")
  func testProblematicNull() {
    #expect("Hello\0".containsProblematicCharacters == true)
  }

  @Test("containsProblematicCharacters returns false for clean text")
  func testProblematicClean() {
    #expect("Hello, World!".containsProblematicCharacters == false)
  }

  // MARK: - Data Extension Tests

  @Test("Data isValidUTF8 returns true for valid UTF-8")
  func testValidUTF8() {
    let data = "Hello".data(using: .utf8)!
    #expect(data.isValidUTF8() == true)
  }

  @Test("Data toSanitizedString converts valid data")
  func testToSanitizedString() {
    let data = "Hello, World!".data(using: .utf8)!
    let result = data.toSanitizedString()
    #expect(result == "Hello, World!")
  }
}
