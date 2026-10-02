import Foundation

enum CapturedMedia {
  case photo(Data)
  case video(URL)
}

enum CameraCaptureMode: Identifiable {
  case photo
  case video

  var id: Int {
    switch self {
    case .photo: 0
    case .video: 1
    }
  }
}

struct CapturedVideoStore: Sendable {
  enum StoreError: Error {
    case applicationGroupUnavailable
    case sourceMissing
    case unmanagedURL
  }

  let managedDirectory: URL

  static func applicationStore() throws -> CapturedVideoStore {
    guard let container = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: "group.blue.catbird.shared"
    ) else {
      throw StoreError.applicationGroupUnavailable
    }
    return CapturedVideoStore(
      managedDirectory: container
        .appendingPathComponent("SharedDrafts", isDirectory: true)
        .appendingPathComponent("CapturedMedia", isDirectory: true)
    )
  }

  func importVideo(from sourceURL: URL) async throws -> URL {
    let directory = managedDirectory
    return try await Task.detached(priority: .userInitiated) {
      let fileManager = FileManager.default
      guard fileManager.fileExists(atPath: sourceURL.path) else {
        throw StoreError.sourceMissing
      }
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      let fileExtension = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
      let destinationURL = directory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(fileExtension)
      try fileManager.copyItem(at: sourceURL, to: destinationURL)
      return destinationURL
    }.value
  }

  func owns(_ url: URL) -> Bool {
    let directoryPath = managedDirectory.standardizedFileURL.path
    let candidatePath = url.standardizedFileURL.path
    return candidatePath == directoryPath || candidatePath.hasPrefix(directoryPath + "/")
  }

  func removeVideoIfOwned(_ url: URL) async throws {
    guard owns(url) else { throw StoreError.unmanagedURL }
    try await Task.detached(priority: .utility) {
      let fileManager = FileManager.default
      if fileManager.fileExists(atPath: url.path) {
        try fileManager.removeItem(at: url)
      }
    }.value
  }
}
