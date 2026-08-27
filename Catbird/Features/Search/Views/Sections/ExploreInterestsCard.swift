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
              .font(.subheadline)
            Text("Your Interests")
              .appFont(AppTextRole.headline)
              .foregroundColor(.primary)
          }

          Text("Select topics you're interested in to help customize your recommendations across Catbird.")
            .appFont(AppTextRole.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer()

        Button(action: onDismiss) {
          Image(systemName: "xmark")
            .font(.caption.weight(.semibold))
            .foregroundColor(.secondary)
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Hide this card")
      }

      if !userInterests.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            ForEach(userInterests, id: \.self) { interest in
              Text(interest)
                .appFont(AppTextRole.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.12))
                .foregroundColor(.accentColor)
                .clipShape(Capsule())
            }
          }
          .padding(.vertical, 2)
        }
      }

      Button(action: onEditInterests) {
        HStack(spacing: 4) {
          Image(systemName: "slider.horizontal.3")
            .font(.caption)
          Text(userInterests.isEmpty ? "Add Interests" : "Edit Interests")
            .appFont(AppTextRole.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.accentColor)
        .foregroundColor(.white)
        .clipShape(Capsule())
      }
      .buttonStyle(.plain)
      .padding(.top, 4)
    }
    .padding(DesignTokens.Spacing.md)
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
