//
//  CircleMediaView.swift
//  Catbird
//

import SwiftUI
import Petrel
import PetrelCatbird

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// SwiftUI view that renders authenticated Circle images via `CircleMediaLoader`.
///
/// Used exclusively for Circle image embeds and galleries. Public Nuke/CDN
/// loading remains unchanged for public feeds.
struct CircleMediaView: View {
  let space: SpaceRef
  let authorDID: DID
  let cid: CID
  let altText: String?
  let aspectRatio: CGFloat?
  let contentMode: ContentMode
  let cornerRadius: CGFloat
  let shouldBlur: Bool

  @Environment(AppState.self) private var appState
  @Environment(\.displayScale) private var displayScale: CGFloat
  @State private var platformImage: PlatformImage?
  @State private var renderedAccountDID: String?
  @State private var hasError = false
  @State private var targetBucket: Int? = nil
  @State private var renderedBucket: Int = 0
  @State private var lifecycleGeneration = 0
  @State private var isRetired = false

  private static let pixelBuckets = [120, 240, 360, 480, 720, 960, 1280, 1920]

  init(
    space: SpaceRef,
    authorDID: DID,
    cid: CID,
    altText: String? = nil,
    aspectRatio: CGFloat? = nil,
    contentMode: ContentMode = .fill,
    cornerRadius: CGFloat = 10,
    shouldBlur: Bool = false
  ) {
    self.space = space
    self.authorDID = authorDID
    self.cid = cid
    self.altText = altText
    self.aspectRatio = aspectRatio
    self.contentMode = contentMode
    self.cornerRadius = cornerRadius
    self.shouldBlur = shouldBlur
  }

  /// Convenience initializer extracting Space and CID from ViewImage and CircleSummary.
  init?(
    viewImage: AppBskyEmbedImages.ViewImage,
    circle: CircleSummary,
    authorDID: DID?,
    contentMode: ContentMode = .fill,
    cornerRadius: CGFloat = 10,
    shouldBlur: Bool = false
  ) {
    guard let authorDID else { return nil }
    self.space = circle.uri
    self.authorDID = authorDID
    self.altText = viewImage.alt.isEmpty ? nil : viewImage.alt
    self.contentMode = contentMode
    self.cornerRadius = cornerRadius
    self.shouldBlur = shouldBlur

    if let ratio = viewImage.aspectRatio, ratio.height > 0 {
      self.aspectRatio = CGFloat(ratio.width) / CGFloat(ratio.height)
    } else {
      self.aspectRatio = nil
    }

    // Extract CID from thumb or fullsize URI
    let cidString = Self.extractCID(from: viewImage.fullsize.uriString()) ?? Self.extractCID(from: viewImage.thumb.uriString())
    guard let cidString else { return nil }
    guard let cid = try? CID.parse(cidString) else { return nil }
    self.cid = cid
  }

