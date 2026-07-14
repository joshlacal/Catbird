//
//  ComposerAccessoryBar.swift
//  Catbird
//

import SwiftUI

struct ComposerBarActions {
  let onPhotos: () -> Void
  let onVideo: () -> Void
  let onGif: () -> Void
  let onAudio: () -> Void
  let onLink: () -> Void
  let onThreadgate: () -> Void
  let onLanguage: () -> Void
  let onTags: () -> Void
  let onLabels: () -> Void
  let onAddToThread: () -> Void
}

struct ComposerAccessoryBar: View {
  @Binding var isPlusMenuOpen: Bool
  let characterCount: Int
  let allowTenor: Bool
  let threadgateValue: String
  let languageValue: String
  let actions: ComposerBarActions

  @Namespace private var glassNamespace
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AccessibilityFocusState private var menuFocused: Bool

  var body: some View {
    #if os(iOS)
    if #available(iOS 26.0, *) {
      glassBar
    } else {
      legacyBar
    }
    #else
    legacyBar
    #endif
  }

  #if os(iOS)
  @available(iOS 26.0, *)
  private var glassBar: some View {
    GlassEffectContainer(spacing: 8) {
      HStack {
        plusButton
          .padding(4)
          .glassEffect(.regular.interactive())
          .glassEffectID("plus", in: glassNamespace)

        Spacer()

        trailingControls
          .padding(.horizontal, 4)
          .glassEffect(.regular.interactive())
          .glassEffectID("controls", in: glassNamespace)
      }
      .overlay(alignment: .bottomLeading) {
        if isPlusMenuOpen {
          plusMenu
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .glassEffectID("plusMenu", in: glassNamespace)
            .glassEffectTransition(.matchedGeometry)
            .padding(.bottom, 56)
        }
      }
    }
  }
  #endif

  private var legacyBar: some View {
    HStack {
      Menu {
        attachmentMenuItems
        Divider()
        settingsMenuItems
      } label: {
        Image(systemName: "plus")
          .font(.system(size: 17, weight: .semibold))
          .frame(width: 44, height: 44)
      }
      .background(Circle().fill(.ultraThinMaterial))
      .accessibilityLabel("Add attachment or post settings")

      Spacer()

      trailingControls
        .background(Capsule().fill(.ultraThinMaterial))
    }
  }

  private var plusButton: some View {
    Button(action: { setMenu(!isPlusMenuOpen) }) {
      Image(systemName: "plus")
        .font(.system(size: 17, weight: .semibold))
        .frame(width: 36, height: 36)
        .rotationEffect(.degrees(isPlusMenuOpen ? 45 : 0))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(isPlusMenuOpen ? "Close menu" : "Add attachment or post settings")
    .accessibilityValue(isPlusMenuOpen ? "Expanded" : "Collapsed")
  }

  private var trailingControls: some View {
    HStack(spacing: 14) {
      Button {
        setMenu(false)
        actions.onAddToThread()
      } label: {
        Image(systemName: "plus.square.on.square")
          .font(.system(size: 16))
          .frame(width: 36, height: 36)
          .padding(4)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Add another post to thread")

      CharacterLimitIndicatorWrapper(currentCount: characterCount)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
  }

  private var plusMenu: some View {
    VStack(alignment: .leading, spacing: 0) {
      menuRow("Photos", systemImage: "photo", action: actions.onPhotos)
      menuRow("Video", systemImage: "video", action: actions.onVideo)
      if allowTenor {
        menuRow("GIF", systemImage: "play.rectangle", action: actions.onGif)
      }
      menuRow("Audio", systemImage: "mic", action: actions.onAudio)
      menuRow("Link", systemImage: "link", action: actions.onLink)

      Divider()
        .padding(.horizontal, 14)
        .padding(.vertical, 4)

      menuRow(
        "Who can reply",
        systemImage: "bubble.left.and.bubble.right",
        value: threadgateValue,
        action: actions.onThreadgate
      )
      menuRow("Language", systemImage: "globe", value: languageValue, action: actions.onLanguage)
      menuRow("Hashtags", systemImage: "number", action: actions.onTags)
      menuRow(
        "Content label",
        systemImage: "exclamationmark.triangle",
        action: actions.onLabels
      )
    }
    .padding(.vertical, 8)
    .frame(minWidth: 250, alignment: .leading)
    .fixedSize(horizontal: true, vertical: false)
    .accessibilityFocused($menuFocused)
    .accessibilityAction(.escape) { setMenu(false) }
  }

  @ViewBuilder
  private var attachmentMenuItems: some View {
    Button(action: actions.onPhotos) { Label("Photos", systemImage: "photo") }
    Button(action: actions.onVideo) { Label("Video", systemImage: "video") }
    if allowTenor {
      Button(action: actions.onGif) { Label("GIF", systemImage: "play.rectangle") }
    }
    Button(action: actions.onAudio) { Label("Audio", systemImage: "mic") }
    Button(action: actions.onLink) { Label("Link", systemImage: "link") }
  }

  @ViewBuilder
  private var settingsMenuItems: some View {
    Button(action: actions.onThreadgate) {
      Label("Who can reply", systemImage: "bubble.left.and.bubble.right")
      Text(threadgateValue)
    }
    Button(action: actions.onLanguage) {
      Label("Language", systemImage: "globe")
      Text(languageValue)
    }
    Button(action: actions.onTags) { Label("Hashtags", systemImage: "number") }
    Button(action: actions.onLabels) {
      Label("Content label", systemImage: "exclamationmark.triangle")
    }
  }

  private func menuRow(
    _ title: String,
    systemImage: String,
    value: String? = nil,
    action: @escaping () -> Void
  ) -> some View {
    Button {
      setMenu(false)
      action()
    } label: {
      HStack(spacing: 12) {
        Image(systemName: systemImage)
          .appFont(AppTextRole.body)
          .foregroundStyle(Color.accentColor)
          .frame(width: 26)
        Text(title)
          .appFont(AppTextRole.body)
          .foregroundStyle(.primary)
        Spacer(minLength: 12)
        if let value {
          Text(value)
            .appFont(AppTextRole.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 11)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(value.map { "\(title), currently \($0)" } ?? title)
  }

  static func menuAnimation(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)
  }

  private func setMenu(_ isOpen: Bool) {
    withAnimation(Self.menuAnimation(reduceMotion: reduceMotion)) {
      isPlusMenuOpen = isOpen
    }
    if isOpen {
      menuFocused = true
    }
  }
}
