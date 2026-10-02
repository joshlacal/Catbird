import UIKit
import UniformTypeIdentifiers
import OSLog

private let logger = Logger(subsystem: "blue.catbird", category: "ShareExtension")

struct SharedIncomingPayload: Codable {
  let text: String?
  let urls: [String]
  // Prefer file URLs to avoid large payloads; keep images for backward compat
  let imageURLs: [String]
  let images: [Data]? // legacy
  let videoURLs: [String] // File URLs in app group container
}

final class ShareViewController: UIViewController {
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    Task { await processItems() }
  }

  private func finish() {
    extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
  }

  private func userDefaults() -> UserDefaults {
    UserDefaults(suiteName: "group.blue.catbird.shared") ?? .standard
  }

  private func appGroupContainerURL() -> URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.blue.catbird.shared")
  }

  private func sharedDraftsDirectory() -> URL? {
    guard let container = appGroupContainerURL() else { return nil }
    let dir = container.appendingPathComponent("SharedDrafts", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func storeDraft(_ data: Data) {
    let defaults = userDefaults()
    defaults.set(data, forKey: "incoming_shared_draft")
    defaults.synchronize()
  }

  private func decodeURL(_ item: NSSecureCoding?) -> URL? {
    if let url = item as? URL { return url }
    if let str = item as? String { return URL(string: str) }
    return nil
  }

  private func decodeText(_ item: NSSecureCoding?) -> String? {
    if let str = item as? String { return str }
    return nil
  }

  private func decodeImageData(_ provider: NSItemProvider, completion: @escaping (Data?) -> Void) {
    if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
      provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
        completion(data)
      }
    } else {
      completion(nil)
    }
  }

  private func saveImageData(_ data: Data) -> URL? {
    guard let draftsDir = sharedDraftsDirectory() else { return nil }
    let destURL = draftsDir
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("jpg")
    do {
      try data.write(to: destURL, options: .atomic)
      return destURL
    } catch {
      return nil
    }
  }

  private func saveMovie(from provider: NSItemProvider) async -> URL? {
    guard provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier),
          let draftsDir = sharedDraftsDirectory() else { return nil }

    // Destination URL
    let destURL = draftsDir
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("mov")

    // Prefer file representation to avoid loading whole file in memory
    var resultURL: URL?
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { tempURL, _ in
        defer { cont.resume() }
        guard let tempURL else { return }
        do {
          try FileManager.default.copyItem(at: tempURL, to: destURL)
          resultURL = destURL
        } catch {
          // Fallback to data representation below
        }
      }
    }
    if let u = resultURL { return u }

    // Fallback: data representation
    return await withCheckedContinuation { cont in
      provider.loadDataRepresentation(forTypeIdentifier: UTType.movie.identifier) { data, _ in
        guard let data else {
          cont.resume(returning: nil)
          return
        }
        do {
          try data.write(to: destURL, options: .atomic)
          cont.resume(returning: destURL)
        } catch {
          cont.resume(returning: nil)
        }
      }
    }
  }

  private func collectProviders() -> [NSItemProvider] {
    guard let contextItems = extensionContext?.inputItems as? [NSExtensionItem] else {
      return []
    }
    return contextItems.compactMap { $0.attachments }.flatMap { $0 }
  }

  private func loadAll() async -> (String?, [URL], [URL], [URL]) {
    let providers = collectProviders()
    var text: String? = nil
    var urls: [URL] = []
    var imageURLs: [URL] = []
    var videos: [URL] = []

    for provider in providers {
      if text == nil, provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
          provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
            text = self.decodeText(item)
            cont.resume()
          }
        }
      }
      if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
          provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
            if let u = self.decodeURL(item) { urls.append(u) }
            cont.resume()
          }
        }
      }
      if imageURLs.count < 4 && provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
          self.decodeImageData(provider) { data in
            if let d = data, let url = self.saveImageData(d) { imageURLs.append(url) }
            cont.resume()
          }
        }
      }
      if videos.isEmpty && provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
        if let url = await saveMovie(from: provider) {
          videos.append(url)
        }
      }
    }

    return (text, urls, imageURLs, videos)
  }

  private func encodePayload(text: String?, urls: [URL], imageURLs: [URL], videos: [URL]) -> Data? {
    let payload = SharedIncomingPayload(
      text: text,
      urls: urls.map { $0.absoluteString },
      imageURLs: imageURLs.map { $0.absoluteString },
      images: nil,
      videoURLs: videos.map { $0.absoluteString }
    )
    guard let data = try? JSONEncoder().encode(payload) else { return nil }
    
    // Validate payload size (max 1MB to avoid UserDefaults issues)
    let maxSize = 1_024 * 1_024 // 1MB
    guard data.count <= maxSize else {
      logger.warning("SharedDraftImporter: Payload too large (\(data.count) bytes), max is \(maxSize)")
      return nil
    }
    
    return data
  }

  private func notifyContainerApp() {
    // Optionally attempt to open container app via custom URL scheme if configured.
    // If no scheme, silently finish.
    finish()
  }

  private func showErrorAndFinish() {
    finish()
  }

  private func processItems() async {
    let (text, urls, images, videos) = await loadAll()
    if let data = encodePayload(text: text, urls: urls, imageURLs: images, videos: videos) {
      storeDraft(data)
      notifyContainerApp()
    } else {
      showErrorAndFinish()
    }
  }
}
