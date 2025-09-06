//
//  UserMentionSuggestionView.swift
//  Catbird
//
//  A SwiftUI view that displays user suggestions when typing @ mentions in the post composer.
//  Integrates with the existing search infrastructure for user lookups.
//

import SwiftUI
import Petrel
import OSLog

private let mentionLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Catbird", category: "UserMentionSuggestion")

// MARK: - Mention Suggestion Data Model

struct MentionSuggestion: Identifiable, Equatable, Hashable {
  let id = UUID()
  let profile: AppBskyActorDefs.ProfileViewBasic
  let displayName: String
  let handle: String
  let avatarURL: URL?

  // Disambiguated initializers to support multiple profile models
  init(profile: AppBskyActorDefs.ProfileViewBasic) {
    self.profile = profile
    self.displayName = profile.displayName?.isEmpty == false ? profile.displayName! : profile.handle.description
    self.handle = profile.handle.description
    self.avatarURL = profile.avatar?.url
  }

  init(profile: AppBskyActorDefs.ProfileView) {
    let basic = AppBskyActorDefs.ProfileViewBasic(
      did: profile.did,
      handle: profile.handle,
      displayName: profile.displayName,
      avatar: profile.avatar,
      associated: profile.associated,
      viewer: profile.viewer,
      labels: profile.labels,
      createdAt: profile.createdAt,
      verification: profile.verification,
      status: profile.status
    )
    self.init(profile: basic)
  }

  init(profile: AppBskyActorDefs.ProfileViewDetailed) {
    let basic = AppBskyActorDefs.ProfileViewBasic(
      did: profile.did,
      handle: profile.handle,
      displayName: profile.displayName,
      avatar: profile.avatar,
      associated: profile.associated,
      viewer: profile.viewer,
      labels: profile.labels,
      createdAt: profile.createdAt,
      verification: profile.verification,
      status: profile.status
    )
    self.init(profile: basic)
  }

  static func == (lhs: MentionSuggestion, rhs: MentionSuggestion) -> Bool { lhs.profile.did.didString() == rhs.profile.did.didString() }
  func hash(into hasher: inout Hasher) { hasher.combine(profile.did.didString()) }
}

// MARK: - User Mention Suggestion View

@available(iOS 26.0, macOS 26.0, *)
struct UserMentionSuggestionView: View {
  let suggestions: [MentionSuggestion]
  let onSuggestionSelected: (MentionSuggestion) -> Void
  let onDismiss: () -> Void
  
  var body: some View {
    if !suggestions.isEmpty {
      VStack(spacing: 0) {
        suggestionList
      }
      .background(Color.systemBackground)
      .glassEffect(.regular, in: .rect(cornerRadius: 12))
      .overlay(
        RoundedRectangle(cornerRadius: 12)
          .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
      )
      // Clip contents to the rounded shape so edges aren't sharp
      .clipShape(RoundedRectangle(cornerRadius: 12))
      .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 2)
      .frame(maxHeight: 200)
    }
  }
  
  private var suggestionList: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(suggestions) { suggestion in
          Button {
            onSuggestionSelected(suggestion)
          } label: {
            MentionSuggestionRow(suggestion: suggestion)
          }
          .buttonStyle(.plain)
          
          if suggestion != suggestions.last {
            Divider()
              .padding(.leading, 60)
          }
        }
      }
    }
  }
}

// MARK: - Fallback for iOS 18-25

@available(iOS 18.0, macOS 13.0, *)
@available(iOS, obsoleted: 26.0, message: "Use iOS 26+ version with Liquid Glass")
@available(macOS, obsoleted: 26.0, message: "Use macOS 26+ version with Liquid Glass")
struct UserMentionSuggestionViewLegacy: View {
  let suggestions: [MentionSuggestion]
  let onSuggestionSelected: (MentionSuggestion) -> Void
  let onDismiss: () -> Void
  
  var body: some View {
    if !suggestions.isEmpty {
      VStack(spacing: 0) {
        suggestionList
      }
      .background(Color.systemBackground)
      // Corner radius alone doesn't clip all subviews; ensure proper clipping
      .clipShape(RoundedRectangle(cornerRadius: 12))
      .overlay(
        RoundedRectangle(cornerRadius: 12)
          .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
      )
      .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 2)
      .frame(maxHeight: 200)
    }
  }
  
  private var suggestionList: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(suggestions) { suggestion in
          Button {
            onSuggestionSelected(suggestion)
          } label: {
            MentionSuggestionRow(suggestion: suggestion)
          }
          .buttonStyle(.plain)
          
          if suggestion != suggestions.last {
            Divider()
              .padding(.leading, 60)
          }
        }
      }
    }
  }
}

// MARK: - Cross-Platform View Resolver

struct UserMentionSuggestionViewResolver: View {
  let suggestions: [MentionSuggestion]
  let onSuggestionSelected: (MentionSuggestion) -> Void
  let onDismiss: () -> Void
  
  var body: some View {
    if #available(iOS 26.0, macOS 26.0, *) {
      UserMentionSuggestionView(
        suggestions: suggestions,
        onSuggestionSelected: onSuggestionSelected,
        onDismiss: onDismiss
      )
    } else {
      UserMentionSuggestionViewLegacy(
        suggestions: suggestions,
        onSuggestionSelected: onSuggestionSelected,
        onDismiss: onDismiss
      )
    }
  }
}

