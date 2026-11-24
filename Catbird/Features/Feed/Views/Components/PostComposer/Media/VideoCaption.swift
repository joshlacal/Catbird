//
//  VideoCaption.swift
//  Catbird
//
//  Created by Josh LaCalamito on 8/24/26.
//

import Foundation
import Petrel

/// Model representing a subtitle/caption track (.vtt) attached to a video embed.
public struct VideoCaption: Codable, Hashable, Sendable, Identifiable {
  public let id: UUID
  public let lang: LanguageCodeContainer
  public let filename: String
  public let content: String

  /// Max raw UTF-8 byte size for caption upload (20 KB).
  public static let maxByteSize: Int = 20_000

  /// Max character count for remote draft persistence (10,000 characters).
  public static let maxCharacterLength: Int = 10_000

  public init(
    id: UUID = UUID(),
    lang: LanguageCodeContainer,
    filename: String,
    content: String
  ) {
    self.id = id
    self.lang = lang
    self.filename = filename
    self.content = content
  }

  /// Caption validation errors.
  public enum ValidationError: LocalizedError, Equatable {
    case emptyContent
    case invalidEncoding
    case invalidHeader
    case missingLanguage
    case exceedsByteLimit(actualBytes: Int)
    case exceedsCharacterLimit(actualCharacters: Int)

    public var errorDescription: String? {
      switch self {
      case .emptyContent:
        return String(localized: "Caption file is empty.", comment: "Validation error when imported WebVTT caption file is empty")
      case .invalidEncoding:
        return String(localized: "Caption file could not be read as valid UTF-8 text.", comment: "Validation error when WebVTT caption file is not valid UTF-8")
      case .invalidHeader:
        return String(localized: "Invalid WebVTT file. The file must start with 'WEBVTT'.", comment: "Validation error when caption file lacks required WEBVTT header")
      case .missingLanguage:
        return String(localized: "Please select a language for the captions.", comment: "Validation error when no caption language is selected")
      case .exceedsByteLimit(let actualBytes):
        return String(
          localized: "Caption file size (\(actualBytes) bytes) exceeds the maximum limit of \(VideoCaption.maxByteSize) bytes.",
          comment: "Validation error when WebVTT file exceeds byte limit; first variable is actual bytes, second is maximum bytes"
        )
      case .exceedsCharacterLimit(let actualCharacters):
        return String(
          localized: "Caption text length (\(actualCharacters) characters) exceeds the maximum draft limit of \(VideoCaption.maxCharacterLength) characters.",
          comment: "Validation error when WebVTT text exceeds character limit; first variable is actual characters, second is maximum characters"
        )
      }
    }
  }

  /// Validates whether the given raw string starts with a compliant WebVTT header.
  public static func isValidWebVTTHeader(_ text: String) -> Bool {
    var content = text
    // Strip leading UTF-8 BOM if present
    if content.hasPrefix("\u{FEFF}") {
      content.removeFirst()
    }
    content = content.trimmingCharacters(in: .whitespacesAndNewlines.subtracting(.newlines))

    guard content.hasPrefix("WEBVTT") else {
      return false
    }

    let remainder = content.dropFirst(6)
    if remainder.isEmpty {
      return true
    }
    guard let firstChar = remainder.first else {
      return true
    }
    // WebVTT spec requires WEBVTT to be followed by space, tab, newline, or EOF
    return firstChar == "\n" || firstChar == "\r" || firstChar == " " || firstChar == "\t"
  }

  /// Validate and create a VideoCaption from raw UTF-8 Data.
  public static func validate(
    data: Data,
    filename: String,
    lang: LanguageCodeContainer?
  ) throws -> VideoCaption {
    guard !data.isEmpty else {
      throw ValidationError.emptyContent
    }

    guard data.count <= maxByteSize else {
      throw ValidationError.exceedsByteLimit(actualBytes: data.count)
    }

    guard let text = String(data: data, encoding: .utf8) else {
      throw ValidationError.invalidEncoding
    }

    return try validate(content: text, filename: filename, lang: lang)
  }

  /// Validate and create a VideoCaption from a text string.
  public static func validate(
    content: String,
    filename: String,
    lang: LanguageCodeContainer?
  ) throws -> VideoCaption {
    guard !content.isEmpty else {
      throw ValidationError.emptyContent
    }

    guard let lang = lang else {
      throw ValidationError.missingLanguage
    }

    guard let utf8Data = content.data(using: .utf8) else {
      throw ValidationError.invalidEncoding
    }

    guard utf8Data.count <= maxByteSize else {
      throw ValidationError.exceedsByteLimit(actualBytes: utf8Data.count)
    }

    guard content.count <= maxCharacterLength else {
      throw ValidationError.exceedsCharacterLimit(actualCharacters: content.count)
    }

    guard isValidWebVTTHeader(content) else {
      throw ValidationError.invalidHeader
    }

    return VideoCaption(
      lang: lang,
      filename: filename,
      content: content
    )
  }
}
