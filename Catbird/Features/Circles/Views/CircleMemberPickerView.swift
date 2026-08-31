import Petrel
import SwiftUI

/// Multi-select profile picker for Circle membership, backed by typeahead
/// actor search. Presents the native searchable-list pattern used elsewhere
/// in the app (MLS group creation, starter packs): search field always
/// visible, checkmark rows to toggle selection, selected people listed when
/// the search field is empty.
struct CircleMemberPickerView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss

  /// Ordered selection, insertion order preserved.
  @Binding var selection: [AppBskyActorDefs.ProfileViewBasic]

  /// DIDs that cannot be selected (existing Circle members). The signed-in
  /// user is always excluded: the owner is an implicit member.
  var excludedDIDs: Set<String> = []

  /// Total member cap for the Circle, counting `excludedDIDs` toward it.
  var maxMembers: Int = 150

  /// Optional footer shown under the selection (e.g. the history disclosure).
  var disclosure: String?

  @State private var searchText = ""
  @State private var searchResults: [AppBskyActorDefs.ProfileViewBasic] = []
  @State private var isSearching = false
  @State private var searchTask: Task<Void, Never>?

  private var selectedDIDs: Set<String> {
    Set(selection.map { $0.did.didString() })
  }

  private var remainingCapacity: Int {
    max(0, maxMembers - excludedDIDs.count - selection.count)
  }

  var body: some View {
    NavigationStack {
      List {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          selectedSection
        } else {
          resultsSection
        }
      }
      #if os(iOS)
      .listStyle(.insetGrouped)
      #else
      .listStyle(.inset)
      #endif
      .navigationTitle("Add Members")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            dismiss()
          }
          .fontWeight(.semibold)
          .accessibilityLabel("Finish selecting members")
        }
      }
      #if os(iOS)
      .searchable(
        text: $searchText,
        placement: .navigationBarDrawer(displayMode: .always),
        prompt: "Search by name or handle"
      )
      #else
      .searchable(text: $searchText, prompt: "Search by name or handle")
      #endif
      .autocorrectionDisabled()
      #if os(iOS)
      .textInputAutocapitalization(.never)
      #endif
      .onChange(of: searchText) { _, newValue in
        performSearch(query: newValue)
      }
    }
  }

  // MARK: - Sections

  @ViewBuilder
  private var selectedSection: some View {
    if selection.isEmpty {
      ContentUnavailableView(
        "No Members Yet",
        systemImage: "person.badge.plus",
        description: Text("Search for people to add to this Circle.")
      )
      .listRowBackground(Color.clear)
    } else {
      Section {
        ForEach(selection, id: \.did) { profile in
          HStack(spacing: 12) {
            profileCell(profile)
            Spacer()
            Button(role: .destructive) {
              remove(profile)
            } label: {
              Image(systemName: "minus.circle.fill")
                .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(profile.displayName ?? "@\(profile.handle)")")
          }
        }
      } header: {
        Text("Selected (\(selection.count))")
      } footer: {
        if let disclosure {
          Text(disclosure)
        }
      }
    }
  }

  @ViewBuilder
  private var resultsSection: some View {
    Section {
      if isSearching && searchResults.isEmpty {
        HStack {
          ProgressView()
            .padding(.trailing, 8)
          Text("Searching...")
            .foregroundStyle(.secondary)
        }
      } else if searchResults.isEmpty {
        Text("No matching profiles")
          .foregroundStyle(.secondary)
      } else {
        ForEach(selectableResults, id: \.did) { profile in
          resultRow(profile)
        }
      }
    } footer: {
      if remainingCapacity == 0 {
        Text("This Circle has reached its \(maxMembers)-member limit.")
      }
    }
  }

  /// Search results minus the signed-in user and already-excluded members.
  private var selectableResults: [AppBskyActorDefs.ProfileViewBasic] {
    searchResults.filter { profile in
      let did = profile.did.didString()
      return did != appState.userDID && !excludedDIDs.contains(did)
    }
  }

  private func resultRow(_ profile: AppBskyActorDefs.ProfileViewBasic) -> some View {
    let isSelected = selectedDIDs.contains(profile.did.didString())
    let atCapacity = !isSelected && remainingCapacity == 0

    return Button {
      toggle(profile)
    } label: {
      HStack(spacing: 12) {
        profileCell(profile)
        Spacer()
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
          .imageScale(.large)
      }
    }
    .buttonStyle(.plain)
    .disabled(atCapacity)
    .opacity(atCapacity ? 0.4 : 1)
    .accessibilityLabel(profile.displayName ?? "@\(profile.handle)")
    .accessibilityHint(isSelected ? "Selected. Tap to deselect." : "Tap to select.")
  }

  private func profileCell(_ profile: AppBskyActorDefs.ProfileViewBasic) -> some View {
    HStack(spacing: 12) {
      AsyncProfileImage(url: URL(string: profile.avatar?.uriString() ?? ""), size: 40)
      VStack(alignment: .leading, spacing: 2) {
        Text(profile.displayName ?? "@\(profile.handle)")
          .font(.subheadline.weight(.medium))
          .lineLimit(1)
        Text("@\(profile.handle)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
  }

  // MARK: - Selection

  private func toggle(_ profile: AppBskyActorDefs.ProfileViewBasic) {
    if selectedDIDs.contains(profile.did.didString()) {
      remove(profile)
    } else if remainingCapacity > 0 {
      selection.append(profile)
    }
  }

  private func remove(_ profile: AppBskyActorDefs.ProfileViewBasic) {
    selection.removeAll { $0.did.didString() == profile.did.didString() }
  }

  // MARK: - Search

  private func performSearch(query: String) {
    searchTask?.cancel()

    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      searchResults = []
      isSearching = false
      return
    }

    searchTask = Task {
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled, let client = appState.atProtoClient else { return }

      isSearching = true
      do {
        let params = AppBskyActorSearchActorsTypeahead.Parameters(q: trimmed, limit: 25)
        let (code, response) = try await client.app.bsky.actor.searchActorsTypeahead(input: params)
        guard !Task.isCancelled else { return }
        searchResults = (200..<300).contains(code) ? (response?.actors ?? []) : []
      } catch {
        guard !Task.isCancelled else { return }
        searchResults = []
      }
      isSearching = false
    }
  }
}
