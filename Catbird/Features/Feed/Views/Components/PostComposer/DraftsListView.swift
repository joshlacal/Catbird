import ImageIO
import Observation
import SwiftUI

/// Sheet for browsing, restoring, and deleting saved post drafts.
struct DraftsListView: View {
  @Environment(\.dismiss) private var dismiss
  let appState: AppState

  @State private var isLoading = true
  @State private var isSyncing = false
  @State private var draftToDelete: DraftPostViewModel?

  var onSelectDraft: ((DraftPostViewModel) -> Void)?

  private var drafts: [DraftPostViewModel] {
    appState.composerDraftManager.savedDrafts
  }

  var body: some View {
    NavigationStack {
      Group {
        if isLoading {
          ProgressView()
            .controlSize(.large)
        } else if drafts.isEmpty {
          emptyState
        } else {
          draftsList
        }
      }
      .navigationTitle("Drafts")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") {
            dismiss()
          }
        }
        if isSyncing {
          ToolbarItem(placement: .confirmationAction) {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel("Syncing drafts")
          }
        }
      }
      .confirmationDialog(
        "Delete Draft?",
        isPresented: Binding(
          get: { draftToDelete != nil },
          set: { if !$0 { draftToDelete = nil } }
        ),
        titleVisibility: .visible,
        presenting: draftToDelete
      ) { draft in
        Button("Delete Draft", role: .destructive) {
          deleteDraft(draft)
        }
        Button("Cancel", role: .cancel) {}
      } message: { _ in
        if appState.composerDraftManager.isDraftSyncEnabled {
          Text("This draft will be removed from all your devices.")
        } else {
          Text("This draft will be removed from this device.")
        }
      }
      .task {
        await loadDrafts()
      }
      .refreshable {
        await loadDrafts()
      }
    }
  }

  private var emptyState: some View {
    ContentUnavailableView {
      Label("No Drafts", systemImage: "square.and.pencil")
    } description: {
      Text("When you save a post for later, it will appear here.")
    }
  }

  private var draftsList: some View {
    List {
      Section {
        ForEach(drafts) { draft in
          Button {
            onSelectDraft?(draft)
          } label: {
            DraftRow(draft: draft)
          }
          .buttonStyle(.plain)
          .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
              draftToDelete = draft
            } label: {
              Label("Delete", systemImage: "trash")
            }
          }
          .contextMenu {
            Button {
              onSelectDraft?(draft)
            } label: {
              Label("Open in Composer", systemImage: "square.and.pencil")
            }
            Button(role: .destructive) {
              draftToDelete = draft
            } label: {
              Label("Delete", systemImage: "trash")
            }
          }
        }
      } footer: {
        if appState.composerDraftManager.isDraftSyncEnabled {
          Text("Drafts sync with your Bluesky account. Photos and videos stay on the device where they were added.")
        }
      }
    }
    .modifier(DraftsListStyleModifier())
  }

  @MainActor
  private func loadDrafts() async {
    await appState.composerDraftManager.loadSavedDrafts()
    isLoading = false

    guard appState.composerDraftManager.isDraftSyncEnabled else { return }
    isSyncing = true
    defer { isSyncing = false }
    await appState.composerDraftManager.performRemoteSync()
  }

  private func deleteDraft(_ draft: DraftPostViewModel) {
    appState.composerDraftManager.deleteSavedDraft(draft.id)
  }
}

// MARK: - List Style

private struct DraftsListStyleModifier: ViewModifier {
  func body(content: Content) -> some View {
    #if os(iOS)
      content.listStyle(.insetGrouped)
    #else
      content.listStyle(.inset)
    #endif
  }
}

// MARK: - Draft Row

