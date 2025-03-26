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

struct Post: View {
    let post: AppBskyFeedPost
    let isSelectable: Bool
    @Binding var path: NavigationPath
    @State private var showTranslation = false
    @State private var translatedText: String?
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var translationError: String?
    @State private var isTranslating = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showLanguageSelection = false

    // public initalizer
    public init(post: AppBskyFeedPost, isSelectable: Bool, path: Binding<NavigationPath>) {
        self.post = post
        self.isSelectable = isSelectable
        self._path = path
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
                TappableTextView(attributedString: post.facetsAsAttributedString)
                //                    .typography(
                //                        design: postTextDesign,
                //                        weight: postTextWeight,
                //                        lineSpacing: Typography.LineHeight.normal,
                //                        letterSpacing: Typography.LetterSpacing.tight
                //                    )
                    .modifier(SelectableModifier(isSelectable: isSelectable))
                    .padding(3)
                    .transition(.opacity)
                    .layoutPriority(1)
            }
            
            // Translated text with improved styling
            if showTranslation, let translatedText = translatedText {
                Text(translatedText)
                    .bodyStyle(weight: .light, lineHeight: Typography.LineHeight.relaxed)
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
                            //                                .customScaledFont(size: 13, weight: .medium, design: .rounded)
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
        .actionSheet(isPresented: $showLanguageSelection) {
            ActionSheet(
                title: Text("Select Language"),
                message: Text("Choose the language to translate from"),
                buttons: sourceLanguages.map { language in
                    let languageName = Locale.current.localizedString(forLanguageCode: language.languageCode?.identifier ?? "") ?? language.languageCode?.identifier ?? "Unknown"
                    return .default(Text(languageName)) {
                        Task {
                            await setupTranslation(sourceLanguage: language)
                        }
                    }
                } + [.cancel()]
            )
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
        .translationTask(translationConfig) { session in
            
            await performTranslation(session: session)
        }
    }
    

    private func toggleTranslation() {
        let hapticFeedback = UIImpactFeedbackGenerator(style: .light)
        hapticFeedback.impactOccurred()
        
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
        let availability = LanguageAvailability()
        let status = await availability.status(from: sourceLanguage, to: targetLanguage)
        
        await MainActor.run {
            switch status {
            case .installed, .supported:
                // Proceed with translation
                translationConfig = .init(source: sourceLanguage, target: targetLanguage)
            case .unsupported:
                // Handle unsupported language pairing
                translationError = NSLocalizedString("Translation not supported for this language pair.", comment: "")
            @unknown default:
                translationError = NSLocalizedString("Translation not supported for this language pair.", comment: "")
            }
        }
    }
    
    private func performTranslation(session: TranslationSession) async {
        do {
            await MainActor.run {
                isTranslating = true
            }
            
            let response = try await session.translate(post.text)
            
            await MainActor.run {
                withAnimation {
                    translatedText = response.targetText
                    showTranslation = true
                    translationError = nil
                    isTranslating = false
                }
            }
        } catch {
            print("Translation error: \(error)")
            await MainActor.run {
                withAnimation {
                    translationError = NSLocalizedString("Failed to translate. Please try again later.", comment: "")
                    isTranslating = false
                }
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

struct SelectableModifier: ViewModifier {
    let isSelectable: Bool
    
    func body(content: Content) -> some View {
        if isSelectable {
            content.textSelection(.enabled)
        } else {
            content
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
//#Preview {
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
//}
