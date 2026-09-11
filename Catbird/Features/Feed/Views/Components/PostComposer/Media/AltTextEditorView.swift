//
//  AltTextEditorView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 3/24/25.
//

import SwiftUI
import Vision
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
public typealias UIImage = NSImage
#endif
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A view for editing the alt text of an image or video
struct AltTextEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let image: Image
    let imageId: UUID
    let imageData: Data?
    @State private var editedText: String
    let maxLength: Int = 1000
    let onSave: (String, UUID) -> Void

    @State private var remainingChars: Int
    @State private var showingOCRSelection = false
    @State private var isGeneratingAltText = false
    @State private var altTextError: String?
    @State private var showingErrorAlert = false

    init(altText: String, image: Image, imageId: UUID, imageData: Data? = nil, onSave: @escaping (String, UUID) -> Void) {
        self.image = image
        self.imageId = imageId
        self.imageData = imageData
        self._editedText = State(initialValue: altText)
        self.onSave = onSave
        self._remainingChars = State(initialValue: 1000 - altText.count)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // Image preview
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 220)
                    .cornerRadius(12)
                    .padding(.horizontal)

                // Alt text guidance and actions
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add a description for people who can't see this content")
                        .appFont(AppTextRole.headline)
                        .foregroundStyle(.primary)

                    Text("Good descriptions are concise, accurate, and focus on what's important in the image or video.")
                        .appFont(AppTextRole.subheadline)
                        .foregroundStyle(.secondary)

                    // Action buttons (only show if we have image data)
                    if imageData != nil {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                #if canImport(FoundationModels)
                                if #available(iOS 26.0, macOS 26.0, *) {
                                    Button(action: {
                                        generateAltTextAction()
                                    }) {
                                        HStack(spacing: 6) {
                                            if isGeneratingAltText {
                                                ProgressView()
                                                    .controlSize(.small)
                                            } else {
                                                Image(systemName: "sparkles")
                                                    .appFont(AppTextRole.subheadline)
                                            }
                                            Text(isGeneratingAltText ? "Generating..." : "Generate Alt Text")
                                                .appFont(AppTextRole.subheadline)
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(Color.accentColor.opacity(0.1))
                                        .cornerRadius(8)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isGeneratingAltText)
                                    .accessibilityLabel("Generate alt text with Apple Intelligence")
                                }
                                #endif

                                Button(action: {
                                    showingOCRSelection = true
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "doc.text.viewfinder")
                                            .appFont(AppTextRole.subheadline)
                                        Text("Select Text from Image")
                                            .appFont(AppTextRole.subheadline)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.accentColor.opacity(0.1))
                                    .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                                .disabled(isGeneratingAltText)
                                .accessibilityLabel("Select text from image using OCR")
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

                // Text editor
                VStack(alignment: .trailing) {
                    TextField("Describe this content...", text: $editedText, axis: .vertical)
                        .padding()
                        .background(Color(platformColor: PlatformColor.platformSystemGray6))
                        .cornerRadius(12)
                        .frame(minHeight: 100, maxHeight: 150)
                        .onChange(of: editedText) { _, newValue in
                            remainingChars = maxLength - newValue.count

                            // Truncate if over limit
                            if newValue.count > maxLength {
                                editedText = String(newValue.prefix(maxLength))
                            }
                        }

                    // Character count
                    Text("\(remainingChars) characters remaining")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(remainingChars < 50 ? .orange : .secondary)
                        .padding(.trailing, 4)
                }
                .padding(.horizontal)

                Spacer()
            }
            .padding(.vertical)
            .navigationTitle("Edit Description")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") {
                        dismiss()
                    }
                    .disabled(isGeneratingAltText)
                }

                #if canImport(FoundationModels)
                if #available(iOS 26.0, macOS 26.0, *) {
                    if imageData != nil {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                generateAltTextAction()
                            } label: {
                                if isGeneratingAltText {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Label("Generate Alt Text", systemImage: "sparkles")
                                }
                            }
                            .disabled(isGeneratingAltText)
                            .accessibilityLabel("Generate alt text with Apple Intelligence")
                        }
                    }
                }
                #endif

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(editedText, imageId)
                        dismiss()
                    }
                    .disabled(isGeneratingAltText)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Description editor")
            .sheet(isPresented: $showingOCRSelection) {
                if let imageData = imageData {
                    if #available(iOS 26.0, macOS 26.0, *) {
                        OCRTextSelectionView(
                            image: image,
                            imageData: imageData,
                            onTextSelected: { selectedText in
                                insertOCRText(selectedText)
                            }
                        )
                    } else {
                        OCRTextSelectionViewLegacy(
                            image: image,
                            imageData: imageData,
                            onTextSelected: { selectedText in
                                insertOCRText(selectedText)
                            }
                        )
                    }
                }
            }
            .alert("Alt Text Generation", isPresented: $showingErrorAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(altTextError ?? "Failed to generate alt text.")
            }
        }
    }

    private func insertOCRText(_ text: String) {
        // Append with a space if there's existing text
        let separator = editedText.isEmpty ? "" : " "
        let newText = editedText + separator + text

        // Truncate if over limit
        if newText.count > maxLength {
            editedText = String(newText.prefix(maxLength))
        } else {
            editedText = newText
        }

        // Update remaining chars
        remainingChars = maxLength - editedText.count
    }

    // MARK: - AI Alt Text Generation

    private func generateAltTextAction() {
        guard let imageData = imageData else { return }
        #if canImport(UIKit)
        guard let uiImage = UIImage(data: imageData) else { return }
        #elseif canImport(AppKit)
        guard let uiImage = NSImage(data: imageData) else { return }
        #endif

        isGeneratingAltText = true
        altTextError = nil

        Task {
            do {
                let generated = try await generateAltText(for: uiImage)
                await MainActor.run {
                    if generated.count > maxLength {
                        self.editedText = String(generated.prefix(maxLength))
                    } else {
                        self.editedText = generated
                    }
                    self.remainingChars = maxLength - self.editedText.count
                    self.isGeneratingAltText = false
                }
            } catch {
                await MainActor.run {
                    self.altTextError = error.localizedDescription
                    self.showingErrorAlert = true
                    self.isGeneratingAltText = false
                }
            }
        }
    }

    /// Generates accessible alt text for the provided image using on-device Apple Intelligence.
    func generateAltText(for image: UIImage) async throws -> String {
        try await AltTextGeneratorService.shared.generateAltText(for: image)
    }
}

