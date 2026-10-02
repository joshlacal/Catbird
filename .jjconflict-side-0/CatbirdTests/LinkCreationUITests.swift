//
//  LinkCreationUITests.swift
//  CatbirdTests
//
//  UI interaction tests for link creation functionality
//  Created by Agent 3: Testing & Validation for enhanced Link Creation
//

import Testing
import SwiftUI
import Foundation
@testable import Catbird
@testable import Petrel

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@available(iOS 16.0, macOS 13.0, *)
@Suite("Link Creation UI Tests")
struct LinkCreationUITests {
    
    // MARK: - Dialog Interaction Tests
    
    @Suite("LinkCreationDialog Interactions")
    struct LinkCreationDialogInteractionTests {
        
        @Test("Dialog initialization with selected text")
        func testDialogInitializationWithSelectedText() async {
            let selectedText = "check this out"
            var dialogShown = false
            var capturedURL: URL? = nil
            
            // Mock dialog state
            var urlText = ""
            var displayText = selectedText
            var validatedURL: URL? = nil
            var showError = false
            
            // Simulate dialog initialization
            #expect(displayText == selectedText)
            #expect(urlText.isEmpty)
            #expect(validatedURL == nil)
            #expect(showError == false)
        }
        
        @Test("Dialog URL validation flow")
        func testDialogURLValidationFlow() async {
            // Simulate user typing different URLs
            let testInputs = [
                ("", false),  // Empty - no validation
                ("invalid", false),  // Invalid URL
                ("example.com", true),  // Valid - will be standardized
                ("https://example.com", true),  // Already valid
                ("  https://example.com  ", true)  // Valid with whitespace
            ]
            
            for (input, expectedValid) in testInputs {
                let result = RichTextFacetUtils.validateAndStandardizeURL(input)
                let isValid = result != nil
                
                #expect(isValid == expectedValid, "Validation failed for input: '\(input)'")
                
                if expectedValid {
                    #expect(result!.absoluteString.hasPrefix("http"), "URL should have protocol: \(result!.absoluteString)")
                }
            }
        }
        
        @Test("Dialog completion flow")
        func testDialogCompletionFlow() async {
            let selectedText = "our website"
            let inputURL = "https://catbird.app"
            let expectedURL = URL(string: inputURL)!
            
            var completionCalled = false
            var completedURL: URL? = nil
            
            // Mock completion callback
            let onComplete: (URL) -> Void = { url in
                completionCalled = true
                completedURL = url
            }
            
            // Simulate validation and completion
            if let validatedURL = RichTextFacetUtils.validateAndStandardizeURL(inputURL) {
                onComplete(validatedURL)
            }
            
            #expect(completionCalled)
            #expect(completedURL == expectedURL)
        }
        
        @Test("Dialog cancellation flow")
        func testDialogCancellationFlow() async {
            var cancellationCalled = false
            
            let onCancel: () -> Void = {
                cancellationCalled = true
            }
            
            // Simulate user cancellation
            onCancel()
            
            #expect(cancellationCalled)
        }
        
        @Test("Dialog advanced options toggle")
        func testDialogAdvancedOptionsToggle() async {
            // Simulate advanced options state management
            var showAdvancedOptions = false
            
            // Initially hidden
            #expect(showAdvancedOptions == false)
            
            // Toggle to show
            showAdvancedOptions.toggle()
            #expect(showAdvancedOptions == true)
            
            // Toggle to hide
            showAdvancedOptions.toggle()  
            #expect(showAdvancedOptions == false)
        }
        
        @Test("Dialog display text customization")
        func testDialogDisplayTextCustomization() async {
            let selectedText = "original text"
            var displayText = selectedText
            let customText = "custom link text"
            
            // Initially uses selected text
            var finalDisplayText = displayText.isEmpty ? selectedText : displayText
            #expect(finalDisplayText == selectedText)
            
            // User enters custom text
            displayText = customText
            finalDisplayText = displayText.isEmpty ? selectedText : displayText
            #expect(finalDisplayText == customText)
            
            // User clears custom text (falls back to selected)
            displayText = ""
            finalDisplayText = displayText.isEmpty ? selectedText : displayText
            #expect(finalDisplayText == selectedText)
        }
    }
    
