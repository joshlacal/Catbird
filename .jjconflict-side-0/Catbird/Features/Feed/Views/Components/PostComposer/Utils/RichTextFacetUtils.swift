//
//  RichTextFacetUtils.swift
//  Catbird
//
//  Created by Josh LaCalamito on 12/18/23.
//

import Foundation
import SwiftUI
import os
import Petrel

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// Import cross-platform modifiers for keyboardType compatibility

// MARK: - Facet Management

struct RichTextFacetUtils {
  private static let logger = Logger(subsystem: "blue.catbird", category: "RichText.Utils")
  
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
  
  // Petrel’s RichText.swift provides AttributedString.toFacets() which converts
  // linked ranges into AppBskyRichtextFacet using UTF-8 offsets. Prefer that.
  
  /// Add a link facet to attributed text (range must be non-empty)
  static func addLinkFacet(to attributedText: NSAttributedString, url: URL, range: NSRange) -> NSAttributedString {
    logger.debug("Utils.addLinkFacet url=\(url.absoluteString) range=\(range.debugDescription)")
    let mutableText = NSMutableAttributedString(attributedString: attributedText)
    mutableText.addAttribute(.link, value: url, range: range)
    
    #if os(iOS)
    mutableText.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: range)
    #elseif os(macOS)
    mutableText.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: range)
    #endif
    
    mutableText.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
    return mutableText
  }

  /// Add or insert a link at the specified range. If the range length is zero, this will
  /// insert a visible display string and apply link styling to that new range.
  static func addOrInsertLinkFacet(
    to attributedText: NSAttributedString,
    url: URL,
    range: NSRange,
    displayText: String?
  ) -> NSAttributedString {
    let mutable = NSMutableAttributedString(attributedString: attributedText)

    // Determine display text when inserting at caret
    let visible = displayText?.isEmpty == false ? displayText! : shortenForDisplay(url)

    if range.length == 0 {
      // Insert display text at caret
      let insertLocation = max(0, min(range.location, mutable.length))
      let linkRun = NSMutableAttributedString(string: visible)
      #if os(iOS)
      linkRun.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: NSRange(location: 0, length: linkRun.length))
      #elseif os(macOS)
      linkRun.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: NSRange(location: 0, length: linkRun.length))
      #endif
      linkRun.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: linkRun.length))
      linkRun.addAttribute(.link, value: url, range: NSRange(location: 0, length: linkRun.length))
      mutable.insert(linkRun, at: insertLocation)
    } else {
      // Apply link styling to existing range
      return addLinkFacet(to: attributedText, url: url, range: range)
    }

    return mutable
  }

  /// Shorten URL for display (domain + truncated path)
  private static func shortenForDisplay(_ url: URL) -> String {
    let host = url.host ?? url.absoluteString
    let path = url.path
    if path.isEmpty || path == "/" { return host }
    let maxPath = 15
    if path.count > maxPath {
      let truncated = String(path.prefix(maxPath)) + "..."
      return host + truncated
    }
    return host + path
  }
  
  // If you need to translate byte ranges to characters for UI, use Petrel’s
  // String.index(atUTF8Offset:) utilities instead of manual conversions.
  
  /// Create facets using Petrel conversion with proper Unicode handling
  static func createFacets(from linkFacets: [LinkFacet], in text: String) -> [AppBskyRichtextFacet] {
    logger.debug("Utils.createFacets from=\(linkFacets.count) textLen=\(text.count)")
    
    var attributed = AttributedString(text)
    
    for facet in linkFacets {
      // Validate range before conversion
      guard facet.range.location >= 0,
            facet.range.location + facet.range.length <= text.count else {
        logger.error("Utils.createFacets: Invalid range \(facet.range.debugDescription) for text length \(text.count)")
        continue
      }
      
      // Convert NSRange to AttributedString range
      let start = attributed.index(attributed.startIndex, offsetByCharacters: facet.range.location)
      let end = attributed.index(start, offsetByCharacters: facet.range.length)
      let range = start..<end
      
      attributed[range].link = facet.url
      attributed[range].foregroundColor = .accentColor
      attributed[range].underlineStyle = .single
    }
    
    do {
      let facets = try attributed.toFacets() ?? []
      logger.debug("Utils.createFacets toFacets=\(facets.count)")
      return facets
    } catch {
      logger.error("Utils.createFacets failed: \(error.localizedDescription)")
      return []
    }
  }
  
  /// Parse existing facets to edit: use Petrel’s offsets; leave as-is for now,
  /// PostComposer fetches facets elsewhere via Petrel helpers.
  
  /// Generate attributed string with link styling
  static func createAttributedString(from text: String, linkFacets: [LinkFacet], baseAttributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
    let attributedString = NSMutableAttributedString(string: text, attributes: baseAttributes)
    
    // Apply link styling to each facet
    for linkFacet in linkFacets {
      attributedString.addAttributes([
        .foregroundColor: PlatformColor.platformSystemBlue,
        .underlineStyle: NSUnderlineStyle.single.rawValue,
        .link: linkFacet.url
      ], range: linkFacet.range)
    }
    
    return attributedString
  }
  
  /// Validate URL and return a standardized version
  static func validateAndStandardizeURL(_ urlString: String) -> URL? {
    logger.debug("Utils.validateURL input='\(urlString)'")
    var processedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    
    // Add https:// if no scheme is present
    if !processedURL.contains("://") {
      processedURL = "https://" + processedURL
    }
    
    let result = URL(string: processedURL)
    logger.debug("Utils.validateURL result='\(result?.absoluteString ?? "nil")'")
    return result
  }
  
  /// Update link facets when text changes, adjusting ranges as needed with proper Unicode handling
  static func updateFacetsForTextChange(
    linkFacets: [LinkFacet],
    in editedRange: NSRange,
    changeLength: Int,
    originalText: String,
    newText: String
  ) -> [LinkFacet] {
    logger.debug("Utils.updateFacets changeRange=\(editedRange.debugDescription) delta=\(changeLength) originalLen=\(originalText.count) newLen=\(newText.count) currentFacets=\(linkFacets.count)")
    
    // Validate inputs
    guard editedRange.location >= 0,
          editedRange.location <= originalText.count,
          editedRange.location + editedRange.length <= originalText.count else {
      logger.error("Utils.updateFacets: Invalid editedRange \(editedRange.debugDescription) for originalText length \(originalText.count)")
      return []
    }
    
    let updated: [LinkFacet] = linkFacets.compactMap { facet in
      // Validate facet range
      guard facet.range.location >= 0,
            facet.range.location + facet.range.length <= originalText.count else {
        logger.error("Utils.updateFacets: Invalid facet range \(facet.range.debugDescription) for originalText length \(originalText.count)")
        return nil
      }
      
      let facetEndLocation = facet.range.location + facet.range.length
      
      if facetEndLocation <= editedRange.location {
        // Facet is entirely before the edit - no change needed
        return facet
      } else if facet.range.location >= editedRange.location + editedRange.length {
        // Facet is entirely after the edit - adjust location
        let newLocation = facet.range.location + changeLength
        guard newLocation >= 0 && newLocation <= newText.count else { 
          logger.debug("Utils.updateFacets: Adjusted facet location \(newLocation) out of bounds for newText length \(newText.count)")
          return nil 
        }
        
        // Validate adjusted range
        guard newLocation + facet.range.length <= newText.count else {
          logger.debug("Utils.updateFacets: Adjusted facet range exceeds newText bounds")
          return nil
        }
        
        return LinkFacet(
          range: NSRange(location: newLocation, length: facet.range.length),
          url: facet.url,
          displayText: facet.displayText
        )
      } else {
        // Facet overlaps with edit - remove it for now (user can re-add)
        logger.debug("Utils.updateFacets: Removing overlapping facet at range \(facet.range.debugDescription)")
        return nil
      }
    }
    logger.debug("Utils.updateFacets resultCount=\(updated.count)")
    return updated
  }
}

