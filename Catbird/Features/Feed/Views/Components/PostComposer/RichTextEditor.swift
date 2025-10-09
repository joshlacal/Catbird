//
//  RichTextEditor.swift
//  Catbird
//
//  Created by Josh LaCalamito on 12/18/23.
//

import SwiftUI
#if os(iOS)
import UIKit
import UniformTypeIdentifiers
#elseif os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

#if os(iOS)
// Data structure for genmoji information
struct GenmojiData {
    let imageData: Data
    let contentDescription: String?
    let range: NSRange
    let uniqueIdentifier: String?
    
    init(from adaptiveGlyph: NSAdaptiveImageGlyph, range: NSRange) {
        self.imageData = adaptiveGlyph.imageContent
        self.contentDescription = adaptiveGlyph.contentDescription
        self.range = range
        // Try to get identifier if available
        if #available(iOS 18.1, *) {
            self.uniqueIdentifier = adaptiveGlyph.contentIdentifier
        } else {
            self.uniqueIdentifier = nil
        }
    }
}

struct RichTextEditor: UIViewRepresentable {
    @Binding var attributedText: NSAttributedString
    var placeholder: String = "What's on your mind?"
    var onImagePasted: ((UIImage) -> Void)?
    var onGenmojiDetected: (([GenmojiData]) -> Void)?
    var onTextChanged: ((NSAttributedString) -> Void)?
    
    func makeUIView(context: Context) -> RichTextView {
        let textView = RichTextView()
        textView.delegate = context.coordinator
        textView.font = UIFont.preferredFont(forTextStyle: UIFont.TextStyle.body)
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsEditingTextAttributes = true
        textView.backgroundColor = .clear
        
        // Enable genmoji support (iOS 18.1+)
        if #available(iOS 18.1, *) {
            textView.supportsAdaptiveImageGlyph = true
        }
        
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        // CRITICAL FIX: Disable automatic data detectors (consistent with RichTextView setup)
        textView.dataDetectorTypes = []
        textView.onImagePasted = onImagePasted
        textView.onGenmojiDetected = onGenmojiDetected
        
        return textView
    }
    
    func updateUIView(_ uiView: RichTextView, context: Context) {
        if uiView.attributedText != attributedText {
            let selectedRange = uiView.selectedRange
            uiView.attributedText = attributedText
            
            if selectedRange.location <= attributedText.length {
                uiView.selectedRange = selectedRange
            }
        }
        
        uiView.onImagePasted = onImagePasted
        uiView.onGenmojiDetected = onGenmojiDetected
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UITextViewDelegate {
        let parent: RichTextEditor
        
        init(_ parent: RichTextEditor) {
            self.parent = parent
        }
        
        func textViewDidChange(_ textView: UITextView) {
            parent.attributedText = textView.attributedText
            parent.onTextChanged?(textView.attributedText)
            
            // Check for genmoji in the text
            if let richTextView = textView as? RichTextView {
                richTextView.detectAndHandleGenmoji()
            }
        }
        
        func textView(_ textView: UITextView, shouldInteractWith textAttachment: NSTextAttachment, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
            return true
        }
        
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            return true
        }
    }
}

