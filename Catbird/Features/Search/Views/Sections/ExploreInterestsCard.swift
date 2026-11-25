//
//  ExploreInterestsCard.swift
//  Catbird
//
//  Explore interests NUX card (G07).
//

import Petrel
import SwiftUI

/// NUX card on the Explore/Search landing view that prompts the user to configure their interests.
public struct ExploreInterestsCard: View {
  public let userInterests: [String]
  public let onEditInterests: () -> Void
  public let onDismiss: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.fontManager) private var fontManager
  @Environment(AppState.self) private var appState

  public init(
    userInterests: [String],
    onEditInterests: @escaping () -> Void,
    onDismiss: @escaping () -> Void
  ) {
    self.userInterests = userInterests
    self.onEditInterests = onEditInterests
    self.onDismiss = onDismiss
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) {
            Image(systemName: "sparkles")
              .foregroundColor(.accentColor)
              .appFont(AppTextRole.subheadline)
            Text("Your Interests")
              .appFont(fontManager.scaledCustomFont(size: 17, weight: .bold, width: 120, relativeTo: .headline))
              .foregroundColor(.primary)
          }

          Text("Choose the topics you love to shape your recommendations.")
            .appFont(AppTextRole.subheadline)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer()

        Button(action: onDismiss) {
          Image(systemName: "xmark")
            .appFont(AppTextRole.caption.weight(.semibold))
            .foregroundColor(.secondary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Hide this card")
      }

      if !userInterests.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            ForEach(userInterests, id: \.self) { interest in
              CatbirdChip(title: Text(BlueskyInterest.displayName(for: interest)), size: .sm)
            }
          }
          .padding(.vertical, 2)
        }
      }

      Button(action: onEditInterests) {
        HStack(spacing: Space.xs) {
          Image(systemName: "slider.horizontal.3")
          Text(
            userInterests.isEmpty
              ? LocalizedStringResource("Add Interests", comment: "Button to choose interests when none are selected")
              : LocalizedStringResource("Edit Interests", comment: "Button to edit selected user interests")
          )
        }
      }
      .buttonStyle(.catbird(.primary, size: .sm))
      .padding(.top, 4)
    }
    .padding(DesignTokens.Spacing.base)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Size.radiusMD)
        .fill(Color.dynamicSecondaryBackground(appState.themeManager, currentScheme: colorScheme))
    )
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Size.radiusMD)
        .stroke(Color.dynamicBorder(appState.themeManager, currentScheme: colorScheme), lineWidth: 0.5)
    )
    .padding(.horizontal)
  }
}
