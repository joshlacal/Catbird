import Petrel
import SwiftUI

/// Compact `+` / `✓` / `pin` pill button for zero-friction rapid-fire subscribing on Storefront
/// and Search rows. Uses immediate optimistic UI + haptic feedback without blocking alerts.
struct FeedStorefrontQuickAddButton: View {
  @Environment(AppState.self) private var appState
  let feed: AppBskyFeedDefs.GeneratorView
  var onOpen: (() -> Void)?

  @State private var optimisticMembership: FeedLibraryMembership?

  private var actions: FeedLibraryActions { appState.feedLibraryActions }
  private var actualMembership: FeedLibraryMembership { actions.membership(for: feed.uri) }
  private var displayedMembership: FeedLibraryMembership { optimisticMembership ?? actualMembership }

  var body: some View {
    Group {
      if displayedMembership == .absent {
        Button(action: quickAdd) {
          HStack(spacing: 4) {
            Image(systemName: "plus")
              .font(.footnote.weight(.bold))
            Text("Add")
              .font(.footnote.weight(.bold))
          }
          .foregroundStyle(Color.accentColor)
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(Color.accentColor.opacity(0.14), in: Capsule())
          .frame(minWidth: 44, minHeight: 44)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add \(feed.displayName) to Saved")
        .accessibilityIdentifier("feed.library.add.\(feed.uri.uriString())")
      } else {
        Menu {
          if displayedMembership == .saved {
            Button {
              perform(.pinned)
            } label: {
              Label("Pin to Feeds", systemImage: "pin")
            }
          } else if displayedMembership == .pinned {
            Button {
              perform(.unpinned)
            } label: {
              Label("Unpin Feed", systemImage: "pin.slash")
            }
          }
          if let onOpen {
            Button("Open Feed", systemImage: "arrow.up.forward", action: onOpen)
          }
          Button(role: .destructive) {
            perform(nil)
          } label: {
            Label("Remove from Library", systemImage: "trash")
          }
        } label: {
          HStack(spacing: 4) {
            Image(systemName: displayedMembership == .pinned ? "pin.fill" : "checkmark")
              .font(.footnote.weight(.bold))
          }
          .foregroundStyle(displayedMembership == .pinned ? Color.accentColor : .green)
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(
            (displayedMembership == .pinned ? Color.accentColor : Color.green).opacity(0.14),
            in: Capsule()
          )
          .frame(minWidth: 44, minHeight: 44)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          displayedMembership == .pinned
            ? Text("\(feed.displayName), Pinned. Manage feed", comment: "Accessibility label for manage menu on a pinned feed — variable is feed name")
            : Text("\(feed.displayName), Saved. Manage feed", comment: "Accessibility label for manage menu on a saved feed — variable is feed name")
        )
        .accessibilityIdentifier("feed.library.manage.\(feed.uri.uriString())")
      }
    }
    .animation(.spring(duration: 0.24, bounce: 0.25), value: displayedMembership)
    .onChange(of: actualMembership) { _, newValue in
      if optimisticMembership == newValue {
        optimisticMembership = nil
      }
    }
  }

  private func quickAdd() {
    PlatformHaptics.light()
    withAnimation(.spring(duration: 0.24, bounce: 0.25)) {
      optimisticMembership = .saved
    }
    Task { @MainActor in
      do {
        _ = try await actions.add(feed.uri, to: .saved)
        optimisticMembership = nil
      } catch let error as FeedLibraryActionError {
        if case .pendingSync = error {
          // Kept locally pending sync; retain the saved checkmark.
          optimisticMembership = nil
        } else {
          optimisticMembership = nil
          appState.toastManager.show(ToastItem(
            message: error.localizedDescription,
            icon: "exclamationmark.triangle.fill"
          ))
        }
      } catch {
        optimisticMembership = nil
        appState.toastManager.show(ToastItem(
          message: String(
            localized: "Couldn’t add \(feed.displayName). Try again.",
            comment: "Error toast when adding a feed to library fails — variable is the feed display name"
          ),
          icon: "exclamationmark.triangle.fill"
        ))
      }
    }
  }

  private func perform(_ destination: FeedLibraryDestination?) {
    PlatformHaptics.light()
    let target: FeedLibraryMembership = switch destination {
    case .saved, .unpinned: .saved
    case .pinned: .pinned
    case nil: .absent
    }
    withAnimation(.spring(duration: 0.24, bounce: 0.25)) {
      optimisticMembership = target
    }
    Task { @MainActor in
      do {
        if let destination {
          _ = try await actions.add(feed.uri, to: destination)
        } else {
          try await actions.remove(feed.uri)
        }
        optimisticMembership = nil
      } catch let error as FeedLibraryActionError {
        if case .pendingSync = error {
          optimisticMembership = nil
        } else {
          optimisticMembership = nil
          appState.toastManager.show(ToastItem(
            message: error.localizedDescription,
            icon: "exclamationmark.triangle.fill"
          ))
        }
      } catch {
        optimisticMembership = nil
        appState.toastManager.show(ToastItem(
          message: String(
            localized: "Couldn’t update \(feed.displayName). Try again.",
            comment: "Error toast when updating feed library status fails — variable is the feed display name"
          ),
          icon: "exclamationmark.triangle.fill"
        ))
      }
    }
  }
}

/// Compact App Store "Top Charts" feed row: crisp 46pt icon, 1-line title, 1-line subtitle,
/// and instant optimistic `+` / `✓` pill button. Keeps icons small to avoid low-res avatar blowout.
struct FeedStorefrontRow: View {
  let feed: AppBskyFeedDefs.GeneratorView
  var customSubtitle: String?
  let onSelect: () -> Void
  let onOpen: () -> Void

