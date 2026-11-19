import OSLog
import Petrel
import SwiftUI

/// Inspects and manages accounts currently muted for reposts ("Originals Only")
/// by Catbird Intelligence onboarding or manual repost taming.
struct OriginalsOnlyAccountsView: View {
  @Environment(AppState.self) private var appState
  @State private var profilesByDID: [String: AppBskyActorDefs.ProfileViewDetailed] = [:]
  @State private var isLoading = false
  @State private var confirmingClearAll = false
  private let logger = Logger(subsystem: "blue.catbird", category: "OriginalsOnlyAccounts")

  private var sortedDIDs: [String] {
    appState.feedFilterSettings.mutedRepostAuthorDIDs.sorted()
  }

  var body: some View {
    Form {
      Section {
        VStack(alignment: .leading, spacing: 6) {
          Label("Originals-Only Repost Tamer", systemImage: "arrow.2.squarepath")
            .appFont(AppTextRole.headline)
            .fontWeight(.semibold)
          Text("Accounts listed here still appear in your timeline whenever they post original content, while their reposts stay hidden.")
            .appFont(AppTextRole.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
      }

      Section("Tamed Accounts (\(sortedDIDs.count))") {
        if sortedDIDs.isEmpty {
          ContentUnavailableView(
            "No Accounts in Originals Only",
            systemImage: "sparkles",
            description: Text("When Catbird Intelligence spots prolific reposters in your Starting Lineup, you can toggle them into Originals-Only mode here.")
          )
          .padding(.vertical, 16)
        } else {
          if isLoading && profilesByDID.isEmpty {
            HStack {
              Spacer()
              ProgressView("Loading accounts…")
                .controlSize(.small)
              Spacer()
            }
            .padding(.vertical, 8)
          }

          ForEach(sortedDIDs, id: \.self) { did in
            accountRow(for: did)
          }
          .onDelete(perform: removeOffsets)
        }
      }

      if !sortedDIDs.isEmpty {
        Section {
          Button(role: .destructive) {
            confirmingClearAll = true
          } label: {
            Label("Restore All Reposts", systemImage: "arrow.uturn.backward")
          }
          .accessibilityIdentifier("settings.originalsOnly.clearAll")
        } footer: {
          Text("Removing an account shows their reposts in your feeds again immediately.")
        }
      }
    }
    .navigationTitle("Originals-Only Accounts")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
    .task(id: sortedDIDs) {
      await hydrateProfiles(for: sortedDIDs)
    }
    .confirmationDialog(
      "Restore Reposts for All Accounts?",
      isPresented: $confirmingClearAll,
      titleVisibility: .visible
    ) {
      Button("Restore All Reposts", role: .destructive) {
        appState.feedFilterSettings.clearMutedRepostAuthors()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("All \(sortedDIDs.count) accounts will show reposts in your feeds again.")
    }
  }

  private func accountRow(for did: String) -> some View {
    let profile = profilesByDID[did]
    let handle = profile?.handle.description
    let displayName = profile?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = (displayName?.isEmpty == false ? displayName : nil) ?? handle.map { "@\($0)" } ?? did
    let subtitle = handle.map { "@\($0)" } ?? did

    return HStack(spacing: 12) {
      ProfileAvatarView(
        url: profile?.finalAvatarURL(),
        fallbackText: String(title.prefix(1)).uppercased(),
        size: 38
      )

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .appFont(AppTextRole.subheadline)
          .fontWeight(.semibold)
          .lineLimit(1)
        if subtitle != title {
          Text(subtitle)
            .appFont(AppTextRole.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }

      Spacer(minLength: 8)

      Button("Show Reposts") {
        appState.feedFilterSettings.setRepostMuted(false, for: did)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .accessibilityLabel("Show reposts from \(title)")
    }
    .padding(.vertical, 2)
  }

  private func removeOffsets(_ offsets: IndexSet) {
    let dids = sortedDIDs
    for index in offsets where dids.indices.contains(index) {
      appState.feedFilterSettings.setRepostMuted(false, for: dids[index])
    }
  }

  @MainActor
  private func hydrateProfiles(for dids: [String]) async {
    guard !dids.isEmpty, let client = appState.atProtoClient else { return }
    let missing = dids.filter { profilesByDID[$0] == nil }
    guard !missing.isEmpty else { return }
    isLoading = true
    defer { isLoading = false }

    for start in stride(from: 0, to: missing.count, by: 25) {
      guard !Task.isCancelled else { return }
      let batch = Array(missing[start..<min(start + 25, missing.count)])
      let actors = batch.compactMap { try? ATIdentifier(string: $0) }
      guard !actors.isEmpty else { continue }
      do {
        let (code, output) = try await client.app.bsky.actor.getProfiles(input: .init(actors: actors))
        guard !Task.isCancelled, (200..<300).contains(code), let profiles = output?.profiles else { continue }
        for profile in profiles {
          profilesByDID[profile.did.didString()] = profile
        }
      } catch {
        logger.debug("Originals-only profile hydration skipped: \(error.localizedDescription)")
      }
    }
  }
}
