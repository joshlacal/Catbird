//
//  PostComposerViewUIKit+MentionOverlay.swift
//  Catbird
//

import SwiftUI
import Petrel
import os
#if os(iOS)
import UIKit
#endif

private let pcMentionLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Catbird", category: "PostComposerMention")

extension PostComposerViewUIKit {
  
  func updateMentionOverlay(vm: PostComposerViewModel, proxy: GeometryProxy) {
    let width = proxy.size.width
    let safeTop = proxy.safeAreaInsets.top
    let horizontalPadding: CGFloat = width >= 600 ? 24 : 16
    let overlayWidth = max(width - (horizontalPadding * 2), 0)
    
    guard Date.now >= mentionOverlayCooldownUntil else { 
      pcMentionLogger.trace("PostComposerMention: Update skipped - in cooldown period")
      return 
    }
    
    if overlayWidth <= 0 || vm.mentionSuggestions.isEmpty {
      pcMentionLogger.debug("PostComposerMention: Hiding mention overlay - width: \(overlayWidth), suggestions: \(vm.mentionSuggestions.count)")
      ComposerMentionOverlayHost.shared.hide()
      return
    }
    
    pcMentionLogger.info("PostComposerMention: Showing mention overlay with \(vm.mentionSuggestions.count) suggestions - width: \(overlayWidth)")
    let offset: CGFloat = vm.parentPost != nil ? 280 : 220
    let content = AnyView(
      UserMentionSuggestionViewResolver(
        suggestions: vm.mappedMentionSuggestions,
        onSuggestionSelected: { suggestion in
          pcMentionLogger.info("PostComposerMention: Mention selected - handle: \(suggestion.profile.handle.description)")
          let newCursorPosition = vm.insertMention(suggestion.profile)
          pendingSelectionRange = NSRange(location: newCursorPosition, length: 0)
          vm.mentionSearchTask?.cancel()
          vm.mentionSuggestions.removeAll()
          mentionOverlayCooldownUntil = Date.now.addingTimeInterval(0.6)
          ComposerMentionOverlayHost.shared.hide()
        },
        onDismiss: {
          pcMentionLogger.info("PostComposerMention: Mention overlay dismissed")
          vm.mentionSuggestions = []
          ComposerMentionOverlayHost.shared.hide()
        },
        enableGlass: false
      )
      .applyAppStateEnvironment(appState)
      .frame(width: overlayWidth)
    )
    ComposerMentionOverlayHost.shared.show(content: content,
                                   horizontalPadding: horizontalPadding,
                                   topInset: safeTop + offset)
  }
  
  @ViewBuilder
  func mentionOverlayView(vm: PostComposerViewModel, proxy: GeometryProxy) -> some View {
    EmptyView()
  }
  
  private func detectMentionRange(in text: String, cursorPos: Int) -> NSRange? {
    guard cursorPos > 0 else { 
      pcMentionLogger.trace("PostComposerMention: detectMentionRange - cursor at start")
      return nil 
    }
    
    let nsText = text as NSString
    var start = cursorPos - 1
    
    while start >= 0 {
      let char = nsText.character(at: start)
      if char == UInt16(UnicodeScalar("@").value) {
        let range = NSRange(location: start, length: cursorPos - start)
        pcMentionLogger.debug("PostComposerMention: detectMentionRange - found @ at \(start), range: \(range)")
        return range
      }
      if let scalar = UnicodeScalar(char), CharacterSet.whitespacesAndNewlines.contains(scalar) {
        pcMentionLogger.trace("PostComposerMention: detectMentionRange - found whitespace, no mention")
        return nil
      }
      start -= 1
    }
    
    pcMentionLogger.trace("PostComposerMention: detectMentionRange - no @ found")
    return nil
  }
}

#if os(iOS)
extension PostComposerViewUIKit {
  final class ComposerMentionOverlayHost {
    static let shared = ComposerMentionOverlayHost()
    private var window: PassthroughWindow?
    private let hosting = UIHostingController(rootView: AnyView(EmptyView()))
    private var activeConstraints: [NSLayoutConstraint] = []
    
    func show(content: AnyView, horizontalPadding: CGFloat, topInset: CGFloat) {
      guard let scene = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .first(where: { $0.activationState == .foregroundActive }) else { 
        pcMentionLogger.warning("PostComposerMention: ComposerMentionOverlayHost - no active scene found")
        return 
      }
      
      let win: PassthroughWindow
      if let existing = window, existing.windowScene == scene {
        win = existing
      } else {
        win = PassthroughWindow(windowScene: scene)
        win.windowLevel = .statusBar + 1
        win.backgroundColor = .clear
        let container = UIViewController()
        container.view.backgroundColor = .clear
        win.rootViewController = container
        window = win
      }
      
      hosting.rootView = content
      hosting.view.backgroundColor = .clear
      hosting.view.translatesAutoresizingMaskIntoConstraints = false
      
      if hosting.view.superview == nil {
        win.rootViewController?.view.addSubview(hosting.view)
      }
      
      NSLayoutConstraint.deactivate(activeConstraints)
      if let root = win.rootViewController?.view {
        activeConstraints = [
          hosting.view.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: horizontalPadding),
          hosting.view.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -horizontalPadding),
          hosting.view.topAnchor.constraint(equalTo: root.topAnchor, constant: topInset)
        ]
        NSLayoutConstraint.activate(activeConstraints)
      }
      
      win.passthroughView = hosting.view
      win.isHidden = false
    }
    
    func hide() {
      pcMentionLogger.debug("PostComposerMention: ComposerMentionOverlayHost - hiding overlay window")
      hosting.rootView = AnyView(EmptyView())
      window?.isHidden = true
    }
  }
  
  final class PassthroughWindow: UIWindow {
    weak var passthroughView: UIView?
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
      guard let target = passthroughView else {
        return nil
      }
      let local = target.convert(point, from: self)
      if target.point(inside: local, with: event) {
        return super.hitTest(point, with: event)
      }
      return nil
    }
  }
}
#else
extension PostComposerViewUIKit {
  final class ComposerMentionOverlayHost {
    static let shared = ComposerMentionOverlayHost()
    func show(content: AnyView, horizontalPadding: CGFloat, topInset: CGFloat) {}
    func hide() {}
  }
}
#endif
