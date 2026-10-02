//
//  LinkAnimationEnhancer.swift
//  Catbird
//
//  Animation and transition enhancements for link creation and editing
//

import SwiftUI
import Foundation
import os

@available(iOS 16.0, macOS 13.0, *)
struct LinkAnimationEnhancer {
    private static let logger = Logger(subsystem: "blue.catbird", category: "LinkAnimation")
    
    // MARK: - Animation Configurations
    
    /// Smooth link creation animation with spring physics
    static let linkCreationAnimation = Animation.interactiveSpring(
        response: 0.4,
        dampingFraction: 0.75,
        blendDuration: 0.1
    )
    
    /// Quick link editing animation for instant feedback
    static let linkEditAnimation = Animation.easeInOut(duration: 0.2)
    
    /// Link removal animation with slight bounce
    static let linkRemovalAnimation = Animation.spring(
        response: 0.3,
        dampingFraction: 0.8,
        blendDuration: 0.05
    )
    
    /// Link preview appearance animation
    static let linkPreviewAnimation = Animation.easeOut(duration: 0.3)
    
    /// Context menu animation
    static let contextMenuAnimation = Animation.easeInOut(duration: 0.15)
    
    // MARK: - Visual Feedback States
    
    struct LinkVisualState {
        var isHighlighted: Bool = false
        var isBeingEdited: Bool = false
        var isCreating: Bool = false
        var opacity: Double = 1.0
        var scale: Double = 1.0
        var glowIntensity: Double = 0.0
    }
    
    // MARK: - Animation State Manager
    
    @MainActor
    @Observable
    final class LinkAnimationStateManager: ObservableObject {
        private let logger = Logger(subsystem: "blue.catbird", category: "LinkAnimation.State")
        
        // MARK: - State Properties
        
        var linkStates: [UUID: LinkVisualState] = [:]
        var isDialogAnimating = false
        var dialogScale: Double = 1.0
        var dialogOpacity: Double = 1.0
        var backgroundBlur: Double = 0.0
        
        // MARK: - Creation Animation
        
        func animateLinkCreation(linkId: UUID) {
            logger.debug("Starting link creation animation for: \(linkId)")
            
            // Initial state
            linkStates[linkId] = LinkVisualState(
                isCreating: true,
                opacity: 0.0,
                scale: 0.8
            )
            
            // Animate to final state
            withAnimation(linkCreationAnimation) {
                linkStates[linkId]?.opacity = 1.0
                linkStates[linkId]?.scale = 1.0
                linkStates[linkId]?.glowIntensity = 0.3
            }
            
            // Remove glow after delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                withAnimation(Animation.easeOut(duration: 0.4)) {
                    self.linkStates[linkId]?.glowIntensity = 0.0
                    self.linkStates[linkId]?.isCreating = false
                }
            }
        }
        
        // MARK: - Edit Animation
        
        func animateLinkEdit(linkId: UUID) {
            logger.debug("Starting link edit animation for: \(linkId)")
            
            linkStates[linkId]?.isBeingEdited = true
            
            withAnimation(linkEditAnimation) {
                linkStates[linkId]?.glowIntensity = 0.5
                linkStates[linkId]?.scale = 1.05
            }
        }
        
        func finishLinkEdit(linkId: UUID) {
            withAnimation(linkEditAnimation) {
                linkStates[linkId]?.glowIntensity = 0.0
                linkStates[linkId]?.scale = 1.0
                linkStates[linkId]?.isBeingEdited = false
            }
        }
        
        // MARK: - Removal Animation
        
        func animateLinkRemoval(linkId: UUID, completion: @escaping () -> Void) {
            logger.debug("Starting link removal animation for: \(linkId)")
            
            withAnimation(linkRemovalAnimation) {
                linkStates[linkId]?.opacity = 0.0
                linkStates[linkId]?.scale = 0.9
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                completion()
                self.linkStates.removeValue(forKey: linkId)
            }
        }
        
        // MARK: - Highlight Animation
        
        func animateLinkHighlight(linkId: UUID, highlighted: Bool) {
            withAnimation(Animation.easeInOut(duration: 0.15)) {
                linkStates[linkId]?.isHighlighted = highlighted
                linkStates[linkId]?.glowIntensity = highlighted ? 0.2 : 0.0
            }
        }
        
        // MARK: - Dialog Animation
        
        func animateDialogPresentation() {
            // Initial state
            isDialogAnimating = true
            dialogScale = 0.9
            dialogOpacity = 0.0
            backgroundBlur = 0.0
            
            // Animate to final state
            withAnimation(linkCreationAnimation) {
                dialogScale = 1.0
                dialogOpacity = 1.0
                backgroundBlur = 1.0
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.isDialogAnimating = false
            }
        }
        
        func animateDialogDismissal(completion: @escaping () -> Void) {
            isDialogAnimating = true
            
            withAnimation(Animation.easeIn(duration: 0.25)) {
                dialogScale = 0.95
                dialogOpacity = 0.0
                backgroundBlur = 0.0
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.isDialogAnimating = false
                completion()
            }
        }
        
        // MARK: - State Cleanup
        
        func cleanupLinkState(linkId: UUID) {
            linkStates.removeValue(forKey: linkId)
        }
        
        func resetAllStates() {
            linkStates.removeAll()
            isDialogAnimating = false
            dialogScale = 1.0
            dialogOpacity = 1.0
            backgroundBlur = 0.0
        }
    }
}

