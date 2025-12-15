//
//  OCRTextSelectionView.swift
//  Catbird
//
//  Created by Claude Code
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A view for selecting detected text regions from an image
@available(iOS 26.0, macOS 26.0, *)
struct OCRTextSelectionView: View {
  @Environment(\.dismiss) private var dismiss

  let image: Image
  let imageData: Data
  let onTextSelected: (String) -> Void

  @State private var detectedRegions: [DetectedTextRegion] = []
  @State private var selectedTexts: [String] = []
  @State private var isProcessing = false
  @State private var errorMessage: String?

  private let detector = OCRTextDetector()

  var body: some View {
    NavigationStack {
      ZStack {
        if isProcessing {
          VStack(spacing: 16) {
            ProgressView()
              .controlSize(.large)
            Text("Detecting text...")
              .appFont(AppTextRole.subheadline)
              .foregroundStyle(.secondary)
          }
        } else if let errorMessage = errorMessage {
          VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
              .appFont(size: 48)
              .foregroundStyle(.orange)

            Text(errorMessage)
              .appFont(AppTextRole.body)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
              .padding(.horizontal)

            Button("Try Again") {
              Task {
                await detectText()
              }
            }
            .buttonStyle(.borderedProminent)
          }
        } else if detectedRegions.isEmpty {
          VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
              .appFont(size: 48)
              .foregroundStyle(.secondary)

            Text("No text detected in this image")
              .appFont(AppTextRole.body)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
              .padding(.horizontal)
          }
        } else {
          ScrollView {
            VStack(spacing: 16) {
              // Image with text overlays
              GeometryReader { geometry in
                ZStack {
                  image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geometry.size.width)

                  // Text region overlays
                  ForEach(detectedRegions) { region in
                    TextRegionButton(
                      region: region,
                      isSelected: selectedTexts.contains(region.text),
                      imageSize: geometry.size
                    ) {
                      toggleTextSelection(region.text)
                    }
                  }
                }
              }
              .aspectRatio(contentMode: .fit)

              // Selected text preview
              if !selectedTexts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                  Text("Selected Text (\(selectedTexts.count))")
                    .appFont(AppTextRole.headline)
                    .foregroundStyle(.primary)

                  Text(selectedTexts.joined(separator: " "))
                    .appFont(AppTextRole.body)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(platformColor: PlatformColor.platformSystemGray6))
                    .cornerRadius(12)
                }
                .padding(.horizontal)
              }
            }
          }
        }
      }
      .navigationTitle("Select Text")
      #if os(iOS)
      .toolbarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", systemImage: "xmark") {
            dismiss()
          }
        }

        ToolbarItem(placement: .confirmationAction) {
          Button("Insert") {
            let combinedText = selectedTexts.joined(separator: " ")
            onTextSelected(combinedText)
            dismiss()
          }
          .disabled(selectedTexts.isEmpty)
        }
      }
      .task {
        await detectText()
      }
    }
  }

  private func detectText() async {
    isProcessing = true
    errorMessage = nil

    do {
      let regions = try await detector.detectText(in: imageData)
      await MainActor.run {
        detectedRegions = regions.sorted { $0.boundingBox.minY > $1.boundingBox.minY }
        isProcessing = false
      }
    } catch {
      await MainActor.run {
        errorMessage = error.localizedDescription
        isProcessing = false
      }
    }
  }

  private func toggleTextSelection(_ text: String) {
    if selectedTexts.contains(text) {
      selectedTexts.removeAll { $0 == text }
    } else {
      selectedTexts.append(text)
    }
  }
}

/// A button representing a detected text region
@available(iOS 26.0, macOS 26.0, *)
private struct TextRegionButton: View {
  let region: DetectedTextRegion
  let isSelected: Bool
  let imageSize: CGSize
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      Text(region.text)
        .appFont(AppTextRole.caption)
        .foregroundStyle(isSelected ? .white : .primary)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor : Color.clear)
        .glassEffect(isSelected ? .regular.interactive() : .clear)
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .strokeBorder(isSelected ? Color.clear : Color.accentColor.opacity(0.8), lineWidth: 2)
        )
        .cornerRadius(6)
    }
    .buttonStyle(.plain)
    .position(
      x: region.boundingBox.midX * imageSize.width,
      y: (1 - region.boundingBox.midY) * imageSize.height
    )
    .accessibilityLabel("Text: \(region.text)")
    .accessibilityHint(isSelected ? "Selected" : "Tap to select")
  }
}

// MARK: - Legacy iOS 18+ Support

/// Fallback OCR text selection view for iOS 18-25 without Liquid Glass
@available(iOS 18.0, macOS 13.0, *)
struct OCRTextSelectionViewLegacy: View {
  @Environment(\.dismiss) private var dismiss

