//
//  FeedLibraryButton.swift
//  Catbird
//
//  One add / saved / pinned control for feed rows. Merges FeedLibraryControls
//  and FeedStorefrontQuickAddButton: optimistic UI, haptics, manage menu.
//  Old types remain for existing call sites.
//
//  Migration mapping for the feed lane:
//  - FeedLibraryControls(...)            -> FeedLibraryButton(feed:, showsStatus: true, showsEducation: true)
//  - compactLabels: true                 -> size: .iconOnly (also use at accessibility sizes)
//  - statusChip / minimumLabelHeight     -> dropped; label is always the tinted capsule, >= 44pt hit
//  - prominent: true                     -> not supported; use Button + .catbird(.brand, size: .lg) for hero add
//  - alignsTrailing                      -> alignsTrailing
//  - FeedStorefrontQuickAddButton(...)   -> FeedLibraryButton(feed:) (defaults: no status, no education alert)
//

import Petrel
import SwiftUI

enum FeedLibraryButtonSize: CaseIterable, Sendable {
  /// "Add" / check / pin with the short "Add" text, icon-only for saved and pinned.
  case compact
  /// Full text for every state.
  case regular
  /// Icon only for every state (accessibility sizes, narrow columns).
  case iconOnly

  var buttonSize: CatbirdButtonSize { self == .regular ? .md : .sm }
}

/// Visual-only capsule used by FeedLibraryButton (and the kit gallery).
struct FeedLibraryButtonLabel: View {
  let membership: FeedLibraryMembership
  var size: FeedLibraryButtonSize = .regular

  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    HStack(spacing: Space.xs) {
      switch membership {
      case .absent:
        Image(systemName: "plus")
        if size != .iconOnly {
          Text("Add")
        }
      case .saved:
        Image(systemName: "checkmark")
        if size == .regular {
          Text("Saved", comment: "Status badge indicating a feed is saved in the library")
        }
      case .pinned:
        Image(systemName: "pin.fill")
        if size == .regular {
          Text("Pinned", comment: "Status badge indicating a feed is pinned")
        }
      }
    }
    .appFont(size.buttonSize.textRole)
    .lineLimit(1)
    .foregroundStyle(TintShapeStyle())
    .padding(.horizontal, size.buttonSize.horizontalPadding)
    .frame(minHeight: size.buttonSize.height)
    .background(
      Capsule(style: .continuous).fill(TintShapeStyle().opacity(contrast == .increased ? 0.22 : 0.14)))
    .frame(minWidth: ControlHeight.minHitTarget, minHeight: ControlHeight.minHitTarget)
    .contentShape(Rectangle())
  }
}

