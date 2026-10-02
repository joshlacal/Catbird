//
//  ComposerTransitionNamespace.swift
//  Catbird
//
//  Provides an Environment value to propagate the composer matched-transition
//  namespace through the view hierarchy so any trigger (e.g., reply button)
//  can participate in the zoom transition to the post composer.
//

import SwiftUI

private struct ComposerTransitionNamespaceKey: EnvironmentKey {
  static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
  var composerTransitionNamespace: Namespace.ID? {
    get { self[ComposerTransitionNamespaceKey.self] }
    set { self[ComposerTransitionNamespaceKey.self] = newValue }
  }
}

extension View {
  /// Tags this view as the source of the composer zoom transition when the
  /// shared namespace is available (iOS 26+ only). No-ops otherwise.
  @ViewBuilder
  func composerMatchedSource(namespace: Namespace.ID?) -> some View {
    #if os(iOS)
    if #available(iOS 26.0, *), let ns = namespace {
      self.matchedTransitionSource(id: "compose", in: ns)
    } else {
      self
    }
    #else
    self
    #endif
  }
  
  /// Applies the zoom navigation transition to a presented composer when the
  /// shared namespace is available (iOS 26+ only). No-ops otherwise.
  @ViewBuilder
  func composerZoomTransition(namespace: Namespace.ID?) -> some View {
    #if os(iOS)
    if #available(iOS 26.0, *), let ns = namespace {
      self.navigationTransition(.zoom(sourceID: "compose", in: ns))
    } else {
      self
    }
    #else
    self
    #endif
  }
}