  let image: Image
  let imageData: Data
  let onTextSelected: (String) -> Void

  @State private var detectedRegions: [DetectedTextRegion] = []
  @State private var selectedTexts: [String] = []
  @State private var isProcessing = false
  @State private var errorMessage: String?

  private let detector = OCRTextDetector()

  var body: some View {
    NavigationStack {
      ZStack {
        if isProcessing {
          VStack(spacing: 16) {
            ProgressView()
              .controlSize(.large)
            Text("Detecting text...")
              .appFont(AppTextRole.subheadline)
              .foregroundStyle(.secondary)
          }
        } else if let errorMessage = errorMessage {
          VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
              .appFont(size: 48)
              .foregroundStyle(.orange)

            Text(errorMessage)
              .appFont(AppTextRole.body)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
              .padding(.horizontal)

            Button("Try Again") {
              Task {
                await detectText()
              }
            }
            .buttonStyle(.borderedProminent)
          }
        } else if detectedRegions.isEmpty {
          VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
              .appFont(size: 48)
              .foregroundStyle(.secondary)

            Text("No text detected in this image")
              .appFont(AppTextRole.body)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
              .padding(.horizontal)
          }
        } else {
          ScrollView {
            VStack(spacing: 16) {
              // Image with text overlays
              GeometryReader { geometry in
                ZStack {
                  image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geometry.size.width)

                  // Text region overlays (legacy style without glass effects)
                  ForEach(detectedRegions) { region in
                    LegacyTextRegionButton(
                      region: region,
                      isSelected: selectedTexts.contains(region.text),
                      imageSize: geometry.size
                    ) {
                      toggleTextSelection(region.text)
                    }
                  }
                }
              }
              .aspectRatio(contentMode: .fit)

              // Selected text preview
              if !selectedTexts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                  Text("Selected Text (\(selectedTexts.count))")
                    .appFont(AppTextRole.headline)
                    .foregroundStyle(.primary)

                  Text(selectedTexts.joined(separator: " "))
                    .appFont(AppTextRole.body)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(platformColor: PlatformColor.platformSystemGray6))
                    .cornerRadius(12)
                }
                .padding(.horizontal)
              }
            }
          }
        }
      }
      .navigationTitle("Select Text")
      #if os(iOS)
      .toolbarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", systemImage: "xmark") {
            dismiss()
          }
        }

        ToolbarItem(placement: .confirmationAction) {
          Button("Insert") {
            let combinedText = selectedTexts.joined(separator: " ")
            onTextSelected(combinedText)
            dismiss()
          }
          .disabled(selectedTexts.isEmpty)
        }
      }
      .task {
        await detectText()
      }
    }
  }

  private func detectText() async {
    isProcessing = true
    errorMessage = nil

    do {
      let regions = try await detector.detectText(in: imageData)
      await MainActor.run {
        detectedRegions = regions.sorted { $0.boundingBox.minY > $1.boundingBox.minY }
        isProcessing = false
      }
    } catch {
      await MainActor.run {
        errorMessage = error.localizedDescription
        isProcessing = false
      }
    }
  }

  private func toggleTextSelection(_ text: String) {
    if selectedTexts.contains(text) {
      selectedTexts.removeAll { $0 == text }
    } else {
      selectedTexts.append(text)
    }
  }
}

/// Legacy button style without glass effects
@available(iOS 18.0, macOS 13.0, *)
private struct LegacyTextRegionButton: View {
  let region: DetectedTextRegion
  let isSelected: Bool
  let imageSize: CGSize
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      Text(region.text)
        .appFont(AppTextRole.caption)
        .foregroundStyle(isSelected ? .white : .primary)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor : Color(platformColor: PlatformColor.platformSystemGray6))
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .strokeBorder(isSelected ? Color.clear : Color.accentColor.opacity(0.8), lineWidth: 2)
        )
        .cornerRadius(6)
    }
    .buttonStyle(.plain)
    .position(
      x: region.boundingBox.midX * imageSize.width,
      y: (1 - region.boundingBox.midY) * imageSize.height
    )
    .accessibilityLabel("Text: \(region.text)")
    .accessibilityHint(isSelected ? "Selected" : "Tap to select")
  }
}

#Preview {
    @ObservationIgnored @Previewable @ObservationIgnored @Environment(AppState.self) var appState
  if #available(iOS 26.0, macOS 26.0, *) {
    OCRTextSelectionView(
      image: Image(systemName: "photo"),
      imageData: Data(),
      onTextSelected: { _ in }
    )
  } else {
    OCRTextSelectionViewLegacy(
      image: Image(systemName: "photo"),
      imageData: Data(),
      onTextSelected: { _ in }
    )
  }
}
