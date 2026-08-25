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
  @State private var platformImage: PlatformImage?
  @State private var isLoading: Bool = false
  @State private var errorMessage: String?

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
    self.cid = (try? CID.parse(cidString)) ?? CID.fromBlob(Data(cidString.utf8))
  }

  /// Convenience initializer with non-optional author DID.
  init?(
    viewImage: AppBskyEmbedImages.ViewImage,
    circle: CircleSummary,
    authorDID: DID,
    contentMode: ContentMode = .fill,
    cornerRadius: CGFloat = 10,
    shouldBlur: Bool = false
  ) {
    self.init(
      viewImage: viewImage,
      circle: circle,
      authorDID: Optional(authorDID),
      contentMode: contentMode,
      cornerRadius: cornerRadius,
      shouldBlur: shouldBlur
    )
  }

  var body: some View {
    ZStack {
      if let platformImage {
        imageView(platformImage)
      } else if isLoading {
        loadingView
      } else if errorMessage != nil {
        errorPlaceholderView
      } else {
        loadingView
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    .task(id: "\(space.description)|\(authorDID.description)|\(cid.description)") {
      await loadImage()
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

  private func loadImage() async {
    guard platformImage == nil else { return }
    isLoading = true
    errorMessage = nil

    do {
      let image = try await CircleMediaLoader.shared.image(
        accountDID: appState.userDID,
        space: space,
        authorDID: authorDID,
        cid: cid,
        service: appState.circleService
      )
      self.platformImage = image
      self.isLoading = false
    } catch {
      self.errorMessage = error.localizedDescription
      self.isLoading = false
    }
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