// MARK: - Alt Text Generator Service

/// Errors that can occur during AI alt text generation
enum AltTextGeneratorError: LocalizedError {
    case invalidImage
    case modelUnavailable(String)
    case unsupportedPlatform
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "Unable to process the image for alt text generation."
        case .modelUnavailable(let reason):
            return "Apple Intelligence is currently unavailable: \(reason)"
        case .unsupportedPlatform:
            return "On-device alt text generation requires iOS 26.0 or macOS 26.0 or later."
        case .generationFailed(let details):
            return "Failed to generate alt text: \(details)"
        }
    }
}

/// Service providing on-device AI accessibility description generation
public final class AltTextGeneratorService: Sendable {
    public static let shared = AltTextGeneratorService()

    private init() {}

    /// Generates concise, accessibility-focused alt text for an image
    public func generateAltText(for image: UIImage) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return try await generateOnDeviceAltText(for: image)
        } else {
            throw AltTextGeneratorError.unsupportedPlatform
        }
        #else
        throw AltTextGeneratorError.unsupportedPlatform
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private func generateOnDeviceAltText(for image: UIImage) async throws -> String {
        #if canImport(UIKit)
        guard let cgImage = image.cgImage ?? image.ciImage.flatMap({ ci in
            CIContext().createCGImage(ci, from: ci.extent)
        }) else {
            throw AltTextGeneratorError.invalidImage
        }
        #elseif canImport(AppKit)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw AltTextGeneratorError.invalidImage
        }
        #endif

        let model = SystemLanguageModel(useCase: .general)
        guard case .available = model.availability else {
            switch model.availability {
            case .unavailable(.appleIntelligenceNotEnabled):
                throw AltTextGeneratorError.modelUnavailable("Apple Intelligence is not enabled in Settings.")
            case .unavailable(.deviceNotEligible):
                throw AltTextGeneratorError.modelUnavailable("This device is not eligible for Apple Intelligence.")
            case .unavailable(.modelNotReady):
                throw AltTextGeneratorError.modelUnavailable("The on-device model is still downloading or preparing.")
            default:
                throw AltTextGeneratorError.modelUnavailable("The on-device model is unavailable.")
            }
        }

        let instructions = """
        You are an accessibility expert generating concise image alt-text for blind and visually impaired users.
        Follow accessibility best practices:
        - Be concise, natural, and descriptive.
        - Focus on the main subject, setting, and notable actions or context.
        - If text is present, include the key words.
        - Never start with "Image of", "Photo of", "Picture of", or similar redundant phrasing.
        - Keep the description under 250 characters.
        - Return only the description text without quotation marks, bullet points, or conversational filler.
        """

        let session = LanguageModelSession(model: model, instructions: instructions)
        let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 100)

        #if os(iOS) || os(macOS)
        if #available(iOS 27.0, macOS 27.0, *) {
            do {
                let attachment = Attachment(cgImage)
                let prompt = Prompt {
                    attachment
                    "Provide a concise accessibility alt-text description for this image under 250 characters. Do not include 'Image of' or 'Photo of'."
                }
                let response = try await session.respond(to: prompt, options: options)
                let cleaned = Self.cleanAltText(response.content)
                if !cleaned.isEmpty {
                    return cleaned
                }
            } catch {
                // Fall back to Vision extraction + SLM synthesis
            }
        }
        #endif

        let visualFeatures = await VisionFeatureExtractor.shared.extractSummary(from: cgImage)
        let promptText = buildPrompt(from: visualFeatures)
        let response = try await session.respond(to: Prompt(promptText), options: options)
        let cleaned = Self.cleanAltText(response.content)
        return cleaned.isEmpty ? "Image description unavailable." : cleaned
    }

    private func buildPrompt(from features: VisionFeatureExtractor.VisualSummary) -> String {
        var parts: [String] = []
        if !features.classifications.isEmpty {
            parts.append("Visual elements and scene: " + features.classifications.joined(separator: ", "))
        }
        if !features.recognizedText.isEmpty {
            parts.append("Visible text in image: " + features.recognizedText.map { "\"\($0)\"" }.joined(separator: ", "))
        }
        if features.faceCount > 0 {
            parts.append("People detected: \(features.faceCount)")
        }

        if parts.isEmpty {
            return "Write a concise accessibility alt-text description under 250 characters for this image."
        } else {
            return """
            Synthesize the following detected visual elements into a concise, natural accessibility alt-text description under 250 characters:
            \(parts.joined(separator: "\n"))
            """
        }
    }
    #endif

    public static func cleanAltText(_ rawText: String) -> String {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove surrounding quotes
        if (text.hasPrefix("\"") && text.hasSuffix("\"")) ||
           (text.hasPrefix("“") && text.hasSuffix("”")) {
            text.removeFirst()
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Remove redundant prefixes
        let redundantPrefixes = [
            "A photo of ", "Photo of ",
            "An image of ", "Image of ",
            "A picture of ", "Picture of ",
            "A shot of ", "Shot of ",
            "A close-up of ", "Close-up of "
        ]
        for prefix in redundantPrefixes {
            if text.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil {
                text = String(text.dropFirst(prefix.count))
                if let first = text.first {
                    text = first.uppercased() + text.dropFirst()
                }
                break
            }
        }

        // Enforce under 250 characters limit
        if text.count > 250 {
            let truncated = String(text.prefix(250))
            if let lastSentenceEnd = truncated.lastIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }) {
                text = String(truncated[...lastSentenceEnd])
            } else if let lastSpace = truncated.lastIndex(of: " ") {
                text = String(truncated[..<lastSpace]) + "."
            } else {
                text = truncated
            }
        }

        return text
    }
}