class RichTextView: UITextView {
    var onImagePasted: ((UIImage) -> Void)?
    var onGenmojiDetected: (([GenmojiData]) -> Void)?
    
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        setupView()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }
    
    private func setupView() {
        allowsEditingTextAttributes = true
        isEditable = true
        isSelectable = true

        textContainer.lineFragmentPadding = 0
        textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        // CRITICAL FIX: Disable automatic data detectors to prevent interference
        // with manual facet management. URL detection is handled by PostParser
        // which provides more reliable and consistent detection.
        dataDetectorTypes = []
    }
    
    override func paste(_ sender: Any?) {
        logger.debug("📝 RichTextEditor: paste() called")
        
        // ✅ CLEANED: Simple paste handler - text only
        // All media handling is done by PostComposerViewModel.handleMediaPaste()
        
        let pasteboard = UIPasteboard.general
        
        // Only handle text content in the text editor
        if pasteboard.hasStrings {
            logger.debug("📝 Pasting text content")
            super.paste(sender)
        } else {
            logger.debug("📝 Non-text content detected - triggering media paste handler")
            // Trigger the unified media paste handler via callback
            // Use a dummy image to signal that paste was attempted
            onImagePasted?(UIImage())
        }
        
        logger.debug("📝 RichTextEditor: paste() completed")
    }
    
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            let pasteboard = UIPasteboard.general
            
            // Check for images in multiple ways
            if pasteboard.hasImages || pasteboard.hasStrings || pasteboard.hasURLs {
                return true
            }
            
            // Check item providers for image content
            if let itemProvider = pasteboard.itemProviders.first {
                let imageTypes = [UTType.image.identifier, UTType.png.identifier, UTType.jpeg.identifier, UTType.tiff.identifier, UTType.gif.identifier, "public.image"]
                for imageType in imageTypes {
                    if itemProvider.hasItemConformingToTypeIdentifier(imageType) {
                        return true
                    }
                }
            }
            
            // Check pasteboard items directly
            for item in pasteboard.items {
                for imageKey in ["public.image", "public.jpeg", "public.png", "public.tiff", "public.gif"] {
                    if item[imageKey] != nil {
                        return true
                    }
                }
            }
            
            return false
        }
        return super.canPerformAction(action, withSender: sender)
    }
    
    // ✅ CLEANED: Removed insertImage() - RichTextEditor now handles text only
    // All media insertion is handled by PostComposerViewModel
    
    func insertAttributedString(_ attributedString: NSAttributedString) {
        let mutableAttributedText = NSMutableAttributedString(attributedString: attributedText)
        mutableAttributedText.insert(attributedString, at: selectedRange.location)
        attributedText = mutableAttributedText
        selectedRange = NSRange(location: selectedRange.location + attributedString.length, length: 0)
    }
    
    func getPlainText() -> String {
        return attributedText.string
    }
    
    // ✅ CLEANED: Removed image extraction methods - text editor is text-only now
    
    // MARK: - Genmoji Detection and Handling
    
    @available(iOS 18.1, *)
    func extractGenmoji() -> [GenmojiData] {
        var genmojis: [GenmojiData] = []
        let fullRange = NSRange(location: 0, length: attributedText.length)
        
        attributedText.enumerateAttribute(.adaptiveImageGlyph, in: fullRange) { value, range, _ in
            if let adaptiveGlyph = value as? NSAdaptiveImageGlyph {
                let genmojiData = GenmojiData(from: adaptiveGlyph, range: range)
                genmojis.append(genmojiData)
            }
        }
        
        return genmojis
    }
    
    func detectAndHandleGenmoji() {
        guard #available(iOS 18.1, *) else { return }
        
        let genmojis = extractGenmoji()
        if !genmojis.isEmpty {
            onGenmojiDetected?(genmojis)
        }
    }
    
    @available(iOS 18.1, *)
    func getAttributedTextWithoutGenmoji() -> NSAttributedString {
        let mutableAttributedText = NSMutableAttributedString(attributedString: attributedText)
        let fullRange = NSRange(location: 0, length: mutableAttributedText.length)
        
        // Collect genmoji ranges in reverse order to maintain indices during deletion
        var genmojiRanges: [NSRange] = []
        mutableAttributedText.enumerateAttribute(.adaptiveImageGlyph, in: fullRange, options: .reverse) { value, range, _ in
            if value is NSAdaptiveImageGlyph {
                genmojiRanges.append(range)
            }
        }
        
        // Remove genmoji ranges
        for range in genmojiRanges {
            mutableAttributedText.deleteCharacters(in: range)
        }
        
        return mutableAttributedText
    }
    
    func getPlainTextWithoutGenmoji() -> String {
        guard #available(iOS 18.1, *) else {
            return getPlainText()
        }
        
        return getAttributedTextWithoutGenmoji().string
    }
    
    // MARK: - Async Image Paste Handling
    
    private func handleAsyncImagePaste(from itemProvider: NSItemProvider) {
        logger.debug("🍃 handleAsyncImagePaste: Starting async image processing")
        
        let imageTypes = [UTType.image.identifier, UTType.png.identifier, UTType.jpeg.identifier, UTType.tiff.identifier, UTType.gif.identifier, "public.image"]
        
        Task {
            for imageType in imageTypes {
                logger.debug("🍃 Async: Checking type: \(imageType)")
                if itemProvider.hasItemConformingToTypeIdentifier(imageType) {
                    logger.debug("🍃 Async: Found conforming type: \(imageType), loading...")
                    
                    do {
                        let result = try await itemProvider.loadItem(forTypeIdentifier: imageType)
                        logger.debug("🍃 Async: Item loaded, data type: \(type(of: result))")
                        
                        var loadedImage: UIImage?
                        
                        if let imageData = result as? Data {
                            logger.debug("🍃 Async: Got Data, size: \(imageData.count) bytes")
                            loadedImage = UIImage(data: imageData)
                        } else if let image = result as? UIImage {
                            logger.debug("🍃 Async: Got UIImage directly, size: \(image.size.debugDescription)")
                            loadedImage = image
                        } else if let url = result as? URL {
                            logger.debug("🍃 Async: Got URL: \(url)")
                            do {
                                let imageData = try Data(contentsOf: url)
                                logger.debug("🍃 Async: Loaded data from URL, size: \(imageData.count) bytes")
                                loadedImage = UIImage(data: imageData)
                            } catch {
                                logger.debug("🍃 Async: FAILED: Could not load data from URL: \(error)")
                            }
                        }
                        
                        if let image = loadedImage {
                            logger.debug("🍃 Async: SUCCESS: Image loaded, calling callback on main thread")
                            await MainActor.run {
                                onImagePasted?(image)
                            }
                            return // Successfully handled, exit
                        } else {
                            logger.debug("🍃 Async: FAILED: Could not create UIImage from result")
                        }
                    } catch {
                        logger.debug("🍃 Async: Error loading item: \(error)")
                        continue // Try next type
                    }
                } else {
                    logger.debug("🍃 Async: Type \(imageType) not conforming")
                }
            }
            
            logger.debug("🍃 Async: No suitable image type found")
        }
    }
}

