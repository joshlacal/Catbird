//
//  DeferredPresentationHost.swift
//  Catbird
//
//  Attaches presentation modifiers only while one of them is requested.
//

import SwiftUI

// MARK: - Deferred Presentations

/// The invisible view that deferred presentations are attached to.
struct DeferredPresentationAnchor: View {
  var body: some View {
    Color.clear
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

extension View {
  /// Installs the presentations built on `anchor` (sheets, alerts, dialogs, popovers) only
  /// while `isActive`.
  ///
  /// Every `.sheet`, `.alert` or `.confirmationDialog` adds attributes and presentation
  /// preferences to the view graph even while dismissed, and a feed row with a dozen of them
  /// pays to build and merge all of them each time a cell is created or reused. Hosting them
  /// in a background that exists only while a presentation is requested keeps idle rows
  /// lean. The background is a separate subtree, so inserting it never changes the identity
  /// or state of the content, and it shares the content's frame for popover anchoring.
  ///
  /// `isActive` must be true whenever any binding the presentations read is true; the host
  /// presents on insertion and its removal completes the dismissal.
  func deferredPresentations<Presentations: View>(
    when isActive: Bool,
    @ViewBuilder _ presentations: @escaping (DeferredPresentationAnchor) -> Presentations
  ) -> some View {
    background {
      if isActive {
        presentations(DeferredPresentationAnchor())
      }
    }
  }
}
