//
//  RichTextFacetUtils.swift
//  Catbird
//
//  Created by Josh LaCalamito on 12/18/23.
//

import Foundation
import SwiftUI
import Petrel

// MARK: - Facet Management

struct RichTextFacetUtils {
  
  /// Represents a link facet with its range and URL
  struct LinkFacet: Identifiable, Equatable {
    let id = UUID()
    let range: NSRange
    let url: URL
    let displayText: String
    
    static func == (lhs: LinkFacet, rhs: LinkFacet) -> Bool {
      lhs.id == rhs.id
    }
  }
  
  /// Convert character-based NSRange to byte-based range for AT Protocol facets
  static func characterRangeToByteRange(_ characterRange: NSRange, in text: String) -> NSRange {
    let startIndex = text.index(text.startIndex, offsetBy: characterRange.location)
    let endIndex = text.index(startIndex, offsetBy: characterRange.length)
    
    let startData = String(text[..<startIndex]).data(using: .utf8) ?? Data()
    let rangeData = String(text[startIndex..<endIndex]).data(using: .utf8) ?? Data()
    
    return NSRange(location: startData.count, length: rangeData.count)
  }
  
  /// Convert byte-based range to character-based range for UI display
  static func byteRangeToCharacterRange(_ byteRange: NSRange, in text: String) -> NSRange? {
    let textData = text.data(using: .utf8) ?? Data()
    
    guard byteRange.location + byteRange.length <= textData.count else { return nil }
    
    let beforeBytes = textData.prefix(byteRange.location)
    let rangeBytes = textData.subdata(in: byteRange.location..<(byteRange.location + byteRange.length))
    
    guard let beforeString = String(data: beforeBytes, encoding: .utf8),
          let rangeString = String(data: rangeBytes, encoding: .utf8) else {
      return nil
    }
    
    return NSRange(location: beforeString.count, length: rangeString.count)
  }
  
  /// Create AppBskyRichtextFacet objects from link facets
  static func createFacets(from linkFacets: [LinkFacet], in text: String) -> [AppBskyRichtextFacet] {
    return linkFacets.compactMap { linkFacet in
      let byteRange = characterRangeToByteRange(linkFacet.range, in: text)
      
      let byteSlice = AppBskyRichtextFacet.ByteSlice(
        byteStart: byteRange.location,
        byteEnd: byteRange.location + byteRange.length
      )
      
      guard let uri = URI(linkFacet.url.absoluteString) else { return nil }
      let linkFeature = AppBskyRichtextFacet.Link(uri: uri)
      return AppBskyRichtextFacet(index: byteSlice, features: [.appBskyRichtextFacetLink(linkFeature)])
    }
  }
  
  /// Parse existing facets from a post to recreate link facets for editing
  static func parseExistingFacets(_ facets: [AppBskyRichtextFacet], in text: String) -> [LinkFacet] {
    return facets.compactMap { facet in
      // Look for link features in this facet
      for feature in facet.features {
        if case .appBskyRichtextFacetLink(let linkFeature) = feature {
          // Convert byte range to character range
          let byteRange = NSRange(location: facet.index.byteStart, length: facet.index.byteEnd - facet.index.byteStart)
          guard let characterRange = byteRangeToCharacterRange(byteRange, in: text),
                let url = URL(string: linkFeature.uri.description) else {
            continue
          }
          
          let nsString = text as NSString
          let displayText = nsString.substring(with: characterRange)
          
          return LinkFacet(
            range: characterRange,
            url: url,
            displayText: displayText
          )
        }
      }
      return nil
    }
  }
  
  /// Generate attributed string with link styling
  static func createAttributedString(from text: String, linkFacets: [LinkFacet], baseAttributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
    let attributedString = NSMutableAttributedString(string: text, attributes: baseAttributes)
    
    // Apply link styling to each facet
    for linkFacet in linkFacets {
      attributedString.addAttributes([
        .foregroundColor: UIColor.systemBlue,
        .underlineStyle: NSUnderlineStyle.single.rawValue,
        .link: linkFacet.url
      ], range: linkFacet.range)
    }
    
    return attributedString
  }
  
  /// Validate URL and return a standardized version
  static func validateAndStandardizeURL(_ urlString: String) -> URL? {
    var processedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    
    // Add https:// if no scheme is present
    if !processedURL.contains("://") {
      processedURL = "https://" + processedURL
    }
    
    return URL(string: processedURL)
  }
  
  /// Update link facets when text changes, adjusting ranges as needed
  static func updateFacetsForTextChange(
    linkFacets: [LinkFacet],
    in editedRange: NSRange,
    changeLength: Int,
    originalText: String,
    newText: String
  ) -> [LinkFacet] {
    return linkFacets.compactMap { facet in
      let facetEndLocation = facet.range.location + facet.range.length
      
      if facetEndLocation <= editedRange.location {
        // Facet is entirely before the edit - no change needed
        return facet
      } else if facet.range.location >= editedRange.location + editedRange.length {
        // Facet is entirely after the edit - adjust location
        let newLocation = facet.range.location + changeLength
        guard newLocation >= 0 && newLocation < newText.count else { return nil }
        
        return LinkFacet(
          range: NSRange(location: newLocation, length: facet.range.length),
          url: facet.url,
          displayText: facet.displayText
        )
      } else {
        // Facet overlaps with edit - remove it for now (user can re-add)
        return nil
      }
    }
  }
}

// MARK: - Link Creation Dialog

struct LinkCreationDialog: View {
  let selectedText: String
  let onComplete: (URL) -> Void
  let onCancel: () -> Void
  
  @State private var urlText: String = ""
  @State private var showError: Bool = false
  @FocusState private var isURLFieldFocused: Bool
  
  var body: some View {
    NavigationStack {
      VStack(spacing: 20) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Selected Text")
            .appFont(AppTextRole.caption)
            .foregroundColor(.secondary)
          
          Text("\"\(selectedText)\"")
            .appFont(AppTextRole.body)
            .padding(12)
            .background(Color(.systemGray6))
            .cornerRadius(8)
        }
        
        VStack(alignment: .leading, spacing: 8) {
          Text("Link URL")
            .appFont(AppTextRole.caption)
            .foregroundColor(.secondary)
          
          TextField("https://example.com", text: $urlText)
            .textFieldStyle(RoundedBorderTextFieldStyle())
            .keyboardType(.URL)
            .autocapitalization(.none)
            .autocorrectionDisabled()
            .focused($isURLFieldFocused)
        }
        
        if showError {
          Text("Please enter a valid URL")
            .appFont(AppTextRole.caption)
            .foregroundColor(.red)
        }
        
        Spacer()
      }
      .padding()
      .navigationTitle("Create Link")
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            onCancel()
          }
        }
        
        ToolbarItem(placement: .confirmationAction) {
          Button("Create") {
            createLink()
          }
          .disabled(urlText.isEmpty)
        }
      }
      .onAppear {
        isURLFieldFocused = true
      }
    }
  }
  
  private func createLink() {
    guard let url = RichTextFacetUtils.validateAndStandardizeURL(urlText) else {
      showError = true
      return
    }
    
    showError = false
    onComplete(url)
  }
}