extension NSTextAttachment {
    func scaleImageToFit(maxWidth: CGFloat) {
        guard let image = image else { return }
        
        // Validate dimensions to prevent NaN
        let imageWidth = max(image.size.width, 1) // Prevent division by zero
        let imageHeight = max(image.size.height, 1) // Prevent invalid dimensions
        let validMaxWidth = max(maxWidth, 1) // Ensure positive maxWidth
        
        let scale = validMaxWidth / imageWidth
        
        // Only scale if we have valid scale and scale is less than 1
        if scale < 1 && scale > 0 && !scale.isNaN && !scale.isInfinite {
            let scaledWidth = imageWidth * scale
            let scaledHeight = imageHeight * scale
            
            // Validate scaled dimensions
            if scaledWidth > 0 && scaledHeight > 0 && !scaledWidth.isNaN && !scaledHeight.isNaN {
                bounds = CGRect(
                    x: 0, y: 0,
                    width: scaledWidth,
                    height: scaledHeight
                )
            }
        }
    }
}

struct RichTextDisplayView: UIViewRepresentable {
    let attributedText: NSAttributedString
    
    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.dataDetectorTypes = .all
        return textView
    }
    
    func updateUIView(_ uiView: UITextView, context: Context) {
        uiView.attributedText = attributedText
    }
}

#elseif os(macOS)

// macOS stub implementations for RichTextEditor
struct GenmojiData {
    let imageData: Data
    let contentDescription: String?
    let range: NSRange
    let uniqueIdentifier: String?
}

struct RichTextEditor: View {
    @Binding var attributedText: NSAttributedString
    var placeholder: String = "What's on your mind?"
    var onImagePasted: ((NSImage) -> Void)?
    var onGenmojiDetected: (([GenmojiData]) -> Void)?
    var onTextChanged: ((NSAttributedString) -> Void)?
    
    var body: some View {
        // Note: Minimal macOS placeholder; a richer NSViewRepresentable editor can be introduced as needed.
        TextEditor(text: .constant(attributedText.string))
            .frame(minHeight: 100)
    }
}

struct RichTextDisplayView: View {
    let attributedText: NSAttributedString
    
    var body: some View {
        Text(attributedText.string)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#endif
