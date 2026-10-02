//
//  VideoCaptionTests.swift
//  CatbirdTests
//
//  Created by Josh LaCalamito on 8/24/26.
//

import Foundation
import Petrel
import Testing
@testable import Catbird

@Suite("Video Caption Validation")
struct VideoCaptionTests {

  @Test("Valid UTF-8 WebVTT file imports and validates successfully")
  func validWebVTTImport() throws {
    let validVTT = """
    WEBVTT

    00:00:00.000 --> 00:00:04.000
    Hello, this is a test caption track.

    00:00:04.500 --> 00:00:08.000
    Testing multi-cue support.
    """

    let lang = LanguageCodeContainer(languageCode: "en")
    let caption = try VideoCaption.validate(
      content: validVTT,
      filename: "captions-en.vtt",
      lang: lang
    )

    #expect(caption.filename == "captions-en.vtt")
    #expect(caption.lang.lang.minimalIdentifier == "en")
    #expect(caption.content == validVTT)
  }

  @Test("Valid WebVTT with UTF-8 BOM is accepted")
  func validWebVTTWithBOM() throws {
    let bomVTT = "\u{FEFF}WEBVTT\n\n00:00:00.000 --> 00:00:02.000\nBOM header test"
    let lang = LanguageCodeContainer(languageCode: "es")

    let caption = try VideoCaption.validate(
      content: bomVTT,
      filename: "captions-es.vtt",
      lang: lang
    )

    #expect(caption.lang.lang.minimalIdentifier == "es")
  }

  @Test("Rejection of file without WEBVTT header")
  func rejectionOfWrongHeader() {
    let invalidVTT = """
    1
    00:00:00.000 --> 00:00:04.000
    This is an SRT-style file, not WebVTT.
    """

    let lang = LanguageCodeContainer(languageCode: "en")
    #expect(throws: VideoCaption.ValidationError.invalidHeader) {
      try VideoCaption.validate(
        content: invalidVTT,
        filename: "wrong.vtt",
        lang: lang
      )
    }
  }

  @Test("Rejection of missing language")
  func rejectionOfMissingLanguage() {
    let validVTT = "WEBVTT\n\n00:00:00.000 --> 00:00:02.000\nNo language"

    #expect(throws: VideoCaption.ValidationError.missingLanguage) {
      try VideoCaption.validate(
        content: validVTT,
        filename: "test.vtt",
        lang: nil
      )
    }
  }

  @Test("Rejection of empty content")
  func rejectionOfEmptyContent() {
    let lang = LanguageCodeContainer(languageCode: "en")
    #expect(throws: VideoCaption.ValidationError.emptyContent) {
      try VideoCaption.validate(
        content: "",
        filename: "empty.vtt",
        lang: lang
      )
    }
  }

  @Test("Rejection of content exceeding 20,000 UTF-8 bytes limit")
  func rejectionOfExceedsByteLimit() {
    let lang = LanguageCodeContainer(languageCode: "en")
    // Generate content that exceeds 20,000 bytes
    let header = "WEBVTT\n\n"
    let repeatedCue = "00:00:00.000 --> 00:00:01.000\nLine of caption text for padding bytes.\n\n"
    let repeatCount = (20_001 / repeatedCue.utf8.count) + 1
    let largeContent = header + String(repeating: repeatedCue, count: repeatCount)
    let byteCount = largeContent.utf8.count

    #expect(byteCount > 20_000)
    #expect(throws: VideoCaption.ValidationError.exceedsByteLimit(actualBytes: byteCount)) {
      try VideoCaption.validate(
        content: largeContent,
        filename: "oversized.vtt",
        lang: lang
      )
    }
  }

  @Test("Rejection of content exceeding 10,000 characters limit")
  func rejectionOfExceedsCharacterLimit() {
    let lang = LanguageCodeContainer(languageCode: "en")
    let header = "WEBVTT\n\n"
    let cue = "00:00:00.000 --> 00:00:01.000\n123456789012345678901234567890\n\n"
    let repeatCount = (10_001 / cue.count) + 1
    let longContent = header + String(repeating: cue, count: repeatCount)
    let charCount = longContent.count

    #expect(charCount > 10_000)
    #expect(throws: VideoCaption.ValidationError.exceedsCharacterLimit(actualCharacters: charCount)) {
      try VideoCaption.validate(
        content: longContent,
        filename: "long.vtt",
        lang: lang
      )
    }
  }

  @Test("VideoCaption Codable serialization and deserialization")
  func videoCaptionCodableRoundTrip() throws {
    let caption = VideoCaption(
      lang: LanguageCodeContainer(languageCode: "ja"),
      filename: "captions-ja.vtt",
      content: "WEBVTT\n\n00:00:00.000 --> 00:00:03.000\nこんにちは世界"
    )

    let encoder = JSONEncoder()
    let data = try encoder.encode(caption)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(VideoCaption.self, from: data)

    #expect(decoded.id == caption.id)
    #expect(decoded.filename == "captions-ja.vtt")
    #expect(decoded.lang.lang.minimalIdentifier == "ja")
    #expect(decoded.content == caption.content)
  }
}
