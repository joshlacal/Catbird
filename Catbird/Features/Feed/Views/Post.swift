//
//  Post.swift
//  Catbird
//
//  Created by Josh LaCalamito on 6/29/24.
//

import SwiftUI
import Petrel
import Translation
import NaturalLanguage
import OSLog
#if os(iOS)
import UIKit
#endif

struct Post: View, Equatable {
    static func == (lhs: Post, rhs: Post) -> Bool {
        lhs.post == rhs.post
    }
    
    private let logger = Logger(subsystem: "blue.catbird", category: "Translation")
    
    let post: AppBskyFeedPost
    let isSelectable: Bool
    let useUIKitSelectableText: Bool
    @Binding var path: NavigationPath
    @State private var showTranslation = false
    @State private var translatedText: String?
    @State private var translationConfig: Any? // Use Any instead of specific type for cross-platform compatibility
    @State private var translationError: String?
    @State private var isTranslating = false
    @State private var showTranslationPopover = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showLanguageSelection = false
    private let textSize: CGFloat?
    private let textStyle: Font.TextStyle
    private let textDesign: Font.Design
    private let textWeight: Font.Weight
    private let fontWidth: CGFloat?
    private let lineSpacing: CGFloat
    private let letterSpacing: CGFloat

    // public initalizer
    public init(post: AppBskyFeedPost, isSelectable: Bool, path: Binding<NavigationPath>,
//                textSize: CGFloat = 17,
//                textStyle: Font.TextStyle = .body,
//                textDesign: Font.Design = .default,
//                textWeight: Font.Weight = .regular,
//                fontWidth: CGFloat = 100,
//                lineSpacing: CGFloat = 1.5,
//                letterSpacing: CGFloat = 0
                
                textSize: CGFloat? = nil,
                textStyle: Font.TextStyle = .body,
                textDesign: Font.Design = .default,
                textWeight: Font.Weight = .regular,
                fontWidth: CGFloat? = nil,
                lineSpacing: CGFloat = 1.2,
                letterSpacing: CGFloat = 0.2,
                useUIKitSelectableText: Bool = false

    ) {
        self.post = post
        self.isSelectable = isSelectable
        self.useUIKitSelectableText = useUIKitSelectableText
        self._path = path
        self.textSize = textSize
        self.textStyle = textStyle
        self.textDesign = textDesign
        self.textWeight = textWeight
        self.fontWidth = fontWidth
        self.lineSpacing = lineSpacing
        self.letterSpacing = letterSpacing

    }
    
    // Typography configuration
    //    @Environment(\.legibilityWeight) private var legibilityWeight
    private var postTextDesign: Font.Design = .default
    private var postTextWeight: Font.Weight = .regular
    
    private var sourceLanguages: [Locale.Language] {
        post.langs?.map { $0.lang } ?? []
    }
    
    private var targetLanguage: Locale.Language {
        Locale.current.language
    }
    