struct FeedLibraryButton: View {
  @Environment(AppState.self) private var appState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.catbirdTheme) private var theme
  let feed: AppBskyFeedDefs.GeneratorView
  var size: FeedLibraryButtonSize = .regular
  var onOpen: (() -> Void)?
  /// Show the saving spinner and the pending-sync / failed / success feedback rows
  /// (with Try Again), as FeedLibraryControls does.
  var showsStatus = false
  /// Show the one-time "Saved and Pinned" explanation alert after the first add.
  var showsEducation = false
  var alignsTrailing = false

  @State private var optimisticMembership: FeedLibraryMembership?
  @State private var showExplanation = false

  private let education = FeedDiscoveryEducationStore()
  private var actions: FeedLibraryActions { appState.feedLibraryActions }
  private var actualMembership: FeedLibraryMembership { actions.membership(for: feed.uri) }
  private var displayedMembership: FeedLibraryMembership { optimisticMembership ?? actualMembership }
  private var actionState: FeedLibraryActionState { actions.state(for: feed.uri) }

  var body: some View {
    VStack(alignment: alignsTrailing ? .trailing : .leading, spacing: Space.sm) {
      if showsStatus && actionState == .saving {
        ProgressView("Saving")
          .appFont(AppTextRole.caption)
          .accessibilityLabel("Saving \(feed.displayName)")
      } else {
        control
      }
      if showsStatus {
        feedback
      }
    }
    .fixedSize(horizontal: false, vertical: showsStatus)
    .catbirdAnimation(Motion.enter, value: displayedMembership)
    .onChange(of: actualMembership) { _, newValue in
      if optimisticMembership == newValue { optimisticMembership = nil }
    }
    .alert("Saved and Pinned", isPresented: $showExplanation) {
      Button("Got it") { education.acknowledge(accountDID: appState.userDID) }
    } message: {
      Text("Saved keeps a feed in your library. Pin to Feeds adds it to your pinned feeds without changing your default feed.")
    }
  }

  @ViewBuilder private var control: some View {
    if displayedMembership == .absent {
      Button(action: quickAdd) {
        FeedLibraryButtonLabel(membership: .absent, size: size)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Add \(feed.displayName) to Saved")
      .accessibilityIdentifier("feed.library.add.\(feed.uri.uriString())")
    } else {
      Menu {
        if displayedMembership == .saved {
          Button { perform(.pinned) } label: { Label("Pin to Feeds", systemImage: "pin") }
        } else if displayedMembership == .pinned {
          Button { perform(.unpinned) } label: { Label("Unpin Feed", systemImage: "pin.slash") }
        }
        if let onOpen {
          Button("Open Feed", systemImage: "arrow.up.forward", action: onOpen)
        }
        Button(role: .destructive) { perform(nil) } label: {
          Label("Remove from Library", systemImage: "trash")
        }
      } label: {
        FeedLibraryButtonLabel(membership: displayedMembership, size: size)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        displayedMembership == .pinned
          ? Text("\(feed.displayName), Pinned. Manage feed", comment: "Accessibility label for manage menu on a pinned feed — variable is feed name")
          : Text("\(feed.displayName), Saved. Manage feed", comment: "Accessibility label for manage menu on a saved feed — variable is feed name")
      )
      .accessibilityIdentifier("feed.library.manage.\(feed.uri.uriString())")
    }
  }

  @ViewBuilder private var feedback: some View {
    switch actionState {
    case .pendingSync:
      Text("Saved on this device. It will sync when you’re back online.")
        .appFont(AppTextRole.caption)
        .foregroundStyle(theme.text(.secondary))
      retryButton
    case .failed(let message):
      Text(message)
        .appFont(AppTextRole.caption)
        .foregroundStyle(theme.semantic(.danger))
      retryButton
    case .success(.saved):
      Text("Added to Saved")
        .appFont(AppTextRole.caption)
        .foregroundStyle(theme.text(.secondary))
    case .success(.pinned):
      Text("Pinned to Feeds")
        .appFont(AppTextRole.caption)
        .foregroundStyle(theme.text(.secondary))
    default:
      EmptyView()
    }
  }

  private var retryButton: some View {
    Button(action: retry) {
      Text("Try Again")
    }
    .buttonStyle(.catbird(.quiet, size: .sm))
  }

  private func retry() {
    Task { @MainActor in
      do {
        try await actions.retry(feed.uri)
        if showsEducation, actualMembership != .absent,
          !education.hasAcknowledged(accountDID: appState.userDID)
        {
          showExplanation = true
        }
      } catch {}
    }
  }

  private func quickAdd() {
    PlatformHaptics.light()
    Motion.withAnimation(Motion.enter, reduceMotion: reduceMotion) { optimisticMembership = .saved }
    Task { @MainActor in
      do {
        _ = try await actions.add(feed.uri, to: .saved)
        optimisticMembership = nil
        if showsEducation, !education.hasAcknowledged(accountDID: appState.userDID) { showExplanation = true }
      } catch let error as FeedLibraryActionError {
        optimisticMembership = nil
        if case .pendingSync = error { return }
        appState.toastManager.show(
          ToastItem(message: error.localizedDescription, icon: "exclamationmark.triangle.fill"))
      } catch {
        optimisticMembership = nil
        appState.toastManager.show(
          ToastItem(
            message: String(
              localized: "Couldn’t add \(feed.displayName). Try again.",
              comment: "Error toast when adding a feed to library fails — variable is the feed display name"
            ),
            icon: "exclamationmark.triangle.fill"))
      }
    }
  }

  private func perform(_ destination: FeedLibraryDestination?) {
    PlatformHaptics.light()
    let target: FeedLibraryMembership =
      switch destination {
      case .saved, .unpinned: .saved
      case .pinned: .pinned
      case nil: .absent
      }
    Motion.withAnimation(Motion.enter, reduceMotion: reduceMotion) { optimisticMembership = target }
    Task { @MainActor in
      do {
        if let destination {
          _ = try await actions.add(feed.uri, to: destination)
          if showsEducation, destination == .pinned, !education.hasAcknowledged(accountDID: appState.userDID) {
            showExplanation = true
          }
        } else {
          try await actions.remove(feed.uri)
        }
        optimisticMembership = nil
      } catch let error as FeedLibraryActionError {
        optimisticMembership = nil
        if case .pendingSync = error { return }
        appState.toastManager.show(
          ToastItem(message: error.localizedDescription, icon: "exclamationmark.triangle.fill"))
      } catch {
        optimisticMembership = nil
        appState.toastManager.show(
          ToastItem(
            message: String(
              localized: "Couldn’t update \(feed.displayName). Try again.",
              comment: "Error toast when updating feed library status fails — variable is the feed display name"
            ),
            icon: "exclamationmark.triangle.fill"))
      }
    }
  }
}

#Preview("Feed library label") {
  VStack(spacing: Space.md) {
    ForEach(FeedLibraryButtonSize.allCases, id: \.self) { size in
      HStack {
        FeedLibraryButtonLabel(membership: .absent, size: size)
        FeedLibraryButtonLabel(membership: .saved, size: size)
        FeedLibraryButtonLabel(membership: .pinned, size: size)
      }
    }
  }
  .padding(Space.screenMargin)
}
