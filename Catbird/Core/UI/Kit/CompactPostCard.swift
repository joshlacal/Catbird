//
//  CompactPostCard.swift
//  Catbird
//
//  Small post summary: avatar, name, handle, clamped body, optional thumbnail
//  and footer slot. Plain-value API so previews and non-feed surfaces can use it.
//

import Nuke
import NukeUI
import Petrel
import SwiftUI

struct CompactPostCard<Footer: View>: View {
  let avatarURL: URL?
  let displayName: String
  let handle: String
  let text: String
  var imageURL: URL?
  var did: String?
  var lineLimit = 3
  /// Draw `catbirdCard(.embed)` chrome. Turn off when the host supplies its own.
  var showsChrome = true
  @ViewBuilder var footer: () -> Footer

  @Environment(\.displayScale) private var displayScale
  @Environment(\.catbirdTheme) private var theme

  var body: some View {
    let content = HStack(alignment: .top, spacing: Space.md) {
      CatbirdAvatar(
        url: avatarURL,
        displayName: displayName,
        handle: handle,
        size: AvatarSize.sm,
        did: did
      )
      VStack(alignment: .leading, spacing: Space.xs) {
        HStack(spacing: Space.xs) {
          EmbeddedAuthorNameView(name: displayName)
            .appFont(AppTextRole.subheadline.weight(.semibold))
            .foregroundStyle(theme.text(.primary))
            .lineLimit(1)
          Text(verbatim: "@\(handle)")
            .appFont(AppTextRole.footnote)
            .foregroundStyle(theme.text(.secondary))
            .lineLimit(1)
        }
        if !text.isEmpty {
          Text(text)
            .appFont(AppTextRole.subheadline)
            .foregroundStyle(theme.text(.primary))
            .lineLimit(lineLimit)
            .multilineTextAlignment(.leading)
        }
        footer()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if let imageURL {
        LazyImage(request: CatbirdAvatar.resizedRequest(
          for: imageURL, sizeInPoints: AvatarSize.xl, displayScale: displayScale)
        ) { state in
          if let image = state.image {
            image.resizable().scaledToFill()
          } else {
            theme.surface(.elevated)
          }
        }
        .pipeline(ImageLoadingManager.shared.pipeline)
        .frame(width: AvatarSize.xl, height: AvatarSize.xl)
        .catbirdClip(.sm)
        .accessibilityHidden(true)
      }
    }
    .padding(Space.md)
    .accessibilityElement(children: .combine)
    if showsChrome {
      content.catbirdCard(.embed)
    } else {
      content
    }
  }
}

extension CompactPostCard where Footer == EmptyView {
  init(
    avatarURL: URL?, displayName: String, handle: String, text: String, imageURL: URL? = nil,
    did: String? = nil, lineLimit: Int = 3, showsChrome: Bool = true
  ) {
    self.init(
      avatarURL: avatarURL, displayName: displayName, handle: handle, text: text,
      imageURL: imageURL, did: did, lineLimit: lineLimit, showsChrome: showsChrome,
      footer: { EmptyView() })
  }
}

extension CompactPostCard where Footer == EmptyView {
  /// Build from a Petrel PostView: author avatar/name/handle, record text, first image thumb.
  init(post: AppBskyFeedDefs.PostView, lineLimit: Int = 3, showsChrome: Bool = true) {
    var body = ""
    if case .knownType(let value) = post.record, let record = value as? AppBskyFeedPost {
      body = record.text
    }
    var thumb: URL?
    if case .appBskyEmbedImagesView(let images) = post.embed, let first = images.images.first {
      thumb = URL(string: first.thumb.uriString())
    }
    self.init(
      avatarURL: post.author.avatar.flatMap { URL(string: $0.uriString()) },
      displayName: post.author.displayName ?? post.author.handle.description,
      handle: post.author.handle.description, text: body, imageURL: thumb,
      did: post.author.did.didString(), lineLimit: lineLimit, showsChrome: showsChrome)
  }
}

#Preview("Compact post card") {
  VStack(spacing: Space.md) {
    CompactPostCard(
      avatarURL: nil, displayName: "Catbird", handle: "catbird.blue",
      text: "A compact post summary that clamps long text after a few lines so rows stay even and scannable in lists.")
    CompactPostCard(
      avatarURL: nil, displayName: "Catbird", handle: "catbird.blue", text: "With a footer",
      footer: { Text("2h").appFont(AppTextRole.caption).foregroundStyle(.secondary) })
  }
  .padding(Space.screenMargin)
}
