//
//  FollowButton.swift
//  Catbird
//
//  Pure presentation of follow state. Callers own networking and state.
//
//  `state` is the relationship; `isLoading` is an in-flight request and never changes the
//  look beyond a spinner, so unfollowing does not flash from tonal to solid. Width is
//  reserved for "Following", so swapping state does not reflow rows.
//  Blocked mirrors the old ProfileHeader pill: neutral stroked capsule, not tappable.
//

import SwiftUI

enum FollowButtonState: CaseIterable, Sendable {
  case notFollowing, following, blocked
}

enum FollowButtonSize: CaseIterable, Sendable {
  case regular, compact

  var buttonSize: CatbirdButtonSize { self == .regular ? .md : .sm }
}

struct FollowButton: View {
  let state: FollowButtonState
  var isLoading = false
  var size: FollowButtonSize = .regular
  var action: () -> Void

  private var kind: CatbirdButtonKind {
    switch state {
    case .notFollowing: return .primary
    case .following: return .tonal
    case .blocked: return .muted
    }
  }

  var body: some View {
    Button(action: action) { title }
      .buttonStyle(
        .catbird(kind, size: size.buttonSize, isLoading: isLoading && state != .blocked)
      )
      .allowsHitTesting(state != .blocked)
      .accessibilityAddTraits(state == .blocked ? .isStaticText : [])
      .accessibilityRemoveTraits(state == .blocked ? .isButton : [])
  }

  private var followingText: Text {
    Text(
      LocalizedStringResource(
        "Following", comment: "Button label indicating the user is currently following this account"))
  }

  @ViewBuilder private var title: some View {
    switch state {
    case .notFollowing:
      ZStack {
        followingText.opacity(0).accessibilityHidden(true)
        Text(LocalizedStringResource("Follow", comment: "Button action to follow an account"))
      }
    case .following:
      followingText
    case .blocked:
      HStack(spacing: Space.xs) {
        Image(systemName: "person.crop.circle.badge.xmark").accessibilityHidden(true)
        Text(
          "Blocked",
          comment: "Disabled pill shown in place of the Follow button when a block exists between accounts."
        )
      }
    }
  }
}

#Preview("Follow") {
  VStack(spacing: Space.md) {
    ForEach(FollowButtonSize.allCases, id: \.self) { size in
      HStack {
        ForEach(FollowButtonState.allCases, id: \.self) { state in
          FollowButton(state: state, size: size) {}
        }
        FollowButton(state: .following, isLoading: true, size: size) {}
      }
    }
  }
  .padding(Space.screenMargin)
}