    private var shouldShowTranslationButton: Bool {
        let targetBase = targetLanguage.baseLanguageCode?.lowercased() ?? "en"
        // Show the button if any source language's base code differs from the target
        return sourceLanguages.contains { ($0.baseLanguageCode?.lowercased() ?? "") != targetBase }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Translation button with enhanced styling
            if shouldShowTranslationButton {
                translationButton
            }
            
            // Main post content with enhanced typography
            if !post.text.isEmpty {
                #if os(iOS)
                if useUIKitSelectableText && isSelectable {
                    SelectableTextView(
                        attributedString: post.facetsAsAttributedString,
                        textSize: textSize,
                        textStyle: textStyle,
                        textDesign: textDesign,
                        textWeight: textWeight,
                        fontWidth: fontWidth,
                        lineSpacing: lineSpacing,
                        letterSpacing: letterSpacing
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(3)
                    .transition(.opacity)
                    .layoutPriority(1)
                } else {
                    TappableTextView(
                        attributedString: post.facetsAsAttributedString,
                        textSize: textSize,
                        textStyle: textStyle,
                        textDesign: textDesign,
                        textWeight: textWeight,
                        fontWidth: fontWidth,
                        lineSpacing: lineSpacing,
                        letterSpacing: letterSpacing
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .modifier(SelectableModifier(isSelectable: isSelectable))
                    .padding(3)
                    .transition(.opacity)
                    .layoutPriority(1)
                    .modifier(TranslationPresentationIfAvailable(isPresented: $showTranslationPopover, text: post.text))
                }
                #else
                TappableTextView(
                    attributedString: post.facetsAsAttributedString,
                    textSize: textSize,
                    textStyle: textStyle,
                    textDesign: textDesign,
                    textWeight: textWeight,
                    fontWidth: fontWidth,
                    lineSpacing: lineSpacing,
                    letterSpacing: letterSpacing
                )
                .modifier(SelectableModifier(isSelectable: isSelectable))
                .padding(3)
                .transition(.opacity)
                .layoutPriority(1)
                #endif
            }
            
            // Translated text with improved styling
            if showTranslation, let translatedText = translatedText {
                Text(translatedText)
                    .bodyStyle(size: Typography.Size.body, weight: .light, lineHeight: Typography.LineHeight.relaxed)
                    .italic()
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.secondary.opacity(0.1))
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            
            // Translation error with enhanced styling
            if let error = translationError {
                Text(error)
                    .captionStyle(color: .red)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.red.opacity(0.1))
                    )
            }
            
            // Tags with enhanced styling
            if let tags = post.tags, !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(tags, id: \.self) { tag in
                            Text("#\(tag)")
                                .customScaledFont(size: 13, weight: .medium, design: .rounded)
                                .foregroundColor(Color.accentColor)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(Color.accentColor.opacity(0.1))
                                )
                                .onTapGesture {
                                    path.append(NavigationDestination.hashtag(tag))
                                }
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showTranslation && translatedText != nil && translationError == nil)
        .modifier(TranslationTaskModifier(config: translationConfig) { session in
            if #available(iOS 18.0, macCatalyst 26.0, *),
               let translationSession = session as? TranslationSession {
                await performTranslation(session: translationSession)
            }
        })
        .confirmationDialog("Select Language", isPresented: $showLanguageSelection, titleVisibility: .visible) {
            ForEach(sourceLanguages, id: \.languageCode) { language in
                let languageName = Locale.current.localizedString(forLanguageCode: language.languageCode?.identifier ?? "") ?? language.languageCode?.identifier ?? "Unknown"
                Button(languageName) {
                    Task {
                        await setupTranslation(sourceLanguage: language)
                    }
                }
            }
            
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Choose the language to translate from")
        }
    }
    
    private var sourceLanguageCodes: String {
        sourceLanguages
            .compactMap { $0.baseLanguageCode }
            .joined(separator: ", ")
    }
    
    private var targetLanguageCode: String {
        targetLanguage.baseLanguageCode?.lowercased() ?? "en"
    }
    
    // Enhanced translation button with better styling
    private var translationButton: some View {
        Button(action: toggleTranslation) {
            HStack(spacing: 6) {
                if isTranslating {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Translating...")
                        .customScaledFont(size: 12, weight: .medium)
                } else {
                    Image(systemName: showTranslation ? "globe.americas.fill" : "globe.americas")
                        .imageScale(.small)
                    
                    Text(showTranslation ? "Hide Translation" : "Translate")
                        .customScaledFont(size: 12, weight: .medium)
                    
                    Text("(\(sourceLanguageCodes) → \(targetLanguageCode))")
                        .customScaledFont(size: 11, weight: .regular)
                        .foregroundColor(.secondary.opacity(0.8))
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
            )
            .foregroundColor(colorScheme == .dark ? .white.opacity(0.9) : .primary.opacity(0.8))
            .contentShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isTranslating)
    }

    private func toggleTranslation() {
#if os(iOS)
        let hapticFeedback = UIImpactFeedbackGenerator(style: .light)
        hapticFeedback.impactOccurred()
#endif
        
#if targetEnvironment(simulator)
        // Translation models and downloads are not available in Simulator.
        withAnimation {
            translationError = NSLocalizedString("Translation isn’t available in the iOS Simulator. Please test on a physical device.", comment: "")
            showTranslation = false
            translatedText = nil
            translationConfig = nil
        }
        return
#endif
        
        if showTranslation {
            // Hide translation and reset state
            withAnimation {
                showTranslation = false
                translatedText = nil
                translationConfig = nil
                translationError = nil
            }
        } else {
            // Check language situation and handle accordingly
            Task {
                if sourceLanguages.count == 1 {
                    // Case 1: Only one language - use it directly
                    await setupTranslation(sourceLanguage: sourceLanguages[0])
                } else if sourceLanguages.count > 1 {
                    // Case 2: Multiple languages - try to detect
                    if let detectedLanguage = detectTextLanguage() {
                        await setupTranslation(sourceLanguage: detectedLanguage)
                    } else {
                        // Case 3: Couldn't detect, let user choose
                        await MainActor.run {
                            showLanguageSelection = true
                        }
                    }
                } else {
                    // No languages specified
                    await MainActor.run {
                        translationError = NSLocalizedString("Source language not identified.", comment: "")
                    }
                }
            }
        }
    }

    private func detectTextLanguage() -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(post.text)
        
        if let languageCode = recognizer.dominantLanguage?.rawValue {
            return Locale.Language(identifier: languageCode)
        }
        return nil
    }

    private func setupTranslation(sourceLanguage: Locale.Language) async {
        if #available(iOS 18.0, macCatalyst 26.0, *) {
            let availability = LanguageAvailability()
            let status = await availability.status(from: sourceLanguage, to: targetLanguage)
            
            logger.debug("Translation status: \(String(describing: status)) for \(String(describing:sourceLanguage)) -> \(String(describing:targetLanguage))")
            
            await MainActor.run {
                switch status {
                case .installed, .supported:
                    // Proceed with translation - the translationTask modifier will handle model downloads
                    if #available(iOS 18.0, macCatalyst 26.0, *) {
                        let config = TranslationSession.Configuration(source: sourceLanguage, target: targetLanguage)
                        translationConfig = config
                        logger.debug("Translation configuration set")
                    }
                case .unsupported:
                    // Handle unsupported language pairing
                    translationError = NSLocalizedString("Translation not supported for this language pair.", comment: "")
                    logger.debug("Translation unsupported for language pair")
                @unknown default:
                    translationError = NSLocalizedString("Translation not supported for this language pair.", comment: "")
                    logger.debug("Translation status unknown")
                }
            }
        } else {
            await MainActor.run {
                translationError = NSLocalizedString("Translation requires iOS 18.0 or later.", comment: "")
                logger.debug("Translation not available - iOS version too old")
            }
        }
    }
    
    @MainActor @available(iOS 18.0, macCatalyst 26.0, *)
    private func performTranslation(session: TranslationSession) async {
        logger.debug("Starting translation...")
        isTranslating = true
        translationError = nil

        // Try to ensure languages are authorized for download/install first.
        do {
            try await session.prepareTranslation()
        } catch {
            logger.debug("prepareTranslation failed: \(error.localizedDescription)")
            // Continue — we’ll handle errors from translate and retry if appropriate.
        }

        func attemptTranslate() async throws -> String {
            let response = try await session.translate(post.text)
            return response.targetText
        }

        do {
            let target = try await attemptTranslate()
            withAnimation {
                translatedText = target
                showTranslation = true
                translationError = nil
                isTranslating = false
            }
        } catch {
            // If models aren’t installed, prompt and retry once.
            if #available(iOS 26.0, macCatalyst 26.0, *), TranslationError.notInstalled ~= error {
                logger.debug("Translate threw notInstalled; retrying after prepareTranslation prompt…")
                do {
                    try await session.prepareTranslation()
                    let target = try await attemptTranslate()
                    withAnimation {
                        translatedText = target
                        showTranslation = true
                        translationError = nil
                        isTranslating = false
                    }
                    return
                } catch {
                    // Fall through to unified error handling
                }
            }

            logger.debug("Translation error: \(error.localizedDescription)")
            withAnimation {
                if #available(iOS 26.0, macCatalyst 26.0, *), TranslationError.notInstalled ~= error {
                    translationError = NSLocalizedString("On‑device translation languages aren’t installed. When prompted, allow the download and try again.", comment: "")
                } else {
                    let errorMessage = error.localizedDescription
                    let nsError = error as NSError
                    let failureReason = nsError.localizedFailureReason ?? ""
                    let fullErrorText = "\(errorMessage) \(failureReason)"

                    if fullErrorText.contains("Offline models not available") || fullErrorText.localizedCaseInsensitiveContains("models not available") {
                        translationError = NSLocalizedString("On‑device translation languages aren’t installed. Approve the download when prompted, then retry.", comment: "")
                    } else if fullErrorText.contains("network") || fullErrorText.contains("internet") {
                        translationError = NSLocalizedString("Internet connection required to download translation models.", comment: "")
                    } else {
                        translationError = "Translation failed: \(fullErrorText.trimmingCharacters(in: .whitespaces))"
                    }
                }
                isTranslating = false
            }
        }
    }
}

