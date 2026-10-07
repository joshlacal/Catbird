//
//  EquatableBox.swift
//  Catbird
//

import Foundation

/// A pointer-sized, immutable, `Equatable` wrapper for a large value.
///
/// Petrel's generated models are stored inline and their layout is only known
/// at run time: an `AppBskyFeedDefs.PostView` is about 3 KB and a
/// `FeedViewPost` about 7.5 KB. A SwiftUI view that stores one by value copies
/// it into every `some View` temporary its body builds, and Debug builds give
/// each temporary its own stack slot, so a single feed row could use most of a
/// device's 1 MB main-thread stack.
///
/// Views hold large models through this box instead. The view, its modifiers
/// and its opaque body types see 8 bytes, while `==` still compares the wrapped
/// values, so `.task(id:)`, `.onChange(of:)` and SwiftUI's field-by-field view
/// diffing behave exactly as they did with the inline value.
struct EquatableBox<Value: Equatable & Sendable>: Equatable, Sendable {
  private final class Storage: Sendable {
    let value: Value

    init(_ value: Value) {
      self.value = value
    }
  }

  private let storage: Storage

  init(_ value: Value) {
    storage = Storage(value)
  }

  /// Borrows the boxed value in place, so `box.value.uri` reads one field
  /// without copying the whole model onto the stack.
  var value: Value {
    _read { yield storage.value }
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.storage === rhs.storage || lhs.storage.value == rhs.storage.value
  }
}
