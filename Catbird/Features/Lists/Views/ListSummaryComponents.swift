import NukeUI
import Petrel
import SwiftUI

// MARK: - Purpose Styling

/// Shared icon, tint, and labels for each list purpose so every list surface reads the same.
extension AppBskyGraphDefs.ListPurpose {
  var symbolName: String {
    switch self {
    case .appbskygraphdefscuratelist:
      return "person.2.fill"
    case .appbskygraphdefsmodlist:
      return "shield.lefthalf.filled"
    case .appbskygraphdefsreferencelist:
      return "person.crop.rectangle.stack.fill"
    default:
      return "list.bullet"
    }
  }

  var tint: Color {
    switch self {
    case .appbskygraphdefscuratelist:
      return .blue
    case .appbskygraphdefsmodlist:
      return .red
    case .appbskygraphdefsreferencelist:
      return .purple
    default:
      return .gray
    }
  }

  /// Short label for badges, such as "Curated".
  var shortLabel: String {
    switch self {
    case .appbskygraphdefscuratelist:
      return String(localized: "Curated")
    case .appbskygraphdefsmodlist:
      return String(localized: "Moderation")
    case .appbskygraphdefsreferencelist:
      return String(localized: "Reference")
    default:
      return String(localized: "List")
    }
  }

  /// Label for row subtitles, such as "Curated list".
  var listKindLabel: String {
    switch self {
    case .appbskygraphdefscuratelist:
      return String(localized: "Curated list")
    case .appbskygraphdefsmodlist:
      return String(localized: "Moderation list")
    case .appbskygraphdefsreferencelist:
      return String(localized: "Starter pack list")
    default:
      return String(localized: "List")
    }
  }
}

// MARK: - List Avatar

/// A list's avatar, or a purpose-tinted placeholder when it has none.
struct ListAvatarView: View {
  let list: AppBskyGraphDefs.ListView
  var size: CGFloat = 48

  private var cornerRadius: CGFloat { size * 0.24 }

  var body: some View {
    LazyImage(url: list.finalAvatarURL()) { state in
      if let image = state.image {
        image
          .resizable()
          .scaledToFill()
      } else {
        placeholder
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
    }
    .accessibilityHidden(true)
  }

  private var placeholder: some View {
    ZStack {
      LinearGradient(
        colors: [list.purpose.tint.opacity(0.85), list.purpose.tint.opacity(0.6)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      Image(systemName: list.purpose.symbolName)
        .font(.system(size: size * 0.4, weight: .semibold))
        .foregroundStyle(.white)
    }
  }
}

// MARK: - Purpose Badge

/// A small capsule naming the list's purpose.
struct ListPurposeBadge: View {
  let purpose: AppBskyGraphDefs.ListPurpose

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: purpose.symbolName)
        .imageScale(.small)
      Text(purpose.shortLabel)
    }
    .font(.caption2.weight(.semibold))
    .foregroundStyle(purpose.tint)
    .padding(.horizontal, 7)
    .padding(.vertical, 3)
    .background(purpose.tint.opacity(0.14), in: Capsule())
  }
}

// MARK: - List Summary Row

/// The standard row for a list: avatar, name, kind and size, and a short description.
struct ListSummaryRow: View {
  let list: AppBskyGraphDefs.ListView
  /// Shows "by @handle" in the subtitle, for lists that aren't the viewer's own.
  var showsCreator: Bool = false
  var showsDisclosureIndicator: Bool = true

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      ListAvatarView(list: list, size: 48)

      VStack(alignment: .leading, spacing: 2) {
        Text(list.name)
          .appFont(AppTextRole.body)
          .fontWeight(.semibold)
          .foregroundStyle(.primary)
          .lineLimit(1)

        Text(subtitle)
          .appFont(AppTextRole.footnote)
          .foregroundStyle(.secondary)
          .lineLimit(1)

        if let description = trimmedDescription {
          Text(description)
            .appFont(AppTextRole.footnote)
            .foregroundStyle(.primary.opacity(0.85))
            .lineLimit(2)
            .padding(.top, 2)
        }
      }

      Spacer(minLength: 8)

      if showsDisclosureIndicator {
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
    }
    .padding(.vertical, 6)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }

  private var subtitle: String {
    let count = list.listItemCount ?? 0
    let members = String(AttributedString(localized: "^[\(count) member](inflect: true)").characters)
    var parts = [list.purpose.listKindLabel, members]
    if showsCreator {
      parts.append(String(localized: "by @\(list.creator.handle.description)"))
    }
    return parts.joined(separator: " · ")
  }

  private var trimmedDescription: String? {
    guard let description = list.description?.trimmingCharacters(in: .whitespacesAndNewlines),
          !description.isEmpty
    else { return nil }
    return description
  }
}

// MARK: - Preview

private func previewList(
  name: String,
  purpose: AppBskyGraphDefs.ListPurpose,
  description: String?,
  count: Int
) -> AppBskyGraphDefs.ListView? {
  guard let did = try? DID(didString: "did:plc:previewcreator"),
        let handle = try? Handle(handleString: "alice.bsky.social"),
        let uri = try? ATProtocolURI(uriString: "at://did:plc:previewcreator/app.bsky.graph.list/\(name.count)")
  else { return nil }
  return AppBskyGraphDefs.ListView(
    uri: uri,
    cid: CID.fromDAGCBOR(Data(name.utf8)),
    creator: AppBskyActorDefs.ProfileView(did: did, handle: handle),
    name: name,
    purpose: purpose,
    description: description,
    listItemCount: count,
    indexedAt: ATProtocolDate(date: Date())
  )
}

#Preview("List rows") {
  let lists = [
    previewList(name: "Science Writers", purpose: .appbskygraphdefscuratelist, description: "Journalists and researchers who write about space, climate, and biology.", count: 42),
    previewList(name: "Spam Accounts", purpose: .appbskygraphdefsmodlist, description: nil, count: 1),
    previewList(name: "Swift Developers Starter Pack", purpose: .appbskygraphdefsreferencelist, description: "People building apps with Swift and SwiftUI.", count: 18),
  ].compactMap { $0 }

  List {
    if let first = lists.first {
      Section {
        HStack(spacing: 14) {
          ListAvatarView(list: first, size: 64)
          VStack(alignment: .leading, spacing: 6) {
            Text(first.name).font(.title3.bold())
            ListPurposeBadge(purpose: first.purpose)
          }
        }
      }
    }
    Section("People Lists") {
      ForEach(lists, id: \.uri) { list in
        ListSummaryRow(list: list, showsCreator: true)
      }
    }
  }
  .listStyle(.insetGrouped)
  .previewWithMockEnvironment()
}