// MARK: - Vision Feature Extractor

actor VisionFeatureExtractor {
    static let shared = VisionFeatureExtractor()

    struct VisualSummary: Sendable {
        var classifications: [String] = []
        var recognizedText: [String] = []
        var faceCount: Int = 0
    }

    func extractSummary(from cgImage: CGImage) async -> VisualSummary {
        var summary = VisualSummary()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let classifyRequest = VNClassifyImageRequest()
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        let faceRequest = VNDetectFaceRectanglesRequest()

        do {
            try handler.perform([classifyRequest, textRequest, faceRequest])

            if let results = classifyRequest.results {
                let labels = results
                    .filter { $0.confidence > 0.15 }
                    .prefix(8)
                    .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
                summary.classifications = Array(labels)
            }

            if let textResults = textRequest.results {
                let texts = textResults
                    .compactMap { $0.topCandidates(1).first?.string }
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    .prefix(5)
                summary.recognizedText = Array(texts)
            }

            if let faceResults = faceRequest.results {
                summary.faceCount = faceResults.count
            }
        } catch {}

        return summary
    }
}

#Preview {
    @ObservationIgnored @Previewable @ObservationIgnored @Environment(AppState.self) var appState
    AltTextEditorView(
        altText: "A sample alt text",
        image: Image(systemName: "photo"),
        imageId: UUID(),
        onSave: { _, _ in }
    )
}
