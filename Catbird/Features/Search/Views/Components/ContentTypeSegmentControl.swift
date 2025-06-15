//
//  ContentTypeSegmentControl.swift
//  Catbird
//
//  Created on 3/9/25.
//

import SwiftUI

/// A system segmented control for selecting content types in search
struct ContentTypeSegmentControl: View {
  @Binding var selectedContentType: ContentType

  // Filter to display only the most relevant content types
  private let displayedTypes: [ContentType] = [
    .all, .profiles, .posts, .feeds
  ]
    // .starterPacks if we ever get starter pack search

  var body: some View {
    Picker("Content Type", selection: $selectedContentType) {
      ForEach(displayedTypes, id: \.self) { type in
        // Only use text in segmented pickers - iOS doesn't support mixed icon/text
        Text(type.title)
          .tag(type)
      }
    }
    .pickerStyle(.segmented)
  }
}

#Preview {
  ContentTypeSegmentControl(selectedContentType: .constant(.profiles))
    .padding()
}
