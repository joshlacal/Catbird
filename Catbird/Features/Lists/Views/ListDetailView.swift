import SwiftUI
import Petrel
import OSLog
import NukeUI

enum ListDetailTab: String, CaseIterable {
  case feed = "Posts"
  case members = "People"
}

@Observable
final class ListDetailViewModel {
  // MARK: - Properties
  
  private let appState: AppState
  let listURI: ATProtocolURI
  private let logger = Logger(subsystem: "blue.catbird", category: "ListDetailView")
  
  // Core data
  var listDetails: AppBskyGraphDefs.ListView?
  var members: [AppBskyActorDefs.ProfileView] = []
  
  // State
  var isLoading = false
  var errorMessage: String?
  var showingError = false
  var selectedTab: ListDetailTab = .feed
  
  // MARK: - Computed Properties
  
  var isOwnList: Bool {
    guard let listDetails = listDetails else { return false }
    return listDetails.creator.did.didString() == appState.userDID
  }

  /// Only curated lists have a post feed; moderation lists are just a set of accounts.
  var hasPostsFeed: Bool {
    listDetails?.purpose == .appbskygraphdefscuratelist
  }
  
  // MARK: - Initialization
  
  init?(listURIString: String, appState: AppState) {
    guard let uri = try? ATProtocolURI(uriString: listURIString) else {
      return nil
    }
    self.listURI = uri
    self.appState = appState
  }
  
  // MARK: - Data Loading
  
