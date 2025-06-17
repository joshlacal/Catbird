import SwiftUI
import OSLog

// MARK: - Chat Tab View

struct ChatTabView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Binding var selectedTab: Int
  @Binding var lastTappedTab: Int?
  @State private var selectedConvoId: String?
  @State private var searchText = ""
  @State private var isShowingErrorAlert = false
  @State private var lastErrorMessage: String?
  @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
  fileprivate let logger = Logger(subsystem: "blue.catbird", category: "ChatUI")

  // Ensure NavigationManager path binding uses the correct tab index (4)
  private var chatNavigationPath: Binding<NavigationPath> {
    appState.navigationManager.pathBinding(for: 4)
  }
  
  // Determine if we should use split view based on device and orientation
  private var shouldUseSplitView: Bool {
    DeviceInfo.isIPad || horizontalSizeClass == .regular
  }

  var body: some View {
    ZStack {
      if shouldUseSplitView {
        // iPad and large screens: Use NavigationSplitView
        NavigationSplitView(columnVisibility: $columnVisibility) {
          // Sidebar: Conversation List
          ConversationListView(
            chatManager: appState.chatManager,
            searchText: searchText,
            onSelectConvo: { id in
              selectedConvoId = id
            },
            onSelectSearchResult: { profile in
              startConversation(with: profile)
            }
          )
          .navigationTitle("Messages")
          .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 400)
        } detail: {
          // Detail also needs NavigationStack for navigation within
            if let convoId = selectedConvoId {
              ConversationView(convoId: convoId)
                .id(convoId)
                .navigationDestination(for: NavigationDestination.self) { destination in
                  NavigationHandler.viewForDestination(
                    destination,
                    path: chatNavigationPath,
                    appState: appState,
                    selectedTab: $selectedTab
                  )
                }
            } else {
              EmptyConversationView()
            }
        }
        .navigationSplitViewStyle(.automatic)
        .searchable(text: $searchText, prompt: "Search")
        .onChange(of: searchText) { _, newValue in
          appState.chatManager.searchLocal(searchTerm: newValue, currentUserDID: appState.currentUserDID)
        }
        .toolbar {
          ToolbarItem(placement: .navigationBarLeading) {
            MessageRequestsButton()
          }
          
          ToolbarItem(placement: .navigationBarTrailing) {
            ChatToolbarMenu()
          }
        }
          
      } else {
          ConversationListView(
            chatManager: appState.chatManager,
            searchText: searchText,
            onSelectConvo: { id in
              selectedConvoId = id
              // Use the correct tab index (4) for navigation
              appState.navigationManager.navigate(
                to: .conversation(id),
                in: 4
              )
            },
            onSelectSearchResult: { profile in
              startConversation(with: profile)
            }
          )
          .navigationTitle("Messages")
          .searchable(text: $searchText, prompt: "Search")
          .onChange(of: searchText) { _, newValue in
            appState.chatManager.searchLocal(searchTerm: newValue, currentUserDID: appState.currentUserDID)
          }
          .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
              MessageRequestsButton()
            }
            
            ToolbarItem(placement: .navigationBarTrailing) {
              ChatToolbarMenu()
            }
          }
          .navigationDestination(for: NavigationDestination.self) { destination in
            NavigationHandler.viewForDestination(
              destination,
              path: chatNavigationPath,
              appState: appState,
              selectedTab: $selectedTab
            )
          }
        
      }
      .onAppear {
        // Load conversations when the tab appears
        Task {
          // Check if conversations are already loaded or loading to avoid redundant calls
          if appState.chatManager.acceptedConversations.isEmpty && !appState.chatManager.loadingConversations {
            logger.debug("ChatTabView appeared, loading conversations.")
            await appState.chatManager.loadConversations(refresh: true)
          } else {
            logger.debug("ChatTabView appeared, conversations already loaded or loading.")
          }
        }
        // Start polling for conversation updates
        appState.chatManager.startConversationsPolling()
      }
      .onDisappear {
        // Stop polling when leaving the chat tab
        appState.chatManager.stopConversationsPolling()
      }
      // Handle potential errors from ChatManager with debouncing
      .alert(
        isPresented: $isShowingErrorAlert
      ) {
        Alert(
          title: Text("Chat Error"),
          message: Text(lastErrorMessage ?? "An unknown error occurred."),
          dismissButton: .default(Text("OK")) {
            // Clear the error state when alert is dismissed
            appState.chatManager.errorState = nil
            lastErrorMessage = nil
          }
        )
      }
      .onChange(of: appState.chatManager.errorState) { _, newError in
        // Only show alert if there's a new error and we're not already showing one
        if let error = newError, !isShowingErrorAlert {
          let errorMessage = error.localizedDescription
          
          // Prevent showing the same error message repeatedly
          if lastErrorMessage != errorMessage {
            lastErrorMessage = errorMessage
            isShowingErrorAlert = true
          }
        } else if newError == nil {
          // Clear alert state when error is cleared
          isShowingErrorAlert = false
          lastErrorMessage = nil
        }
      }

      // Add the ChatFAB with a new message action, but only if we're not already in a conversation
      // Commenting out for now - uncomment when NewMessageSheet is implemented
      // if chatNavigationPath.wrappedValue.isEmpty {
      //   ChatFAB(newMessageAction: {
      //     showingNewMessageSheet = true
      //   })
      //   .offset(y: -80)  // Match the offset of the main FAB
      // }
    }
  }

  // Search is now handled by ChatManager's searchLocal method

  private func startConversation(with profile: ProfileDisplayable) {
    Task {
      logger.debug("Starting conversation with user: \(profile.handle.description)")

      if let convoId = await appState.chatManager.startConversationWith(userDID: profile.did.didString()) {
        logger.debug("Successfully started conversation with ID: \(convoId)")

        await MainActor.run {
          if shouldUseSplitView {
            // For split view, just update the selected conversation
            selectedConvoId = convoId
          } else {
            // For regular navigation, use the navigation manager
            appState.navigationManager.navigate(
              to: .conversation(convoId),
              in: 4  // Chat tab index
            )
          }
        }
      } else {
        logger.error("Failed to start conversation with user: \(profile.handle.description)")
      }
    }
  }
}