  var body: some View {
    ZStack {
      if !appState.circleSupportsImages || isRetired {
        errorPlaceholderView
      } else if let platformImage, renderedAccountDID == appState.userDID {
        imageView(platformImage)
      } else if hasError {
        errorPlaceholderView
      } else {
        loadingView
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    .onChange(of: appState.userDID) { _, _ in
      lifecycleGeneration += 1
      platformImage = nil
      renderedAccountDID = nil
      renderedBucket = 0
      hasError = false
    }
    .onChange(of: appState.circleSupportsImages) { _, supported in
      if !supported { lifecycleGeneration += 1; platformImage = nil; renderedBucket = 0 }
    }
    .onReceive(NotificationCenter.default.publisher(for: .circleDeleted)) { notification in
      guard notification.userInfo?["accountDID"] as? String == appState.userDID,
            notification.userInfo?["spaceURI"] as? String == space.uriString() else { return }
      lifecycleGeneration += 1
      isRetired = true
      platformImage = nil
      hasError = true
    }
    .onReceive(NotificationCenter.default.publisher(for: .circleAccountInvalidated)) { notification in
      guard notification.userInfo?["accountDID"] as? String == appState.userDID else { return }
      lifecycleGeneration += 1
      platformImage = nil
      hasError = true
    }
    .onGeometryChange(for: CGSize.self) { proxy in
      proxy.size
    } action: { newSize in
      guard newSize.width > 0, newSize.height > 0 else { return }
      let maxDim = max(newSize.width, newSize.height) * displayScale
      let bucket = Self.bucket(for: maxDim)
      if let current = targetBucket {
        if bucket > current {
          targetBucket = bucket
        }
      } else {
        targetBucket = bucket
      }
    }
    .task(id: "\(appState.userDID)|\(appState.circleSupportsImages)|\(space.description)|\(authorDID.description)|\(cid.description)|\(targetBucket?.description ?? "nil")") {
      guard let targetBucket else { return }
      await loadImage(bucket: targetBucket)
    }
  }

  @ViewBuilder
  private func imageView(_ img: PlatformImage) -> some View {
    #if os(iOS)
    Image(uiImage: img)
      .resizable()
      .aspectRatio(aspectRatio, contentMode: contentMode)
      .accessibilityLabel(altText ?? "Circle image")
      .accessibilityAddTraits(.isImage)
    #elseif os(macOS)
    Image(nsImage: img)
      .resizable()
      .aspectRatio(aspectRatio, contentMode: contentMode)
      .accessibilityLabel(altText ?? "Circle image")
      .accessibilityAddTraits(.isImage)
    #endif
  }

  private var loadingView: some View {
    ZStack {
      RoundedRectangle(cornerRadius: cornerRadius)
        .fill(Color.secondary.opacity(0.1))
      ProgressView()
        .scaleEffect(0.8)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var errorPlaceholderView: some View {
    ZStack {
      RoundedRectangle(cornerRadius: cornerRadius)
        .fill(Color.secondary.opacity(0.1))
      Image(systemName: "photo")
        .font(.title2)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func loadImage(bucket: Int) async {
    guard appState.circleSupportsImages, !isRetired else { return }
    let requestGeneration = lifecycleGeneration
    let accountDID = appState.userDID
    guard platformImage == nil || renderedAccountDID != accountDID || bucket > renderedBucket else { return }
    hasError = false

    do {
      let image = try await CircleMediaLoader.shared.image(
        accountDID: accountDID,
        space: space,
        authorDID: authorDID,
        cid: cid,
        targetBucket: bucket,
        service: appState.circleService
      )
      guard !Task.isCancelled, lifecycleGeneration == requestGeneration, appState.userDID == accountDID else { return }
      self.renderedAccountDID = accountDID
      self.platformImage = image
      self.renderedBucket = bucket
    } catch {
      guard !Task.isCancelled, lifecycleGeneration == requestGeneration, appState.userDID == accountDID else { return }
      if platformImage == nil {
        hasError = true
      }
    }
  }

  static func bucket(for maxPixelDimension: CGFloat) -> Int {
    guard maxPixelDimension > 0 else { return 360 }
    let target = Int(ceil(maxPixelDimension))
    return pixelBuckets.first(where: { $0 >= target }) ?? max(target, 1920)
  }

  private static func extractCID(from uriString: String) -> String? {
    if uriString.hasPrefix("cid:") {
      return String(uriString.dropFirst(4))
    }
    if let url = URL(string: uriString),
       let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
      if let cidParam = components.queryItems?.first(where: { $0.name == "cid" })?.value {
        return cidParam
      }
      let lastComponent = url.lastPathComponent
      if lastComponent.hasPrefix("baf") || lastComponent.hasPrefix("zd") {
        return lastComponent
      }
    }
    if uriString.hasPrefix("baf") || uriString.hasPrefix("zd") {
      return uriString
    }
    return nil
  }
}
