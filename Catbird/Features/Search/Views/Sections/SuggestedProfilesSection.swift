//
//  SuggestedProfilesSection.swift
//  Catbird
//
//  Explore Suggested Accounts with Interest Tabs (G04).
//

import NukeUI
import OSLog
import Petrel
import SwiftUI

/// A section displaying suggested profiles categorized by interest tabs (G04).
public struct SuggestedProfilesSection: View {
  public let profiles: [AppBskyActorDefs.ProfileView]
  public let selectedCategory: String?
  public let userInterests: [String]
  public let isLoading: Bool
  public let onSelectCategory: (String?) -> Void
  public let onSelectProfile: (AppBskyActorDefs.ProfileView) -> Void
  public let onRefresh: () -> Void

  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  public static let standardCategories: [String] = [
    "Art",
    "Gaming",
    "Sports",
    "Music",
    "Politics",
    "Photography",
    "Science",
    "News",
    "Technology",
  ]

  public init(
    profiles: [AppBskyActorDefs.ProfileView],
    selectedCategory: String? = nil,
    userInterests: [String] = [],
    isLoading: Bool = false,
    onSelectCategory: @escaping (String?) -> Void,
    onSelectProfile: @escaping (AppBskyActorDefs.ProfileView) -> Void,
    onRefresh: @escaping () -> Void
  ) {
    self.profiles = profiles
    self.selectedCategory = selectedCategory
    self.userInterests = userInterests
    self.isLoading = isLoading
    self.onSelectCategory = onSelectCategory
    self.onSelectProfile = onSelectProfile
    self.onRefresh = onRefresh
  }

  /// Category tabs with "For You" first, followed by user interests boosted, then standard categories.
  private var allCategories: [String?] {
    var categories: [String?] = [nil]  // nil represents "For You"

    var seen = Set<String>()

    // Boosted user interests
    for interest in userInterests {
      let formatted = interest.trimmingCharacters(in: .whitespacesAndNewlines).capitalized
      if !formatted.isEmpty && !seen.contains(formatted.lowercased()) {
        categories.append(formatted)
        seen.insert(formatted.lowercased())
      }
    }

    // Standard categories
    for cat in Self.standardCategories {
      if !seen.contains(cat.lowercased()) {
        categories.append(cat)
        seen.insert(cat.lowercased())
      }
    }

    return categories
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.base) {
      headerView
      categoryTabBar
      contentArea
    }
  }

  private var headerView: some View {
    DiscoverySectionHeader("Suggested Accounts", subtitle: "Find your people, one interest at a time.") {
      Button(action: onRefresh) {
        Image(systemName: "arrow.clockwise")
          .appFont(AppTextRole.subheadline)
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }
      .disabled(isLoading)
      .accessibilityLabel("Refresh suggested accounts")
    }
  }

  private var categoryTabBar: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(allCategories, id: \.self) { category in
          categoryPill(category)
        }
      }
      .padding(.horizontal)
    }
  }

  private func categoryPill(_ category: String?) -> some View {
    let isSelected = (selectedCategory?.lowercased() == category?.lowercased())
    let title = category ?? "For You"

    return Button {
      onSelectCategory(category)
    } label: {
      Text(title)
        .appFont(AppTextRole.subheadline)
        .fontWeight(isSelected ? .semibold : .regular)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(
          Capsule()
            .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.12))
        )
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }

  @ViewBuilder
  private var contentArea: some View {
    if isLoading && profiles.isEmpty {
      VStack(spacing: 12) {
        ProgressView()
          .scaleEffect(1.1)
        Text("Loading accounts…")
          .appFont(AppTextRole.subheadline)
          .foregroundColor(.secondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 24)
      .background(Color.dynamicSecondaryBackground(appState.themeManager, currentScheme: colorScheme))
      .cornerRadius(12)
      .padding(.horizontal)
    } else if profiles.isEmpty {
      VStack(spacing: 8) {
        Image(systemName: "person.slash")
          .font(.system(size: 28))
          .foregroundColor(.secondary)
        Text("No suggestions right now")
          .appFont(AppTextRole.subheadline)
          .foregroundColor(.secondary)
        Button("Try Again", action: onRefresh)
          .appFont(size: Typography.Size.subheadline, weight: .medium, relativeTo: .subheadline)
          .frame(minHeight: 44)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 20)
      .background(Color.dynamicSecondaryBackground(appState.themeManager, currentScheme: colorScheme))
      .cornerRadius(12)
      .padding(.horizontal)
    } else {
      VStack(spacing: 0) {
        ForEach(Array(profiles.prefix(5).enumerated()), id: \.element.did) { index, profile in
          if index > 0 { Divider() }
          profileCard(profile: profile)
        }
      }
    }
  }

  private func profileCard(profile: AppBskyActorDefs.ProfileView) -> some View {
    let layout = dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: DesignTokens.Spacing.base))
      : AnyLayout(HStackLayout(alignment: .center, spacing: DesignTokens.Spacing.base))

    return layout {
      Button { onSelectProfile(profile) } label: {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.base) {
          AsyncProfileImage(url: URL(string: profile.avatar?.uriString() ?? ""), size: 48, labels: profile.labels)
          VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
              Text(profile.displayName ?? profile.handle.description)
                .appFont(size: Typography.Size.body, weight: .semibold, relativeTo: .body)
                .foregroundStyle(.primary)
                .lineLimit(2)
              if let badgeKind = VerificationBadge.kind(for: profile.verification, did: profile.did) {
                VerificationBadgeView(kind: badgeKind).font(.caption)
              }
            }
            Text("@\(profile.handle)")
              .appFont(AppTextRole.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
            if let description = profile.description, !description.isEmpty {
              Text(description)
                .appFont(AppTextRole.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .multilineTextAlignment(.leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityHint("Open profile")

      // Keep Follow outside the profile-navigation button so each action has its own hit target.
      EnhancedFollowButton(profile: profile)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, DesignTokens.Spacing.base)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