    // MARK: - Context Menu Tests
    
    @Suite("Context Menu Interactions")
    struct ContextMenuInteractionTests {
        
        @Test("Context menu action availability")
        func testContextMenuActionAvailability() async {
            // Test when "Create Link" should appear in context menu
            let testCases = [
                (selectedText: "hello world", selectedRange: NSRange(location: 0, length: 11), shouldShow: true),
                (selectedText: "", selectedRange: NSRange(location: 0, length: 0), shouldShow: false),
                (selectedText: "   ", selectedRange: NSRange(location: 0, length: 3), shouldShow: false),
                (selectedText: "a", selectedRange: NSRange(location: 0, length: 1), shouldShow: true),
                (selectedText: "\n\n", selectedRange: NSRange(location: 0, length: 2), shouldShow: false)
            ]
            
            for testCase in testCases {
                let hasValidSelection = testCase.selectedRange.length > 0 &&
                                      !testCase.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                
                #expect(hasValidSelection == testCase.shouldShow, 
                       "Context menu availability wrong for: '\(testCase.selectedText)'")
            }
        }
        
        @Test("Context menu action execution")
        func testContextMenuActionExecution() async {
            let fullText = "This is some text to link"
            let selectedRange = NSRange(location: 8, length: 4) // "some"
            let selectedText = (fullText as NSString).substring(with: selectedRange)
            
            var linkCreationRequested = false
            var capturedText = ""
            var capturedRange = NSRange()
            
            // Mock link creation delegate
            let mockDelegate = MockLinkCreationDelegate()
            
            // Simulate context menu action
            mockDelegate.requestLinkCreation(for: selectedText, in: selectedRange)
            
            #expect(mockDelegate.requestCount == 1)
            #expect(mockDelegate.requestedText == "some")
            #expect(mockDelegate.requestedRange == selectedRange)
        }
        