  @MainActor
  func loadInitialData() async {
    guard !isLoading else { return }
    
    isLoading = true
    errorMessage = nil
    
    do {
      // Load list details and members concurrently
      async let listDetailsTask = appState.listManager.getListDetails(listURI.description)
      async let membersTask = appState.listManager.getListMembers(listURI.description)
      
      listDetails = try await listDetailsTask
      members = try await membersTask
      
      logger.info("Loaded list data: \(self.members.count) members")
      
    } catch {
      logger.error("Failed to load list data: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      showingError = true
    }
    
    isLoading = false
  }
  
  /// Re-reads cached details so edits made on a pushed screen show up when returning.
  @MainActor
  func reloadDetailsFromCache() async {
    guard !isLoading, listDetails != nil else { return }
    if let details = try? await appState.listManager.getListDetails(listURI.description) {
      listDetails = details
    }
  }

  @MainActor
  func refreshData() async {
    do {
      // Refresh list details and members
      async let listDetailsTask = appState.listManager.getListDetails(listURI.description, forceRefresh: true)
      async let membersTask = appState.listManager.getListMembers(listURI.description, forceRefresh: true)
      
      listDetails = try await listDetailsTask
      members = try await membersTask
      
      logger.info("Refreshed list data")
      
    } catch {
      logger.error("Failed to refresh list data: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      showingError = true
    }
  }

  // MARK: - Member Actions

  /// Removes an account from the viewer's own list, restoring it if the request fails.
  @MainActor
  func removeMember(_ member: AppBskyActorDefs.ProfileView) async {
    guard let index = members.firstIndex(where: { $0.did == member.did }) else { return }
    withAnimation { _ = members.remove(at: index) }

    do {
      try await appState.listManager.removeMember(userDID: member.did.didString(), from: listURI.description)
      if let details = try? await appState.listManager.getListDetails(listURI.description) {
        listDetails = details
      }
    } catch {
      withAnimation { members.insert(member, at: min(index, members.count)) }
      logger.error("Failed to remove list member: \(error.localizedDescription)")
      errorMessage = UserFacingError.message(for: error, action: "remove this person from the list") ?? "Try again."
      showingError = true
    }
  }

  // MARK: - Mod-list Block Actions

  /// Blocks every account currently on this moderation list.
  @MainActor
  func blockListAccounts() async {
    do {
      try await appState.blockList(listUri: listURI)
      await refreshData()
    } catch {
      logger.error("Failed to block list accounts: \(error.localizedDescription)")
      errorMessage = UserFacingError.message(for: error, action: "block these accounts") ?? "Try again."
      showingError = true
    }
  }

  /// Removes the viewer's list-level block record for this moderation list.
  @MainActor
  func unblockListAccounts(listblockRecordUri: ATProtocolURI) async {
    do {
      try await appState.unblockList(listblockRecordUri: listblockRecordUri)
      await refreshData()
    } catch {
      logger.error("Failed to unblock list accounts: \(error.localizedDescription)")
      errorMessage = UserFacingError.message(for: error, action: "unblock these accounts") ?? "Try again."
      showingError = true
    }
  }
}

struct ListDetailView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @Environment(\.listsUseLocalNavigation) private var usesLocalNavigation
  @State private var vm: ListDetailViewModel?
  @State private var didAttemptInit = false
  @State private var localDestination: ListLocalDestination?
  @State private var feedSelectedTab: Int = 0
  @State private var isConfirmingListBlock = false
  @State private var isConfirmingListUnblock = false
  @State private var isShowingReportSheet = false
  @Binding var path: NavigationPath
  
  let listURIString: String
  
  init(listURIString: String, path: Binding<NavigationPath>) {
    self.listURIString = listURIString
    self._path = path
  }
  
  var body: some View {
    Group {
      if let viewModel = vm {
        contentView(viewModel: viewModel)
      } else if !didAttemptInit {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        errorView
      }
    }
    .themedGroupedBackground(appState.themeManager, appSettings: appState.appSettings)
    .listLocalNavigationDestination($localDestination)
    .task {
      if vm == nil {
        let listDetailViewModel = ListDetailViewModel(listURIString: listURIString, appState: appState)
        vm = listDetailViewModel
        didAttemptInit = true
        await listDetailViewModel?.loadInitialData()
      }
    }
    .onAppear {
      // Pick up edits made on the Edit List screen.
      if let vm {
        Task { await vm.reloadDetailsFromCache() }
      }
    }
  }

  /// Pushes list screens with the tab's path, or locally when hosted in Settings.
  private func navigate(to destination: ListLocalDestination) {
    if usesLocalNavigation {
      localDestination = destination
      return
    }
    switch destination {
    case .detail(let uri):
      path.append(NavigationDestination.listFeed(uri))
    case .edit(let uri):
      path.append(NavigationDestination.editList(uri))
    case .members(let uri):
      path.append(NavigationDestination.listMembers(uri))
    }
  }
  
  @ViewBuilder
  private func contentView(viewModel: ListDetailViewModel) -> some View {
    @Bindable var viewModel = viewModel
    
    VStack(spacing: 0) {
      // List header with details
      if let listDetails = viewModel.listDetails {
        listHeaderView(listDetails, viewModel: viewModel)
      } else if viewModel.isLoading {
        ProgressView()
          .padding()
      }
      
      if usesLocalNavigation || (viewModel.listDetails != nil && !viewModel.hasPostsFeed) {
        // Settings manages the list here, and moderation lists have no feed, so show people only.
        membersView(viewModel: viewModel)
      } else {
        // Tab Picker
        Picker("View", selection: $viewModel.selectedTab) {
          ForEach(ListDetailTab.allCases, id: \.self) { tab in
            Text(tab.rawValue).tag(tab)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        
        // Tab Content
        TabView(selection: $viewModel.selectedTab) {
          feedView(viewModel: viewModel)
            .tag(ListDetailTab.feed)

          membersView(viewModel: viewModel)
            .tag(ListDetailTab.members)
        }
        #if os(iOS)
        .tabViewStyle(.page(indexDisplayMode: .never))
        #endif
      }
    }
    .navigationTitle(viewModel.listDetails?.name ?? "List")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Menu {
          listToolbarMenu(viewModel: viewModel)
        } label: {
          Image(systemName: "ellipsis")
            .accessibilityLabel("More Options")
        }
      }
    }
    .refreshable {
      await viewModel.refreshData()
    }
    .alert("Something Went Wrong", isPresented: $viewModel.showingError) {
      Button("OK") {
        viewModel.showingError = false
      }
    } message: {
      if let errorMessage = viewModel.errorMessage {
        Text(errorMessage)
      }
    }
    .alert("Block accounts on this list", isPresented: $isConfirmingListBlock) {
      Button("Cancel", role: .cancel) {}
      Button("Block accounts on this list", role: .destructive) {
        Task { await viewModel.blockListAccounts() }
      }
    } message: {
      Text("Accounts currently on this list will be blocked. Future membership changes may change which accounts are blocked. Accounts you blocked directly stay blocked.")
    }
    .alert("Stop blocking accounts on this list", isPresented: $isConfirmingListUnblock) {
      Button("Cancel", role: .cancel) {}
      Button("Stop blocking accounts on this list", role: .destructive) {
        if let blockedRecordUri = viewModel.listDetails?.viewer?.blocked {
          Task { await viewModel.unblockListAccounts(listblockRecordUri: blockedRecordUri) }
        }
      }
    } message: {
      Text("Stop blocking accounts on this list? Accounts you blocked directly stay blocked.")
    }
    .sheet(isPresented: $isShowingReportSheet) {
      reportSheet(viewModel: viewModel)
    }
  }

  @ViewBuilder
  private func listToolbarMenu(viewModel: ListDetailViewModel) -> some View {
    if viewModel.isOwnList {
      Button {
        navigate(to: .edit(viewModel.listURI))
      } label: {
        Label("Edit List", systemImage: "pencil")
      }
      
      Button {
        navigate(to: .members(viewModel.listURI))
      } label: {
        Label("Manage Members", systemImage: "person.2.badge.gearshape")
      }
    }
    
    Button {
      Task { await viewModel.refreshData() }
    } label: {
      Label("Refresh", systemImage: "arrow.clockwise")
    }

    if viewModel.listDetails != nil {
      Divider()
      Button {
        isShowingReportSheet = true
      } label: {
        Label("Report List", systemImage: "flag")
      }
    }
    if let listDetails = viewModel.listDetails, listDetails.purpose.rawValue == "app.bsky.graph.defs#modlist" {
      Divider()

      if listDetails.viewer?.blocked != nil {
        Button("Stop blocking accounts on this list", role: .destructive) {
          isConfirmingListUnblock = true
        }
      } else {
        Button("Block accounts on this list", role: .destructive) {
          isConfirmingListBlock = true
        }
      }
    }
  }

  @ViewBuilder
  private func reportSheet(viewModel: ListDetailViewModel) -> some View {
    if let listDetails = viewModel.listDetails, let client = appState.atProtoClient {
      let reportingService = ReportingService(client: client)
      let subject = reportingService.createListSubject(uri: viewModel.listURI, cid: listDetails.cid)
      ReportFormView(
        reportingService: reportingService,
        subject: subject,
        contentDescription: "List \"\(listDetails.name)\""
      )
    }
  }
  
  private var errorView: some View {
    ContentUnavailableView(
      "List Not Found",
      systemImage: "exclamationmark.triangle",
      description: Text("This list couldn’t be found.")
    )
  }
  
  private func listHeaderView(_ listDetails: AppBskyGraphDefs.ListView, viewModel: ListDetailViewModel) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center, spacing: 14) {
        ListAvatarView(list: listDetails, size: 64)
        
        VStack(alignment: .leading, spacing: 4) {
          Text(listDetails.name)
            .appFont(AppTextRole.title3)
            .fontWeight(.bold)
            .foregroundStyle(.primary)
            .lineLimit(2)

          Button {
            path.append(NavigationDestination.profile(listDetails.creator.did.didString()))
          } label: {
            Text(creatorLine(for: listDetails))
              .appFont(AppTextRole.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          .buttonStyle(.plain)
          // Profiles open in the main app, not inside Settings.
          .allowsHitTesting(!usesLocalNavigation)

          HStack(spacing: 8) {
            ListPurposeBadge(purpose: listDetails.purpose)

            Text("^[\(listDetails.listItemCount ?? viewModel.members.count) member](inflect: true)")
              .appFont(AppTextRole.caption)
              .foregroundStyle(.secondary)
          }
        }
        
        Spacer(minLength: 0)
      }

      if let description = listDetails.description?.trimmingCharacters(in: .whitespacesAndNewlines),
         !description.isEmpty {
        Text(description)
          .appFont(AppTextRole.subheadline)
          .foregroundStyle(.primary)
          .lineLimit(4)
          .fixedSize(horizontal: false, vertical: true)
      }

      if viewModel.isOwnList {
        ownerActions(viewModel: viewModel)
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 8)
    .padding(.bottom, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func ownerActions(viewModel: ListDetailViewModel) -> some View {
    HStack(spacing: 10) {
      Button {
        navigate(to: .edit(viewModel.listURI))
      } label: {
        Label("Edit", systemImage: "pencil")
          .frame(maxWidth: .infinity)
      }

      Button {
        navigate(to: .members(viewModel.listURI))
      } label: {
        Label("Add People", systemImage: "person.badge.plus")
          .frame(maxWidth: .infinity)
      }
    }
    .appFont(AppTextRole.subheadline)
    .fontWeight(.semibold)
    .buttonStyle(.bordered)
    .buttonBorderShape(.capsule)
    .controlSize(.regular)
  }

  private func creatorLine(for listDetails: AppBskyGraphDefs.ListView) -> String {
    if listDetails.creator.did.didString() == appState.userDID {
      return String(localized: "List by you")
    }
    return String(localized: "List by @\(listDetails.creator.handle.description)")
  }
  
  @ViewBuilder
  private func membersView(viewModel: ListDetailViewModel) -> some View {
    List {
      if viewModel.isLoading && viewModel.members.isEmpty {
        ProgressView()
          .frame(maxWidth: .infinity, minHeight: 120)
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
      } else if viewModel.members.isEmpty {
        ContentUnavailableView(
          "No Members",
          systemImage: "person.2.slash",
          description: Text("This list doesn’t have anyone on it yet.")
        )
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
      } else {
        ForEach(viewModel.members, id: \.did) { member in
          Button {
            path.append(NavigationDestination.profile(member.did.didString()))
          } label: {
            HStack(alignment: .top, spacing: 12) {
              AsyncProfileImage(url: member.finalAvatarURL(), size: 44, labels: member.labels)
                .accessibilityHidden(true)
              
              VStack(alignment: .leading, spacing: 2) {
                Text(memberDisplayName(member))
                  .appFont(AppTextRole.subheadline)
                  .fontWeight(.semibold)
                  .foregroundStyle(.primary)
                  .lineLimit(1)
                
                Text(verbatim: "@\(member.handle.description)")
                  .appFont(AppTextRole.footnote)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)

                if let bio = member.description?.trimmingCharacters(in: .whitespacesAndNewlines), !bio.isEmpty {
                  Text(bio)
                    .appFont(AppTextRole.footnote)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .padding(.top, 2)
                }
              }
              
              Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .listRowBackground(Color.clear)
          .listRowSeparator(member.did == viewModel.members.first?.did ? .hidden : .automatic, edges: .top)
          .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if viewModel.isOwnList {
              Button(role: .destructive) {
                Task { await viewModel.removeMember(member) }
              } label: {
                Label("Remove from List", systemImage: "person.badge.minus")
              }
            }
          }
          // Profiles open in the main app, not inside Settings.
          .allowsHitTesting(!usesLocalNavigation)
          .accessibilityRemoveTraits(usesLocalNavigation ? .isButton : [])
        }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
  }

  private func memberDisplayName(_ member: AppBskyActorDefs.ProfileView) -> String {
    if let displayName = member.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !displayName.isEmpty {
      return displayName
    }
    return member.handle.description
  }
  
  @ViewBuilder
  private func feedView(viewModel: ListDetailViewModel) -> some View {
    FeedView(
      fetch: .list(viewModel.listURI),
      path: $path,
      selectedTab: $feedSelectedTab
    )
  }
}

#Preview("ListDetailView") {
  @Previewable @State var path = NavigationPath()
  NavigationStack(path: $path) {
    ListDetailView(
      listURIString: "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.graph.list/example",
      path: $path
    )
  }
  .previewWithAuthenticatedState()
}