// MARK: - Animated Link Text Modifier

@available(iOS 16.0, macOS 13.0, *)
struct AnimatedLinkModifier: ViewModifier {
    let linkId: UUID
    let visualState: LinkAnimationEnhancer.LinkVisualState
    let isActive: Bool
    
    init(linkId: UUID, visualState: LinkAnimationEnhancer.LinkVisualState, isActive: Bool = true) {
        self.linkId = linkId
        self.visualState = visualState
        self.isActive = isActive
    }
    
    func body(content: Content) -> some View {
        content
            .opacity(isActive ? visualState.opacity : 1.0)
            .scaleEffect(isActive ? visualState.scale : 1.0)
            .background {
                if isActive && visualState.glowIntensity > 0 {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor.opacity(visualState.glowIntensity * 0.3))
                        .blur(radius: 2)
                        .scaleEffect(1.2)
                }
            }
            .overlay {
                if isActive && visualState.isBeingEdited {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.accentColor, lineWidth: 1)
                        .opacity(0.7)
                }
            }
    }
}

// MARK: - Link Creation Dialog Animation Container

@available(iOS 16.0, macOS 13.0, *)
struct LinkCreationDialogContainer<Content: View>: View {
    @StateObject private var animationManager = LinkAnimationEnhancer.LinkAnimationStateManager()
    @Environment(\.dismiss) private var dismiss
    
    let content: Content
    let onDismiss: (() -> Void)?
    
    init(@ViewBuilder content: () -> Content, onDismiss: (() -> Void)? = nil) {
        self.content = content()
        self.onDismiss = onDismiss
    }
    
    var body: some View {
        ZStack {
            // Background blur
            Color.black
                .opacity(0.3 * animationManager.backgroundBlur)
                .ignoresSafeArea()
                .onTapGesture {
                    dismissWithAnimation()
                }
            
            // Dialog content
            content
                .scaleEffect(animationManager.dialogScale)
                .opacity(animationManager.dialogOpacity)
                .background {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.regularMaterial)
                        .shadow(
                            color: .black.opacity(0.1),
                            radius: 20,
                            x: 0,
                            y: 10
                        )
                }
        }
        .onAppear {
            animationManager.animateDialogPresentation()
        }
    }
    
    private func dismissWithAnimation() {
        animationManager.animateDialogDismissal {
            onDismiss?()
            dismiss()
        }
    }
}

// MARK: - Link Preview Animation

@available(iOS 16.0, macOS 13.0, *)
struct LinkPreviewAnimator: View {
    let url: URL
    let isLoading: Bool
    let hasImage: Bool
    
    @State private var imageScale: Double = 0.8
    @State private var textOpacity: Double = 0.0
    @State private var loadingRotation: Double = 0.0
    
