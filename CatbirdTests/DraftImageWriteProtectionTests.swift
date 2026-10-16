#if os(iOS)
import Foundation
import Testing
@testable import Catbird

@Suite("Draft photo first-write protection")
@MainActor
struct DraftImageWriteProtectionTests {
  @Test("A metadata-only touch failure does not replace an existing file or claim ownership")
  func failedTouchKeepsExistingOwnership() throws {
    let sandbox = try DraftPhotoSandbox()
    defer { sandbox.remove() }
    let bytes = Data("shared content hash".utf8)
    let first = try #require(CodableMediaItem.writeImageData(bytes, directory: sandbox.directory))
    let file = try #require(URL(string: first.urlString))
    let birth = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes([.creationDate: birth], ofItemAtPath: file.path)

    let reused = try #require(CodableMediaItem.writeImageData(
      bytes, directory: sandbox.directory, fileManager: FailingTouchFileManager()
    ))

    #expect(!reused.created, "touch failure cannot transfer a quarantined draft's file to a new composition")
    let actualBirth = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.creationDate] as? Date)
    #expect(abs(actualBirth.timeIntervalSince(birth)) < 1)
    #expect(try Data(contentsOf: file) == bytes)
  }

  @Test("A file that disappeared during touch is recreated and belongs to its new writer")
  func failedTouchRecreatesOnlyIfGone() throws {
    let sandbox = try DraftPhotoSandbox()
    defer { sandbox.remove() }
    let bytes = Data("vanished hash".utf8)
    _ = try #require(CodableMediaItem.writeImageData(bytes, directory: sandbox.directory))

    let replacement = try #require(CodableMediaItem.writeImageData(
      bytes, directory: sandbox.directory, fileManager: FailingTouchFileManager(removesFile: true)
    ))

    #expect(replacement.created)
    #expect(try Data(contentsOf: #require(URL(string: replacement.urlString))) == bytes)
  }

  @Test("An unknown first-write date is retained when a lost-row fence applies")
  func unknownBirthIsProtected() throws {
    let sandbox = try DraftPhotoSandbox()
    defer { sandbox.remove() }
    let file = try sandbox.managedFile(modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
    var janitor = sandbox.janitor()
    janitor.fileManager = UnknownBirthFileManager()

    let outcome = janitor.removeUnreferenced(
      [file.absoluteString], eligibleModificationDates: Date.distantPast..<Date(),
      createdAfter: Date(timeIntervalSince1970: 1_600_000_000)
    )

    #expect(DraftPhotoSandbox.exists(file))
    #expect(outcome.removed.isEmpty && outcome.skippedByDate == [file.absoluteString])
  }
}

private final class FailingTouchFileManager: FileManager, @unchecked Sendable {
  let removesFile: Bool
  init(removesFile: Bool = false) { self.removesFile = removesFile; super.init() }
  override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
    if removesFile { try FileManager.default.removeItem(atPath: path) }
    throw CocoaError(removesFile ? .fileNoSuchFile : .fileWriteNoPermission)
  }
}

private final class UnknownBirthFileManager: FileManager, @unchecked Sendable {
  override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
    var attributes = try super.attributesOfItem(atPath: path)
    attributes.removeValue(forKey: .creationDate)
    return attributes
  }
}
#endif