// MARK: - Typography Configuration

extension Post {
    /// Sets the typography configuration for the post text
    func postTypography(design: Font.Design, weight: Font.Weight) -> Self {
        var view = self
        view.postTextDesign = design
        view.postTextWeight = weight
        return view
    }
}

// MARK: - Modifiers

struct TranslationTaskModifier: ViewModifier {
    let config: Any?
    let action: (Any) async -> Void
    
    func body(content: Content) -> some View {
        if #available(iOS 18.0, macCatalyst 26.0, *) {
            if let config = config as? TranslationSession.Configuration {
                content.translationTask(config) { session in
                    await action(session)
                }
            } else {
                content
            }
        } else {
            content
        }
    }
}

// Presents the system translation popover as a fallback when downloads can’t be prompted programmatically (e.g., policy or transient issues).
private struct TranslationPresentationIfAvailable: ViewModifier {
    @Binding var isPresented: Bool
    let text: String

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content
        #else
        if #available(iOS 17.4, *) {
            content.translationPresentation(isPresented: $isPresented, text: text)
        } else {
            content
        }
        #endif
    }
}

struct SelectableModifier: ViewModifier {
    let isSelectable: Bool
    
    func body(content: Content) -> some View {
        if isSelectable {
            content.textSelection(.enabled)
        } else {
            content.textSelection(.disabled)
        }
    }
}

// Extension to extract base language code
extension Locale.Language {
    /// Returns the base language code (e.g., "en" from "en-US")
    var baseLanguageCode: String? {
        return self.languageCode?.identifier
    }
}

//// MARK: - Preview
// #Preview {
//    let mockPost = AppBskyFeedPost(
//        text: "This is a sample post with some #hashtags and @mentions that might need to be displayed properly in the UI.",
//        entities: [],
//        facets: [],
//        reply: nil,
//        embed: nil,
//        langs: [LanguageCodeContainer(languageCode: "en-US")],
//        labels: nil,
//        tags: ["swiftui", "typography", "design"],
//        createdAt: ATProtocolDate(date: Date())
//    )
//
//    VStack {
//        Post(post: mockPost, isSelectable: true, path: .constant(NavigationPath()))
//            .padding()
//            .background(Color(.systemBackground))
//            .cornerRadius(12)
//            .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
//            .padding()
//
//        Post(post: mockPost, isSelectable: true, path: .constant(NavigationPath()))
//            .postTypography(design: .serif, weight: .medium)
//            .padding()
//            .background(Color(.systemBackground))
//            .cornerRadius(12)
//            .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
//            .padding()
//    }
//    .background(Color(.systemGroupedBackground))
// }