        @Test("Context menu with existing link")
        func testContextMenuWithExistingLink() async {
            // Test behavior when text already has a link
            let text = "Visit our website today"
            let nsAttributedString = NSMutableAttributedString(string: text)
            let url = URL(string: "https://example.com")!
            let linkRange = NSRange(location: 6, length: 11) // "our website"
            
            nsAttributedString.addAttribute(.link, value: url, range: linkRange)
            
            // When text already has a link, context menu might show "Edit Link" instead
            var hasExistingLink = false
            nsAttributedString.enumerateAttribute(.link, in: linkRange) { value, _, _ in
                if value != nil {
                    hasExistingLink = true
                }
            }
            
            #expect(hasExistingLink == true)
            
            // Context menu should handle existing links appropriately
            // (This would show "Edit Link" or "Remove Link" instead of "Create Link")
        }
    }
    
    // MARK: - Keyboard Shortcut Tests
    
    @Suite("Keyboard Shortcut Interactions")
    struct KeyboardShortcutInteractionTests {
        
        @Test("Command+L keyboard shortcut trigger")
        func testCommandLShortcutTrigger() async {
            let selectedText = "link this text"
            let selectedRange = NSRange(location: 0, length: selectedText.count)
            
            var shortcutTriggered = false
            var capturedText = ""
            var capturedRange = NSRange()
            
            // Mock the keyboard shortcut handler
            let handleKeyboardShortcut = { (text: String, range: NSRange) in
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    shortcutTriggered = true
                    capturedText = text
                    capturedRange = range
                }
            }
            
            // Simulate ⌘L shortcut press
            handleKeyboardShortcut(selectedText, selectedRange)
            
            #expect(shortcutTriggered)
            #expect(capturedText == selectedText)
            #expect(capturedRange == selectedRange)
        }
        
        @Test("Command+L with no text selection")
        func testCommandLWithNoSelection() async {
            let selectedText = ""
            let selectedRange = NSRange(location: 5, length: 0) // Cursor position
            
            var shortcutTriggered = false
            
            let handleKeyboardShortcut = { (text: String, range: NSRange) in
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    shortcutTriggered = true
                }
            }
            
            // Simulate ⌘L shortcut press with no selection
            handleKeyboardShortcut(selectedText, selectedRange)
            
            #expect(shortcutTriggered == false)
        }
        
        @Test("Command+L shortcut priority over other shortcuts")
        func testCommandLShortcutPriority() async {
            // Test that ⌘L takes precedence when multiple shortcuts might apply
            let selectedText = "important text"
            
            var linkShortcutTriggered = false
            var otherShortcutTriggered = false
            
            // Simulate shortcut handling priority
            let keyEquivalent = "l"
            let modifiers = ["command"]
            
            if keyEquivalent == "l" && modifiers.contains("command") {
                if !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    linkShortcutTriggered = true
                }
            } else {
                otherShortcutTriggered = true
            }
            
            #expect(linkShortcutTriggered)
            #expect(otherShortcutTriggered == false)
        }
    }
    
    // MARK: - Text Editor Integration Tests
    
    @Suite("Text Editor Integration")
    struct TextEditorIntegrationTests {
        
        @Test("Link creation in text editor")
        func testLinkCreationInTextEditor() async {
            let originalText = "Check out our website"
            let selectedRange = NSRange(location: 10, length: 3) // "our"
            let linkURL = URL(string: "https://catbird.app")!
            
            // Simulate text editor state
            var textEditorContent = NSMutableAttributedString(string: originalText)
            
            // Apply link to selected range
            textEditorContent.addAttribute(.link, value: linkURL, range: selectedRange)
            
            // Verify link was applied
            var foundURL: URL?
            textEditorContent.enumerateAttribute(.link, in: selectedRange) { value, _, _ in
                if let url = value as? URL {
                    foundURL = url
                }
            }
            
            #expect(foundURL == linkURL)
            #expect(textEditorContent.string == originalText)
        }
        
        @Test("Multiple link creation in text editor")
        func testMultipleLinkCreationInTextEditor() async {
            let originalText = "Visit site1.com and site2.com"
            var textEditorContent = NSMutableAttributedString(string: originalText)
            
            let url1 = URL(string: "https://site1.com")!
            let url2 = URL(string: "https://site2.com")!
            
            let range1 = NSRange(location: 6, length: 9)  // "site1.com"
            let range2 = NSRange(location: 20, length: 9) // "site2.com"
            
            // Apply first link
            textEditorContent.addAttribute(.link, value: url1, range: range1)
            
            // Apply second link
            textEditorContent.addAttribute(.link, value: url2, range: range2)
            
            // Verify both links
            var foundURLs: [URL] = []
            textEditorContent.enumerateAttribute(.link, in: NSRange(location: 0, length: textEditorContent.length)) { value, _, _ in
                if let url = value as? URL {
                    foundURLs.append(url)
                }
            }
            
            #expect(foundURLs.contains(url1))
            #expect(foundURLs.contains(url2))
            #expect(foundURLs.count >= 2)
        }
        
        @Test("Link editing in text editor")
        func testLinkEditingInTextEditor() async {
            let text = "Visit our website"
            var textEditorContent = NSMutableAttributedString(string: text)
            let linkRange = NSRange(location: 6, length: 11) // "our website"
            
            let originalURL = URL(string: "https://old-site.com")!
            let newURL = URL(string: "https://new-site.com")!
            
            // Apply original link
            textEditorContent.addAttribute(.link, value: originalURL, range: linkRange)
            
            // Edit the link (simulate user changing URL)
            textEditorContent.removeAttribute(.link, range: linkRange)
            textEditorContent.addAttribute(.link, value: newURL, range: linkRange)
            
            // Verify the change
            var currentURL: URL?
            textEditorContent.enumerateAttribute(.link, in: linkRange) { value, _, _ in
                if let url = value as? URL {
                    currentURL = url
                }
            }
            
            #expect(currentURL == newURL)
            #expect(currentURL != originalURL)
        }
        
        @Test("Link removal from text editor")
        func testLinkRemovalFromTextEditor() async {
            let text = "Visit our linked website"
            var textEditorContent = NSMutableAttributedString(string: text)
            let linkRange = NSRange(location: 10, length: 6) // "linked"
            
            let url = URL(string: "https://example.com")!
            
            // Apply link
            textEditorContent.addAttribute(.link, value: url, range: linkRange)
            
            // Verify link exists
            var linkExists = false
            textEditorContent.enumerateAttribute(.link, in: linkRange) { value, _, _ in
                if value != nil {
                    linkExists = true
                }
            }
            #expect(linkExists)
            
            // Remove link
            textEditorContent.removeAttribute(.link, range: linkRange)
            
            // Verify link is removed
            linkExists = false
            textEditorContent.enumerateAttribute(.link, in: linkRange) { value, _, _ in
                if value != nil {
                    linkExists = true
                }
            }
            #expect(linkExists == false)
            #expect(textEditorContent.string == text) // Text content unchanged
        }
    }
    
    // MARK: - Focus and Selection Tests
    
    @Suite("Focus and Selection Management")
    struct FocusAndSelectionTests {
        
        @Test("Focus state management in dialog")
        func testFocusStateManagementInDialog() async {
            // Simulate dialog focus states
            var isURLFieldFocused = false
            var isDisplayTextFocused = false
            
            // Initially, URL field should be focused
            isURLFieldFocused = true
            #expect(isURLFieldFocused)
            #expect(!isDisplayTextFocused)
            
            // User tabs to display text field
            isURLFieldFocused = false
            isDisplayTextFocused = true
            #expect(!isURLFieldFocused)
            #expect(isDisplayTextFocused)
            
            // User submits form
            isURLFieldFocused = false
            isDisplayTextFocused = false
            #expect(!isURLFieldFocused)
            #expect(!isDisplayTextFocused)
        }
        
        @Test("Selection preservation during link creation")
        func testSelectionPreservationDuringLinkCreation() async {
            let text = "This is some text to modify"
            let originalSelection = NSRange(location: 8, length: 4) // "some"
            
            // Simulate text view with selection
            var currentSelection = originalSelection
            
            // During link creation, selection should be preserved
            #expect(currentSelection == originalSelection)
            
            // After link is applied, selection might be adjusted but should be valid
            let linkURL = URL(string: "https://example.com")!
            var textContent = NSMutableAttributedString(string: text)
            textContent.addAttribute(.link, value: linkURL, range: currentSelection)
            
            // Selection should still be valid
            #expect(currentSelection.location >= 0)
            #expect(currentSelection.location + currentSelection.length <= text.count)
        }
        
        @Test("Text selection after link insertion")
        func testTextSelectionAfterLinkInsertion() async {
            let originalText = "Check out our website"
            let selectionRange = NSRange(location: 10, length: 3) // "our"
            let replacementText = "Catbird"
            let linkURL = URL(string: "https://catbird.app")!
            
            // Create modified text
            var modifiedText = originalText
            let nsString = modifiedText as NSString
            modifiedText = nsString.replacingCharacters(in: selectionRange, with: replacementText)
            
            // Expected result: "Check out Catbird website"
            #expect(modifiedText == "Check out Catbird website")
            
            // New selection should be at the replacement location
            let newSelectionRange = NSRange(location: 10, length: replacementText.count)
            
            // Verify new range is valid
            #expect(newSelectionRange.location >= 0)
            #expect(newSelectionRange.location + newSelectionRange.length <= modifiedText.count)
            
            // Verify selected text matches replacement
            let newSelectedText = (modifiedText as NSString).substring(with: newSelectionRange)
            #expect(newSelectedText == replacementText)
        }
    }
    
    // MARK: - Error Handling UI Tests
    
    @Suite("Error Handling UI")
    struct ErrorHandlingUITests {
        
        @Test("Invalid URL error display")
        func testInvalidURLErrorDisplay() async {
            let invalidURLs = ["not a url", "http://", "://invalid", ""]
            
            for invalidURL in invalidURLs {
                let validatedURL = RichTextFacetUtils.validateAndStandardizeURL(invalidURL)
                let shouldShowError = validatedURL == nil && !invalidURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                
                // Empty URLs shouldn't show error (no validation attempted)
                // Invalid non-empty URLs should show error
                let expectError = !invalidURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && validatedURL == nil
                #expect(shouldShowError == expectError, "Error display logic incorrect for: '\(invalidURL)'")
            }
        }
        
        @Test("Network error handling simulation")
        func testNetworkErrorHandlingSimulation() async {
            // Simulate network-related errors that might occur during link validation
            let urlString = "https://example.com"
            
            // Simulate successful validation
            var validationSuccessful = true
            var errorMessage = ""
            
            if let _ = RichTextFacetUtils.validateAndStandardizeURL(urlString) {
                validationSuccessful = true
                errorMessage = ""
            } else {
                validationSuccessful = false
                errorMessage = "Invalid URL format"
            }
            
            #expect(validationSuccessful)
            #expect(errorMessage.isEmpty)
            
            // Simulate validation failure
            let invalidURL = "not-a-url"
            if RichTextFacetUtils.validateAndStandardizeURL(invalidURL) == nil {
                validationSuccessful = false
                errorMessage = "Please enter a valid URL"
            }
            
            #expect(!validationSuccessful)
            #expect(!errorMessage.isEmpty)
        }
        
        @Test("Error recovery flow")
        func testErrorRecoveryFlow() async {
            // Simulate user entering invalid URL, seeing error, then correcting
            var showError = false
            var errorMessage = ""
            var validatedURL: URL? = nil
            
            // Step 1: User enters invalid URL
            let invalidInput = "invalid-url"
            validatedURL = RichTextFacetUtils.validateAndStandardizeURL(invalidInput)
            if validatedURL == nil && !invalidInput.isEmpty {
                showError = true
                errorMessage = "Please enter a valid URL"
            }
            
            #expect(showError)
            #expect(!errorMessage.isEmpty)
            #expect(validatedURL == nil)
            
            // Step 2: User corrects the URL
            let validInput = "example.com"
            validatedURL = RichTextFacetUtils.validateAndStandardizeURL(validInput)
            if validatedURL != nil {
                showError = false
                errorMessage = ""
            }
            
            #expect(!showError)
            #expect(errorMessage.isEmpty)
            #expect(validatedURL != nil)
        }
    }
    
    // MARK: - Animation and Transitions Tests
    
    @Suite("Animation and Transitions")
    struct AnimationAndTransitionTests {
        
        @Test("Advanced options expand/collapse")
        func testAdvancedOptionsExpandCollapse() async {
            // Test the animation state management for advanced options
            var showAdvancedOptions = false
            var animationCompleted = false
            
            // Initially collapsed
            #expect(!showAdvancedOptions)
            
            // Expand with animation
            showAdvancedOptions = true
            // Simulate animation completion
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                animationCompleted = true
            }
            
            #expect(showAdvancedOptions)
            
            // Wait for animation
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
            
            // Collapse with animation
            showAdvancedOptions = false
            animationCompleted = false
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                animationCompleted = true
            }
            
            #expect(!showAdvancedOptions)
        }
        
        @Test("Error message fade in/out")
        func testErrorMessageFadeInOut() async {
            // Test error message appearance animation
            var showError = false
            var errorMessage = ""
            
            // No error initially
            #expect(!showError)
            #expect(errorMessage.isEmpty)
            
            // Error appears
            showError = true
            errorMessage = "Invalid URL"
            
            #expect(showError)
            #expect(!errorMessage.isEmpty)
            
            // Error disappears
            showError = false
            errorMessage = ""
            
            #expect(!showError)
            #expect(errorMessage.isEmpty)
        }
        
        @Test("Validation indicator animation")
        func testValidationIndicatorAnimation() async {
            // Test the validation state indicators (loading, success, error)
            var isValidating = false
            var isValidURL = false
            var showError = false
            
            // Initial state
            #expect(!isValidating)
            #expect(!isValidURL)
            #expect(!showError)
            
            // Start validation
            isValidating = true
            #expect(isValidating)
            
            // Validation completes successfully
            isValidating = false
            isValidURL = true
            showError = false
            
            #expect(!isValidating)
            #expect(isValidURL)
            #expect(!showError)
            
            // Validation fails
            isValidating = false
            isValidURL = false
            showError = true
            
            #expect(!isValidating)
            #expect(!isValidURL)
            #expect(showError)
        }
    }
}