    var body: some View {
        HStack(spacing: 12) {
            // Link icon or thumbnail
            Group {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                        .rotationEffect(.degrees(loadingRotation))
                } else if hasImage {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.2))
                        .frame(width: 40, height: 40)
                        .overlay(
                            Image(systemName: "photo")
                                .foregroundColor(.accentColor)
                        )
                        .scaleEffect(imageScale)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 40, height: 40)
                        .overlay(
                            Image(systemName: "link")
                                .foregroundColor(.gray)
                        )
                        .scaleEffect(imageScale)
                }
            }
            .animation(LinkAnimationEnhancer.linkPreviewAnimation, value: isLoading)
            .animation(LinkAnimationEnhancer.linkPreviewAnimation, value: hasImage)
            
            // Link details
            VStack(alignment: .leading, spacing: 4) {
                Text(url.host ?? "Link")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .opacity(textOpacity)
                
                Text(url.absoluteString)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .opacity(textOpacity)
            }
            
            Spacer()
        }
        .onAppear {
            withAnimation(LinkAnimationEnhancer.linkPreviewAnimation.delay(0.1)) {
                imageScale = 1.0
                textOpacity = 1.0
            }
        }
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            if isLoading {
                withAnimation(.linear(duration: 0.5).repeatForever(autoreverses: false)) {
                    loadingRotation += 360
                }
            }
        }
    }
}

// MARK: - Context Menu Animation

@available(iOS 16.0, macOS 13.0, *)
struct AnimatedContextMenu<Content: View>: View {
    let content: Content
    let actions: [LinkContextMenuAction]
    
    @State private var isPresented = false
    @State private var scale: Double = 1.0
    @State private var opacity: Double = 1.0
    
    init(
        actions: [LinkContextMenuAction],
        @ViewBuilder content: () -> Content
    ) {
        self.actions = actions
        self.content = content()
    }
    
    var body: some View {
        content
            .scaleEffect(scale)
            .opacity(opacity)
            .contextMenu {
                ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                    Button(action: {
                        animateAction {
                            action.action()
                        }
                    }) {
                        Label(action.title, systemImage: action.systemImage)
                    }
                    .foregroundColor(action.isDestructive ? .red : .primary)
                }
            } preview: {
                content
                    .scaleEffect(1.1)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
    }
    
    private func animateAction(completion: @escaping () -> Void) {
        withAnimation(LinkAnimationEnhancer.contextMenuAnimation) {
            scale = 0.95
            opacity = 0.8
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(LinkAnimationEnhancer.contextMenuAnimation) {
                self.scale = 1.0
                self.opacity = 1.0
            }
            completion()
        }
    }
}

// MARK: - Link Highlight Animator

@available(iOS 16.0, macOS 13.0, *)
struct LinkHighlightAnimator: ViewModifier {
    let isHighlighted: Bool
    let color: Color
    
    @State private var animationOffset: Double = 0
    
    init(isHighlighted: Bool, color: Color = .accentColor) {
        self.isHighlighted = isHighlighted
        self.color = color
    }
    
    func body(content: Content) -> some View {
        content
            .background {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    color.opacity(0.1),
                                    color.opacity(0.2),
                                    color.opacity(0.1)
                                ]),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .offset(x: animationOffset)
                        .animation(
                            Animation.easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                            value: animationOffset
                        )
                }
            }
            .onChange(of: isHighlighted) { _, newValue in
                if newValue {
                    animationOffset = 10
                } else {
                    animationOffset = 0
                }
            }
    }
}

// MARK: - Extensions

extension View {
    @available(iOS 16.0, macOS 13.0, *)
    func animatedLink(
        id: UUID,
        state: LinkAnimationEnhancer.LinkVisualState,
        isActive: Bool = true
    ) -> some View {
        modifier(AnimatedLinkModifier(linkId: id, visualState: state, isActive: isActive))
    }
    
    @available(iOS 16.0, macOS 13.0, *)
    func linkHighlight(
        isHighlighted: Bool,
        color: Color = .accentColor
    ) -> some View {
        modifier(LinkHighlightAnimator(isHighlighted: isHighlighted, color: color))
    }
}