// MARK: - Enhanced Link Creation Dialog

struct LinkCreationDialog: View {
  let selectedText: String
  let onComplete: (URL, String?) -> Void
  let onCancel: () -> Void
  
  @State private var urlText: String = ""
  @State private var displayText: String = ""
  @State private var showError: Bool = false
  @State private var errorMessage: String = ""
  @State private var isValidating: Bool = false
  @State private var validatedURL: URL? = nil
  @State private var showAdvancedOptions: Bool = false
  @FocusState private var isURLFieldFocused: Bool
  @FocusState private var isDisplayTextFocused: Bool
  
  private var isValidURL: Bool {
    validatedURL != nil && !showError
  }
  
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 24) {
          // Selected text section
          if !selectedText.isEmpty {
            selectedTextSection
          }
          
          // URL input section
          urlInputSection
          
          // Advanced options section
          advancedOptionsSection
          
          // URL preview section
          if let url = validatedURL {
            urlPreviewSection(url)
          }
          
          // Error section
          if showError {
            errorSection
          }
        }
        .padding()
      }
      .navigationTitle("Create Link")
      #if os(iOS)
      .toolbarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", systemImage: "xmark") {
            onCancel()
          }
        }
        
        ToolbarItem(placement: .confirmationAction) {
          Button("Add Link") { createLink() }
          .disabled(!isValidURL)
          #if os(iOS)
          .adaptiveGlassEffect(
            style: .accentTinted,
            in: Capsule(),
            interactive: true
          )
          #else
          .background(isValidURL ? Color.accentColor : Color.gray, in: Capsule())
          #endif
          .foregroundColor(.white)
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
        }
      }
      .onAppear {
        setupInitialState()
      }
      .onChange(of: urlText) { _, newValue in
        validateURL(newValue)
      }
    }
  }
  
  // MARK: - UI Sections
  
  private var selectedTextSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Selected Text", systemImage: "text.cursor")
        .appFont(AppTextRole.headline)
        .foregroundColor(.primary)
      
      Text(selectedText)
        .appFont(AppTextRole.body)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 12)
            .fill(Color.accentColor.opacity(0.1))
            .overlay(
              RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
            )
        )
        .overlay(
          HStack {
            Spacer()
            VStack {
              Image(systemName: "quote.opening")
                .appFont(size: 12)
                .foregroundColor(.accentColor.opacity(0.6))
              Spacer()
            }
            .padding(8)
          }
        )
    }
  }
  
  private var urlInputSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("Link URL", systemImage: "link")
          .appFont(AppTextRole.headline)
          .foregroundColor(.primary)
        
        Spacer()
        
        if isValidating {
          ProgressView()
            .scaleEffect(0.8)
        } else if isValidURL {
          Image(systemName: "checkmark.circle.fill")
            .foregroundColor(.green)
            .appFont(size: 16)
        }
      }
      
      VStack(spacing: 8) {
        #if os(iOS)
        TextField("https://example.com", text: $urlText)
          .textFieldStyle(.roundedBorder)
          .keyboardType(.URL)
          .autocapitalization(.none)
          .autocorrectionDisabled(true)
          .focused($isURLFieldFocused)
          .onSubmit {
            if isValidURL {
              createLink()
            }
          }
        #else
        TextField("https://example.com", text: $urlText)
          .textFieldStyle(.roundedBorder)
          .autocorrectionDisabled(true)
          .focused($isURLFieldFocused)
          .onSubmit {
            if isValidURL {
              createLink()
            }
          }
        #endif
        
        // Quick URL suggestions
        if urlText.isEmpty {
          quickSuggestionsView
        }
      }
    }
  }
  
  private var quickSuggestionsView: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(quickSuggestions, id: \.self) { suggestion in
          Button(action: {
            urlText = suggestion
          }) {
            Text(suggestion)
              .appFont(AppTextRole.caption)
              .padding(.horizontal, 12)
              .padding(.vertical, 6)
              .background(Color.accentColor.opacity(0.1))
              .foregroundColor(.accentColor)
              .cornerRadius(16)
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 1)
    }
  }
  
  private var quickSuggestions: [String] {
    ["https://", "http://", "ftp://"]
  }
  
  private var advancedOptionsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Button(action: {
        withAnimation(.easeInOut(duration: 0.3)) {
          showAdvancedOptions.toggle()
        }
      }) {
        HStack {
          Label("Advanced Options", systemImage: "gear")
            .appFont(AppTextRole.subheadline)
          Spacer()
          Image(systemName: showAdvancedOptions ? "chevron.up" : "chevron.down")
            .appFont(size: 12)
            .foregroundColor(.secondary)
        }
      }
      .foregroundColor(.primary)
      .buttonStyle(.plain)
      
      if showAdvancedOptions {
        VStack(alignment: .leading, spacing: 12) {
          VStack(alignment: .leading, spacing: 8) {
            Text("Display Text")
              .appFont(AppTextRole.caption)
              .foregroundColor(.secondary)
            
            TextField(selectedText.isEmpty ? "Optional custom text" : selectedText, text: $displayText)
              .textFieldStyle(.roundedBorder)
              .focused($isDisplayTextFocused)
            
            Text("Leave empty to use the selected text or URL")
              .appFont(AppTextRole.caption2)
              .foregroundColor(.secondary)
          }
        }
        .padding(.top, 8)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
  }
  
  private func urlPreviewSection(_ url: URL) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Preview", systemImage: "eye")
        .appFont(AppTextRole.headline)
        .foregroundColor(.primary)
      
      HStack(spacing: 12) {
        // Link icon
        RoundedRectangle(cornerRadius: 8)
          .fill(Color.accentColor.opacity(0.2))
          .frame(width: 40, height: 40)
          .overlay(
            Image(systemName: "link")
              .foregroundColor(.accentColor)
              .appFont(size: 16)
          )
        
        // Link details
        VStack(alignment: .leading, spacing: 4) {
          Text(finalDisplayText)
            .appFont(AppTextRole.subheadline)
            .fontWeight(.medium)
            .foregroundColor(.primary)
            .lineLimit(2)
          
          Text(url.absoluteString)
            .appFont(AppTextRole.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
        }
        
        Spacer()
      }
      .padding(16)
      .background(
        RoundedRectangle(cornerRadius: 12)
          .fill(Color.systemBackground)
          .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12)
          .stroke(Color.systemGray5, lineWidth: 1)
      )
    }
  }
  
  private var errorSection: some View {
    HStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundColor(.red)
        .appFont(size: 16)
      
      Text(errorMessage)
        .appFont(AppTextRole.body)
        .foregroundColor(.red)
        .multilineTextAlignment(.leading)
      
      Spacer()
    }
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(Color.red.opacity(0.1))
        .overlay(
          RoundedRectangle(cornerRadius: 12)
            .stroke(Color.red.opacity(0.3), lineWidth: 1)
        )
    )
  }
  
  // MARK: - Helper Properties
  
  private var finalDisplayText: String {
    if !displayText.isEmpty {
      return displayText
    } else if !selectedText.isEmpty {
      return selectedText
    } else {
      return validatedURL?.host ?? urlText
    }
  }
  
  // MARK: - Helper Methods
  
  private func setupInitialState() {
    displayText = selectedText
    isURLFieldFocused = true
  }
  
  private func validateURL(_ urlString: String) {
    // Clear previous state
    showError = false
    validatedURL = nil
    
    // Don't validate empty strings
    guard !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return
    }
    
    isValidating = true
    
    // Add slight delay to avoid excessive validation during typing
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      self.performValidation(urlString)
    }
  }
  
  private func performValidation(_ urlString: String) {
    defer { isValidating = false }
    
    guard let url = RichTextFacetUtils.validateAndStandardizeURL(urlString) else {
      showError = true
      errorMessage = "Please enter a valid URL. URLs should include a domain name (e.g., example.com or https://example.com)"
      return
    }
    
    // Additional validation
    guard let host = url.host, !host.isEmpty else {
      showError = true
      errorMessage = "URL must include a valid domain name"
      return
    }
    
    // Success
    validatedURL = url
    showError = false
  }
  
  private func createLink() {
    guard let url = validatedURL else {
      showError = true
      errorMessage = "Please enter a valid URL"
      return
    }
    // Pass the chosen display text (may be empty). The caller can decide how to use it.
    onComplete(url, finalDisplayText)
  }
}
