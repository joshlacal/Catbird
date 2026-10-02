import Foundation
import XCTest
import UIKit
@testable import Catbird

final class EnhancedRichTextEditorUpdateTests: XCTestCase {
    private final class StorageEditRecorder: NSObject, NSTextStorageDelegate {
        var editCount = 0
        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions, range editedRange: NSRange, changeInLength delta: Int) {
            editCount += 1
        }
    }

    private final class CountingTextView: UITextView {
        var sizeThatFitsCallCount = 0
        override func sizeThatFits(_ size: CGSize) -> CGSize {
            sizeThatFitsCallCount += 1
            return super.sizeThatFits(size)
        }
    }

    @MainActor
    func testVisualAttributesSkippedWhenAlreadyEqual() {
        let textView = UITextView()
        let attributed = NSAttributedString(
            string: "Hello world",
            attributes: [.foregroundColor: UIColor.label]
        )
        textView.attributedText = attributed
        
        let recorder = StorageEditRecorder()
        textView.textStorage.delegate = recorder
        
        var heightChanges: [CGFloat] = []
        let editor = EnhancedRichTextEditor(
            attributedText: .constant(attributed),
            linkFacets: .constant([]),
            pendingSelectionRange: .constant(nil),
            placeholder: "",
            onImagePasted: { _ in },
            onGenmojiDetected: { _ in },
            onTextChanged: { _, _ in },
            onLinkCreationRequested: { _, _ in },
            onHeightChange: { heightChanges.append($0) }
        )
        let coordinator = editor.makeCoordinator()
        
        // Initial application when text is equal
        coordinator.applyVisualAttributes(from: attributed, to: textView)
        let editCountAfterFirst = recorder.editCount
        
        // Second call with same source should be an absolute no-op (no NSTextStorage edit)
        coordinator.applyVisualAttributes(from: attributed, to: textView)
        XCTAssertEqual(recorder.editCount, editCountAfterFirst)
    }

    @MainActor
    func testHeightMeasurementAndThresholdBehavior() {
        let textView = CountingTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        textView.text = "Sample text for measurement"
        
        var reportedHeights: [CGFloat] = []
        let editor = EnhancedRichTextEditor(
            attributedText: .constant(NSAttributedString(string: "Sample text for measurement")),
            linkFacets: .constant([]),
            pendingSelectionRange: .constant(nil),
            placeholder: "",
            onImagePasted: { _ in },
            onGenmojiDetected: { _ in },
            onTextChanged: { _, _ in },
            onLinkCreationRequested: { _, _ in },
            onHeightChange: { reportedHeights.append($0) }
        )
        let coordinator = editor.makeCoordinator()
        
        // 1. Initial measurement (initial layout): 1 sizeThatFits call, 1 height report
        coordinator.updateHeight(for: textView, force: true)
        XCTAssertEqual(textView.sizeThatFitsCallCount, 1)
        XCTAssertEqual(reportedHeights.count, 1)
        let initialHeight = reportedHeights[0]
        XCTAssertGreaterThan(initialHeight, 0)
        
        // 2. Delegate text change on same line: measures once, but height is unchanged so callback is suppressed
        textView.text = "Sample text for measurement."
        coordinator.updateHeight(for: textView, force: true)
        XCTAssertEqual(textView.sizeThatFitsCallCount, 2)
        XCTAssertEqual(reportedHeights.count, 1) // No duplicate callback!
        
        // 3. Unrelated SwiftUI updateUIView with same width (force: false): sizeThatFits is NOT called
        coordinator.updateHeight(for: textView, force: false)
        XCTAssertEqual(textView.sizeThatFitsCallCount, 2) // Unchanged!
        XCTAssertEqual(reportedHeights.count, 1)
        
        // 4. Width change (e.g. rotation/resize): sizeThatFits is called even with force: false
        textView.frame = CGRect(x: 0, y: 0, width: 80, height: 100)
        textView.text = "This is a much longer sample text that will definitely wrap across multiple lines at a narrow width."
        coordinator.updateHeight(for: textView, force: false)
        XCTAssertEqual(textView.sizeThatFitsCallCount, 3)
        XCTAssertEqual(reportedHeights.count, 2)
        XCTAssertGreaterThan(reportedHeights[1], initialHeight)
    }
}