// MARK: - Individual Suggestion Row

struct MentionSuggestionRow: View {
  let suggestion: MentionSuggestion
  
  var body: some View {
    HStack(spacing: 12) {
      // Avatar
      AsyncImage(url: suggestion.avatarURL) { image in
        image
          .resizable()
          .aspectRatio(contentMode: .fill)
      } placeholder: {
        Circle()
          .fill(Color.systemGray4)
          .overlay(
            Image(systemName: "person.fill")
              .foregroundColor(.systemGray2)
              .font(.system(size: 16))
          )
      }
      .frame(width: 32, height: 32)
      .clipShape(Circle())
      
      // User info
      VStack(alignment: .leading, spacing: 2) {
        Text(suggestion.displayName)
          .appFont(AppTextRole.body)
          .fontWeight(.medium)
          .lineLimit(1)
        
        Text("@\(suggestion.handle)")
          .appFont(AppTextRole.caption)
          .foregroundColor(.secondary)
          .lineLimit(1)
      }
      
      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .contentShape(Rectangle())
  }
}

// MARK: - Mention Detection Utilities

struct MentionDetectionUtils {
  
  /// Detects if the current cursor position is within an @ mention context
  /// Returns the mention query string if found, or nil if not in mention context
  static func detectMentionContext(in text: String, at cursorPosition: Int) -> String? {
    guard cursorPosition <= text.count else { return nil }
    
    let textUpToCursor = String(text.prefix(cursorPosition))
    
    // Find the last @ symbol before the cursor
    guard let lastAtIndex = textUpToCursor.lastIndex(of: "@") else { return nil }
    
    let atPosition = textUpToCursor.distance(from: textUpToCursor.startIndex, to: lastAtIndex)
    
    // Check if @ is at the beginning or preceded by whitespace
    let isValidMentionStart: Bool
    if atPosition == 0 {
      isValidMentionStart = true
    } else {
      let characterBeforeAt = textUpToCursor[textUpToCursor.index(textUpToCursor.startIndex, offsetBy: atPosition - 1)]
      isValidMentionStart = characterBeforeAt.isWhitespace
    }
    
    guard isValidMentionStart else { return nil }
    
    // Extract text after @ up to cursor
    let mentionStart = textUpToCursor.index(after: lastAtIndex)
    let mentionText = String(textUpToCursor[mentionStart...])
    
    // Check if mention text contains whitespace (which would invalidate the mention)
    guard !mentionText.contains(where: { $0.isWhitespace }) else { return nil }
    
    mentionLogger.debug("Detected mention context: '@\(mentionText)' at position \(atPosition)")
    return mentionText
  }
  
  /// Replaces the current mention query with the selected user mention
  static func insertMention(
    in text: String,
    cursorPosition: Int,
    mentionQuery: String,
    selectedUser: MentionSuggestion
  ) -> (newText: String, newCursorPosition: Int) {
    
    let textUpToCursor = String(text.prefix(cursorPosition))
    guard let lastAtIndex = textUpToCursor.lastIndex(of: "@") else {
      return (text, cursorPosition)
    }
    
    let atPosition = textUpToCursor.distance(from: textUpToCursor.startIndex, to: lastAtIndex)
    let mentionStartPosition = atPosition + 1 // Position after @
    
    // Replace from @ to cursor with full handle
    let beforeMention = String(text.prefix(atPosition))
    let afterCursor = String(text.dropFirst(cursorPosition))
    let mentionText = "@\(selectedUser.handle) "
    
    let newText = beforeMention + mentionText + afterCursor
    let newCursorPosition = atPosition + mentionText.count
    
    mentionLogger.debug("Inserted mention: '\(mentionText)' at position \(atPosition)")
    return (newText, newCursorPosition)
  }
}

// MARK: - Mention Search Manager

@Observable
class MentionSearchManager {
  var suggestions: [MentionSuggestion] = []
  var isLoading = false
  private var searchTask: Task<Void, Never>?
  
  func searchUsers(query: String, client: ATProtoClient) {
    // Cancel any ongoing search
    searchTask?.cancel()
    
    guard !query.isEmpty else {
      suggestions = []
      return
    }
    
    searchTask = Task {
      await performSearch(query: query, client: client)
    }
  }
  
  func clearSuggestions() {
    searchTask?.cancel()
    suggestions = []
    isLoading = false
  }
  
  @MainActor
  private func performSearch(query: String, client: ATProtoClient) async {
    isLoading = true
    
    do {
      // Search actors for mentions
      let (code, data) = try await client.app.bsky.actor.searchActors(
        input: AppBskyActorSearchActors.Parameters(q: query, limit: 8)
      )
      
      guard !Task.isCancelled else { return }
      
      if code == 200 {
        let actors = data?.actors ?? []
        let newSuggestions = actors.map { profile in
          MentionSuggestion(profile: profile)
        }
        
        suggestions = newSuggestions
        isLoading = false
        
        mentionLogger.debug("Found \(newSuggestions.count) mention suggestions for '\(query)'")
      } else {
        // Non-200 response
        suggestions = []
        isLoading = false
        mentionLogger.error("searchActors returned status \(code)")
      }
      
    } catch {
      guard !Task.isCancelled else { return }
      mentionLogger.error("Failed to search for mentions: \(error.localizedDescription)")
      suggestions = []
      isLoading = false
    }
  }
}
