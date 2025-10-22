import SwiftUI
import Observation

/// View for displaying and managing saved post drafts
struct DraftsListView: View {
  @Environment(\.dismiss) private var dismiss
  let appState: AppState
  
  @State private var isLoading = true
  @State private var errorMessage: String?
  @State private var draftToDelete: DraftPostViewModel?
  @State private var showDeleteConfirmation = false
  
  var onSelectDraft: ((DraftPostViewModel) -> Void)?
  
  var body: some View {
    NavigationStack {
      Group {
        if isLoading {
          ProgressView()
        } else if appState.composerDraftManager.savedDrafts.isEmpty {
          emptyState
        } else {
          draftsList
        }
      }
      .navigationTitle("Drafts")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") {
            dismiss()
          }
        }
      }
      .alert("Delete Draft", isPresented: $showDeleteConfirmation, presenting: draftToDelete) { draft in
        Button("Delete", role: .destructive) {
          deleteDraft(draft)
        }
        Button("Cancel", role: .cancel) {}
      } message: { draft in
        Text("Are you sure you want to delete this draft? This action cannot be undone.")
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
      Label("No Drafts", systemImage: "doc.text")
    } description: {
      Text("Your saved drafts will appear here")
    }
  }
  
  private var draftsList: some View {
    List {
      ForEach(appState.composerDraftManager.savedDrafts) { draft in
        DraftRow(draft: draft)
          .contentShape(Rectangle())
          .onTapGesture {
            onSelectDraft?(draft)
          }
          .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
              draftToDelete = draft
              showDeleteConfirmation = true
            } label: {
              Label("Delete", systemImage: "trash")
            }
          }
          .contextMenu {
            Button(role: .destructive) {
              draftToDelete = draft
              showDeleteConfirmation = true
            } label: {
              Label("Delete", systemImage: "trash")
            }
          }
      }
    }
    .listStyle(.plain)
  }
  
  private func loadDrafts() async {
    await appState.composerDraftManager.loadSavedDrafts()
    await MainActor.run {
      isLoading = false
    }
  }
  
  private func deleteDraft(_ draft: DraftPostViewModel) {
    appState.composerDraftManager.deleteSavedDraft(draft.id)
  }
}

// MARK: - Draft Row

private struct DraftRow: View {
  let draft: DraftPostViewModel
  
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 8) {
        VStack(alignment: .leading, spacing: 4) {
          Text(draft.previewText)
            .font(.body)
            .lineLimit(3)
            .foregroundStyle(.primary)
          
          HStack(spacing: 4) {
            if draft.isReply {
              Label("Reply", systemImage: "arrowshape.turn.up.left")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if draft.isQuote {
              Label("Quote", systemImage: "quote.bubble")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if draft.isThread {
              Label("Thread", systemImage: "list.bullet")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if draft.hasMedia {
              Label("Media", systemImage: "photo")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
        
        Spacer()
        
        VStack(alignment: .trailing, spacing: 4) {
          Text(draft.modifiedDate, style: .relative)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 4)
  }
}

// MARK: - Preview

#Preview {
  DraftsListView(appState: AppState.shared)
}