private struct DraftRow: View {
  let draft: DraftPostViewModel

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 6) {
        Text(draft.previewText)
          .appFont(AppTextRole.body)
          .lineLimit(3)
          .foregroundStyle(.primary)
          .multilineTextAlignment(.leading)

        if hasBadges {
          badgeRow
        }

        footerRow
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if let thumbnailURL = draft.thumbnailURLs.first {
        DraftThumbnail(
          url: thumbnailURL,
          extraCount: max(0, draft.mediaCount - 1),
          showsVideoGlyph: draft.hasVideo
        )
      }
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
  }

  private var hasBadges: Bool {
    draft.isReply || draft.isQuote || draft.isThread
      || draft.remoteMediaDeviceName != nil
      || (draft.hasMedia && draft.thumbnailURLs.isEmpty)
  }

  private var badgeRow: some View {
    HStack(spacing: 10) {
      if draft.isReply {
        DraftBadge(text: "Reply", systemImage: "arrowshape.turn.up.left")
      }
      if draft.isQuote {
        DraftBadge(text: "Quote", systemImage: "quote.opening")
      }
      if draft.isThread {
        DraftBadge(
          text: "Thread · \(draft.postCount) posts",
          systemImage: "text.line.first.and.arrowtriangle.forward"
        )
      }
      if draft.hasMedia && draft.thumbnailURLs.isEmpty && draft.remoteMediaDeviceName == nil {
        DraftBadge(
          text: draft.hasVideo ? "Video" : "Media",
          systemImage: draft.hasVideo ? "video" : "photo"
        )
      }
      if let deviceName = draft.remoteMediaDeviceName {
        DraftBadge(text: "Media on \(deviceName)", systemImage: "iphone.and.arrow.forward")
          .foregroundStyle(.orange)
      }
    }
  }

  private var footerRow: some View {
    HStack(spacing: 4) {
      Text(draft.modifiedDate, format: .relative(presentation: .named))
      if draft.isSynced {
        Image(systemName: "checkmark.icloud")
          .accessibilityLabel("Synced")
      }
    }
    .appFont(AppTextRole.caption)
    .foregroundStyle(.tertiary)
  }
}

private struct DraftBadge: View {
  let text: String
  let systemImage: String

  var body: some View {
    Label(text, systemImage: systemImage)
      .appFont(AppTextRole.caption)
      .labelStyle(.titleAndIcon)
      .imageScale(.small)
      .foregroundStyle(.secondary)
      .lineLimit(1)
  }
}

// MARK: - Thumbnail

private struct DraftThumbnail: View {
  let url: URL
  let extraCount: Int
  let showsVideoGlyph: Bool

  @State private var image: CGImage?

  private static let side: CGFloat = 56

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      Group {
        if let image {
          Image(decorative: image, scale: 1)
            .resizable()
            .aspectRatio(contentMode: .fill)
        } else {
          Rectangle()
            .fill(.quaternary)
            .overlay {
              Image(systemName: showsVideoGlyph ? "video" : "photo")
                .foregroundStyle(.secondary)
            }
        }
      }
      .frame(width: Self.side, height: Self.side)
      .clipShape(.rect(cornerRadius: 12))

      if extraCount > 0 {
        Text("+\(extraCount)")
          .appFont(AppTextRole.caption2)
          .bold()
          .foregroundStyle(.white)
          .padding(.horizontal, 5)
          .padding(.vertical, 2)
          .background(.black.opacity(0.6), in: .capsule)
          .padding(4)
      } else if showsVideoGlyph, image != nil {
        Image(systemName: "video.fill")
          .imageScale(.small)
          .foregroundStyle(.white)
          .padding(4)
          .background(.black.opacity(0.6), in: .circle)
          .padding(4)
      }
    }
    .task(id: url) {
      image = await Self.loadThumbnail(from: url, pixelSize: Self.side * 3)
    }
    .accessibilityHidden(true)
  }

  private static func loadThumbnail(from url: URL, pixelSize: CGFloat) async -> CGImage? {
    await Task.detached(priority: .utility) {
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: pixelSize
      ]
      guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
      return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }.value
  }
}

#Preview {
  @ObservationIgnored @Previewable @ObservationIgnored @Environment(AppState.self) var appState
  if case .authenticated(let appState) = AppStateManager.shared.lifecycle {
    DraftsListView(appState: appState)
  }
}
