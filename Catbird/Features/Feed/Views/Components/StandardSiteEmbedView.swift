import SwiftUI
import NukeUI
import Petrel

/// System labels are unconditional; other labels retain the existing preference policy.
struct ExternalEmbedLabelGate<Content: View>: View {
  let labels: [ComAtprotoLabelDefs.Label]?
  @ViewBuilder var content: () -> Content
  @State private var revealed = false

  var body: some View {
    switch ExternalEmbedSystemLabelVisibility.resolve(labels) {
    case .hide:
      Label("Link hidden by moderation", systemImage: "eye.slash")
        .appFont(AppTextRole.subheadline)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    case .warn where !revealed:
      VStack(alignment: .leading, spacing: 8) {
        Label("Link warning", systemImage: "exclamationmark.triangle")
        Button("Show link preview") { revealed = true }
          .frame(minHeight: 44)
      }
      .appFont(AppTextRole.subheadline)
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    default:
      ContentLabelManager(labels: labels, contentType: "media") { content() }
    }
  }
}

struct StandardSiteEmbedView: View {
  let card: StandardSiteCard
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if !card.isPublicationOnly {
        Link(destination: card.articleURL) {
          article
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Open article: \(card.external.title)"))
        .accessibilityValue(articleAccessibilityValue)
      }
      if let publicationURL = card.publicationURL {
        if !card.isPublicationOnly { Divider() }
        publication(url: publicationURL)
      } else {
        metadata.padding([.horizontal, .bottom], 12)
      }
    }
    .feedEmbedCardStyle()
    .fixedSize(horizontal: false, vertical: true)
  }

  private var article: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let thumbnailURL = card.thumbnailURL {
        // The image and its loading/error state occupy identical geometry.
        Rectangle()
          .fill(Color.gray.opacity(0.12))
          .aspectRatio(1.91, contentMode: .fit)
          .overlay {
            LazyImage(url: thumbnailURL) { state in
              if let image = state.image {
                image.resizable().scaledToFill()
              }
            }
          }
          .clipped()
          .accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: 6) {
        if !card.external.title.isEmpty {
          Text(card.external.title)
            .appFont(AppTextRole.headline)
            .foregroundStyle(.primary)
            .lineLimit(3)
        }
        if !card.external.description.isEmpty {
          Text(card.external.description)
            .appFont(AppTextRole.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(card.thumbnailURL == nil ? 4 : 2)
        }
        HStack(spacing: 8) {
          if let date = card.external.createdAt?.date {
            Text(date, format: .dateTime.month(.abbreviated).day().year())
          }
          if let minutes = card.readingMinutes {
            Text("\(minutes) min read")
          }
        }
        .appFont(AppTextRole.caption)
        .foregroundStyle(.secondary)
      }
      .padding(12)
    }
  }

  private func publication(url: URL) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Link(destination: url) {
        HStack(alignment: .top, spacing: 10) {
          publicationIcon
          VStack(alignment: .leading, spacing: 4) {
            Text(card.publicationTitle)
              .appFont(AppTextRole.headline)
              .foregroundStyle(.primary)
              .lineLimit(2)
            if card.isPublicationOnly, !card.external.description.isEmpty {
              Text(card.external.description)
                .appFont(AppTextRole.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(4)
            }
            metadata
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(Text("Open publication: \(card.publicationTitle)"))
      .accessibilityValue(publicationAccessibilityValue)

      Link(destination: url) {
        Group {
          if let publisher = card.publisher {
            Text("Subscribe on \(publisher)")
          } else {
            Text("View publication")
          }
        }
        .appFont(AppTextRole.subheadline)
        .fontWeight(.semibold)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.horizontal, 10)
        .foregroundStyle(buttonForeground)
        .background(buttonBackground, in: RoundedRectangle(cornerRadius: 8))
      }
      .buttonStyle(.plain)
      .accessibilityLabel(Text(card.publisher.map { "Subscribe to \(card.publicationTitle) on \($0)" }
        ?? "View publication: \(card.publicationTitle)"))
    }
    .padding(12)
  }

  private var publicationIcon: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.15))
      Text(String(card.publicationTitle.prefix(1)).uppercased())
        .appFont(AppTextRole.title2)
        .foregroundStyle(.secondary)
      if let iconURL = card.iconURL {
        LazyImage(url: iconURL) { state in
          if let image = state.image { image.resizable().scaledToFill() }
        }
      }
    }
    .frame(width: 44, height: 44)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .accessibilityHidden(true)
  }

  private var metadata: some View {
    VStack(alignment: .leading, spacing: 2) {
      if let handle = card.authorHandle { Text("by @\(handle)") }
      if let domain = card.displayDomain { Text(domain) }
    }
    .appFont(AppTextRole.caption)
    .foregroundStyle(.secondary)
    .lineLimit(1)
  }

  private var buttonBackground: Color {
    guard colorSchemeContrast != .increased, let colors = card.buttonColors else {
      return Color.primary.opacity(0.08)
    }
    return color(colors.background)
  }

  private var articleAccessibilityValue: Text {
    var value = Text(card.external.description)
    if let date = card.external.createdAt?.date {
      value = value + Text(". ") + Text(date, format: .dateTime.month(.abbreviated).day().year())
    }
    if let minutes = card.readingMinutes { value = value + Text(". \(minutes) min read") }
    return value
  }

  private var publicationAccessibilityValue: Text {
    var value = Text(card.isPublicationOnly ? card.external.description : "")
    if let handle = card.authorHandle { value = value + Text(". by @\(handle)") }
    if let domain = card.displayDomain { value = value + Text(". \(domain)") }
    return value
  }

  private var buttonForeground: Color {
    guard colorSchemeContrast != .increased, let colors = card.buttonColors else { return .primary }
    return color(colors.foreground)
  }

  private func color(_ value: AppBskyEmbedExternal.ColorRGB) -> Color {
    Color(.sRGB, red: Double(value.r) / 255, green: Double(value.g) / 255, blue: Double(value.b) / 255, opacity: 1)
  }
}
