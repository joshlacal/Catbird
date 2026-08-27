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
    HStack {
      HStack(spacing: 6) {
        Image(systemName: "person.2.fill")
          .appFont(AppTextRole.subheadline)
          .foregroundColor(.accentColor)

        Text("Suggested Accounts")
          .appFont(.customSystemFont(size: 17, weight: .bold, width: 120, relativeTo: .headline))
      }

      Spacer()

      Button(action: onRefresh) {
        Image(systemName: "arrow.triangle.2.circlepath")
          .appFont(AppTextRole.subheadline)
          .foregroundColor(.accentColor)
          .frame(width: 32, height: 32)
          .background(
            Circle()
              .fill(Color.accentColor.opacity(0.1))
          )
      }
    }
    .padding(.horizontal)
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
        .padding(.vertical, 6)
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
        Text("Loading accounts...")
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
        Text("No suggestions available")
          .appFont(AppTextRole.subheadline)
          .foregroundColor(.secondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 20)
      .background(Color.dynamicSecondaryBackground(appState.themeManager, currentScheme: colorScheme))
      .cornerRadius(12)
      .padding(.horizontal)
    } else {
      VStack(spacing: 10) {
        ForEach(profiles.prefix(5), id: \.did) { profile in
          profileCard(profile: profile)
        }
      }
      .padding(.horizontal)
    }
  }

  private func profileCard(profile: AppBskyActorDefs.ProfileView) -> some View {
    Button {
      onSelectProfile(profile)
    } label: {
      HStack(alignment: .center, spacing: 12) {
        AsyncProfileImage(url: URL(string: profile.avatar?.uriString() ?? ""), size: 48)

        VStack(alignment: .leading, spacing: 3) {
          HStack(alignment: .center, spacing: 4) {
            Text(profile.displayName ?? profile.handle.description)
              .appFont(AppTextRole.body.weight(.semibold))
              .foregroundColor(Color.dynamicText(appState.themeManager, style: .primary, currentScheme: colorScheme))
              .lineLimit(1)
              .truncationMode(.tail)

            if let badgeKind = VerificationBadge.kind(
              for: profile.verification,
              did: profile.did
            ) {
              VerificationBadgeView(kind: badgeKind)
                .font(.caption)
            }
          }

          Text("@\(profile.handle)")
            .appFont(AppTextRole.subheadline)
            .foregroundColor(Color.dynamicText(appState.themeManager, style: .secondary, currentScheme: colorScheme))
            .lineLimit(1)
            .truncationMode(.middle)

          if let description = profile.description, !description.isEmpty {
            Text(description)
              .appFont(AppTextRole.footnote)
              .foregroundColor(Color.dynamicText(appState.themeManager, style: .tertiary, currentScheme: colorScheme))
              .lineLimit(2)
              .multilineTextAlignment(.leading)
          }
        }

        Spacer(minLength: 8)

        EnhancedFollowButton(profile: profile)
      }
      .padding(12)
      .frame(maxWidth: .infinity)
      .background(
        Color.dynamicSecondaryBackground(appState.themeManager, currentScheme: colorScheme)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12)
          .stroke(Color.dynamicBorder(appState.themeManager, currentScheme: colorScheme).opacity(0.3), lineWidth: 0.5)
      )
      .cornerRadius(12)
    }
    .buttonStyle(.plain)
  }
}