  private var subtitleText: String {
    if let customSubtitle, !customSubtitle.isEmpty {
      return customSubtitle
    }
    if let desc = feed.description?
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !desc.isEmpty {
      return desc
    }
    let creatorHandle = feed.creator.handle.description
    if let likes = feed.likeCount, likes > 0 {
      if likes < 1_000 {
        return String(
          localized: "@\(creatorHandle) · \(likes) likes",
          comment: "Feed row subtitle with creator handle and like count — first variable is handle, second is number of likes"
        )
      }
      let compactLikes = FeedCountFormatter.compact(likes)
      return String(
        localized: "@\(creatorHandle) · \(compactLikes) likes",
        comment: "Feed row subtitle with creator handle and compact like count — first variable is handle, second is compact count like 1.2K"
      )
    }
    return "@\(creatorHandle)"
  }

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Button(action: onSelect) {
        HStack(alignment: .center, spacing: 12) {
          StorefrontFeedIcon(feed: feed, size: 46)

          VStack(alignment: .leading, spacing: 2) {
            Text(feed.displayName)
              .appFont(AppTextRole.subheadline)
              .fontWeight(.semibold)
              .foregroundStyle(.primary)
              .lineLimit(1)

            Text(subtitleText)
              .appFont(AppTextRole.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("\(feed.displayName), \(subtitleText)")
      .accessibilityHint("Opens live preview and details")
      .accessibilityIdentifier("feed.storefront.row.\(feed.uri.uriString())")

      FeedStorefrontQuickAddButton(feed: feed, onOpen: onOpen)
    }
    .padding(.vertical, 4)
  }
}

/// Crisp small-format feed icon with subtle hairline border and gradient monogram fallback.
struct StorefrontFeedIcon: View {
  let feed: AppBskyFeedDefs.GeneratorView
  let size: CGFloat

  private var cornerRadius: CGFloat {
    size * 0.22
  }

  var body: some View {
    AsyncImage(url: feed.avatar.flatMap { URL(string: $0.uriString()) }) { phase in
      switch phase {
      case .success(let image):
        image
          .resizable()
          .scaledToFill()
      default:
        monogramPlaceholder
      }
    }
    .frame(width: size, height: size)
    .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
    )
    .accessibilityHidden(true)
  }

  private var monogramPlaceholder: some View {
    ZStack {
      LinearGradient(
        colors: [Color.accentColor.opacity(0.85), Color.accentColor.opacity(0.55)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      Text(String(feed.displayName.prefix(1)).uppercased())
        .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
        .foregroundStyle(.white)
    }
  }
}

/// App Store-style 3-row horizontal paging carousel (`.scrollTargetBehavior(.viewAligned)`).
/// Users scan 9–12 feeds in two seconds with peeking next-column affordance.
struct FeedStorefrontCarousel<Item: Identifiable>: View {
  let items: [Item]
  var rowsPerColumn: Int = 3
  let feedForItem: (Item) -> AppBskyFeedDefs.GeneratorView
  var subtitleForItem: (Item) -> String? = { _ in nil }
  let onSelect: (AppBskyFeedDefs.GeneratorView) -> Void
  let onOpen: (AppBskyFeedDefs.GeneratorView) -> Void

  private var columns: [[Item]] {
    FeedStorefrontViewModel.chunkIntoColumns(items, rowsPerColumn: rowsPerColumn)
  }

  var body: some View {
    ScrollView(.horizontal) {
      LazyHStack(alignment: .top, spacing: 14) {
        ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(column.enumerated()), id: \.element.id) { rowIndex, item in
              let feed = feedForItem(item)
              FeedStorefrontRow(
                feed: feed,
                customSubtitle: subtitleForItem(item),
                onSelect: { onSelect(feed) },
                onOpen: { onOpen(feed) }
              )
              if rowIndex < column.count - 1 {
                Divider()
                  .padding(.leading, 58)
              }
            }
          }
          .containerRelativeFrame(.horizontal) { width, _ in
            // Leave a ~36pt peek of the next column on compact screens; cap neatly on iPad/macOS.
            min(max(width - 44, 260), 360)
          }
        }
      }
      .scrollTargetLayout()
      .padding(.horizontal, 16)
    }
    .scrollIndicators(.hidden)
    .scrollTargetBehavior(.viewAligned)
  }
}

/// Section header for a Storefront shelf with an optional "See All" navigation affordance.
struct FeedShelfHeader: View {
  let title: String
  var subtitle: String?
  var onSeeAll: (() -> Void)?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .appFont(AppTextRole.title3)
          .fontWeight(.bold)
          .foregroundStyle(.primary)
          .accessibilityAddTraits(.isHeader)

        if let subtitle, !subtitle.isEmpty {
          Text(subtitle)
            .appFont(AppTextRole.caption)
            .foregroundStyle(.secondary)
        }
      }

      Spacer(minLength: 8)

      if let onSeeAll {
        Button(action: onSeeAll) {
          HStack(spacing: 2) {
            Text("See All")
              .appFont(AppTextRole.subheadline)
            Image(systemName: "chevron.forward")
              .font(.caption.weight(.semibold))
          }
          .foregroundStyle(Color.accentColor)
          .frame(minHeight: 36)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("See all \(title)")
      }
    }
    .padding(.horizontal, 16)
  }
}

enum FeedCountFormatter {
  static func compact(_ count: Int) -> String {
    if count >= 1_000_000 {
      let millions = Double(count) / 1_000_000.0
      return "\(millions.formatted(.number.precision(.fractionLength(1))))M"
    } else if count >= 1_000 {
      let thousands = Double(count) / 1_000.0
      return "\(thousands.formatted(.number.precision(.fractionLength(1))))K"
    } else {
      return count.formatted()
    }
  }
}
