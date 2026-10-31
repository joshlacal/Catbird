#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import Catbird

/// The fixture itself uses only production presentation components and local data.
/// CatbirdTests is app-hosted: this does not suppress or characterize app startup,
/// account initialization, network traffic, model warmup, or other process activity.
@MainActor
final class AskCatbirdRenderingTests: XCTestCase {
  func testEmptyContextBeforeAndAfter() async throws {
    try await capture(state: FixtureState(), name: "baseline-empty-reconstruction", baseline: true)
    try await capture(state: FixtureState(), name: "candidate-empty-context")
  }

  func testAnswerSourcesAndProposal() async throws {
    let state = FixtureState()
    state.turns = FixtureData.turns
    try await capture(state: state, name: "candidate-answer-sources")
    try await captureSourcesAtBottom(state: state, name: "candidate-sources-visible-light")
    state.turns = [CopilotStoredTurn(role: .assistant, text: "I can help prepare a reply for you to review.",
      proposal: .prepareReply(uri: FixtureData.postURI, cid: "fixture-cid", text: "Thanks for sharing!"))]
    try await capture(state: state, name: "candidate-proposal")
  }

  func testImageSelectedAndUnavailable() async throws {
    let state = FixtureState()
    state.selectedImageID = FixtureData.candidates[0].id
    state.prompt = "What stands out in this image?"
    try await capture(state: state, name: "candidate-image-selected")
    state.selectedImageID = nil
    state.imageUnavailableReason = "Image inspection requires iOS 27 or macOS 27."
    try await capture(state: state, name: "candidate-image-unavailable")
  }

  func testDarkAndAccessibilityText() async throws {
    let state = FixtureState()
    state.turns = FixtureData.turns
    try await capture(state: state, name: "candidate-answer-dark", dark: true)
    try await captureSourcesAtBottom(state: state, name: "candidate-sources-visible-dark", dark: true)
    state.turns = []
    state.imageUnavailableReason = "The on-device model does not support image inspection."
    try await capture(state: state, name: "candidate-accessibility-text", largeText: true)
  }

  func testImageEvidenceAndStreaming() async throws {
    let state = FixtureState()
    state.turns = [
      CopilotStoredTurn(role: .user, text: "Describe this image", selectedImageID: FixtureData.candidates[0].id),
      CopilotStoredTurn(role: .assistant, text: "The image shows flowers beside a garden path.",
        evidence: [.init(origin: "selected_image", text: "Image 1 inspected on device using a resized still image. Other images, video, audio and linked pages were not inspected.", sources: [], wasTruncated: false)])
    ]
    try await capture(state: state, name: "candidate-image-inspected")
    state.turns[1].text = "I can use the supplied image description, but could not inspect this image."
    state.turns[1].evidence = [.init(origin: "selected_image", text: "Image not inspected: The selected image could not be loaded. Available text and attachment metadata only.", sources: [], wasTruncated: false)]
    try await capture(state: state, name: "candidate-image-not-inspected")
    state.turns[1].text = ""
    state.turns[1].evidence = nil
    state.streamingTurnID = state.turns[1].id
    try await capture(state: state, name: "candidate-streaming-stop")
  }

  func testLongNoticeAtAccessibilityText() async throws {
    let state = FixtureState()
    state.notice = "Some earlier messages were left out to keep this conversation within limits. The current question and available context are still included."
    try await capture(state: state, name: "candidate-accessibility-notice", largeText: true)
  }

  func testInlineLinksReachInjectedNativeURLAction() async throws {
    let state = FixtureState()
    let source = CopilotSource(label: "Garden post", uri: FixtureData.postURI)
    let prose = CopilotReferencePresentation.render("Read \(FixtureData.postURI)", sources: [source])
    state.probeURL = try XCTUnwrap(prose.runs.compactMap(\.link).first)
    let host = try makeHost(state: state)
    defer { host.close() }
    await settle(host)
    XCTAssertEqual(state.callbacks, ["url:\(try XCTUnwrap(state.probeURL).absoluteString)"])
    let user = ChatTextRenderer.attributedString(for: "https://bsky.app/profile/maya.example/post/a")
    state.probeURL = try XCTUnwrap(user.runs.compactMap(\.link).first)
    await settle(host)
    XCTAssertEqual(state.callbacks.last, "url:\(try XCTUnwrap(state.probeURL).absoluteString)")
    XCTAssertEqual(state.callbacks.count, 2)
  }

  func testComposerGrowsAndRemainsReachableAboveKeyboard() async throws {
    let state = FixtureState()
    let host = try makeHost(state: state)
    defer { host.close() }
    await settle(host)
    let initial = try XCTUnwrap(state.frames["composer"])
    state.prompt = "Please help me understand this post.\nWhat is the key point?\nWhich details support it?\nSuggest a thoughtful reply."
    await settle(host)
    let grown = try XCTUnwrap(state.frames["composer"])
    XCTAssertGreaterThan(grown.height, initial.height + 30, "Multiline text must expand the native composer")
    XCTAssertEqual(grown.maxY, initial.maxY, accuracy: 1, "Growth must preserve the bottom anchor")
    try attach(host: host, state: state, name: "candidate-growing-input")

    let input = try XCTUnwrap(descendants(host.controller.view).first {
      ($0 is UITextView || $0 is UITextField) && $0.canBecomeFirstResponder
    }, "The real SwiftUI TextField must create a UIKit text input")
    // Resolve the guide on the receiving hosting view before activation so it
    // participates in keyboard layout; a lazily created UIWindow guide is not
    // evidence of this view's keyboard intersection.
    let receivingView = host.controller.view!
    let keyboardGuide = receivingView.keyboardLayoutGuide
    let keyboardReceipt = KeyboardReceipt()
    defer { keyboardReceipt.stop() }
    receivingView.setNeedsLayout()
    receivingView.layoutIfNeeded()
    state.notice = "Some earlier messages were left out to keep this conversation within limits."
    XCTAssertTrue(input.becomeFirstResponder())
    await settle(host, passes: 35)
    XCTAssertTrue(input.isFirstResponder)
    let keyboardFrame = receivingView.convert(keyboardGuide.layoutFrame, to: host.window)
    let shownScreenFrame = try XCTUnwrap(keyboardReceipt.shownFrame,
      "The focused input must produce a software keyboard did-show notification")
    let screen = try XCTUnwrap(host.window.windowScene?.screen)
    let shownWindowFrame = host.window.convert(shownScreenFrame, from: screen.coordinateSpace)
    let visibleKeyboardFrame = shownWindowFrame.intersection(host.window.bounds)
    XCTAssertGreaterThan(keyboardFrame.height, 100,
      "The hosting view keyboard guide must report a visible software keyboard")
    XCTAssertGreaterThan(visibleKeyboardFrame.height, 100,
      "A did-show notification must independently confirm a substantial keyboard intersection")
    let composer = try XCTUnwrap(state.frames["composer"])
    let inputFrame = input.convert(input.bounds, to: host.window)
    XCTAssertLessThanOrEqual(inputFrame.maxY, keyboardFrame.minY + 1,
      "Input must remain above the hosting view's keyboard guide in window coordinates")
    XCTAssertLessThanOrEqual(inputFrame.maxY, visibleKeyboardFrame.minY + 1,
      "Input must also remain above the keyboard's notified visible frame")
    XCTAssertGreaterThan(composer.height, 44)
    try attach(host: host, state: state, name: "candidate-keyboard",
      extra: "firstResponder=\(input.isFirstResponder); inputFrame=\(inputFrame); receivingViewGuide=\(keyboardGuide.layoutFrame); guideInWindow=\(keyboardFrame); didShowScreenFrame=\(shownScreenFrame); notifiedVisibleFrame=\(visibleKeyboardFrame). The host capture excludes the system keyboard's separate window.")
    input.resignFirstResponder()
  }

  private func capture(state: FixtureState, name: String, baseline: Bool = false,
    dark: Bool = false, largeText: Bool = false) async throws {
    let host = try makeHost(state: state, baseline: baseline, dark: dark, largeText: largeText)
    defer { host.close() }
    await settle(host)
    let composer = try XCTUnwrap(state.frames["composer"])
    let transcript = try XCTUnwrap(state.frames["transcript"])
    XCTAssertGreaterThan(composer.height, 44)
    XCTAssertGreaterThan(transcript.height, 80, "Conversation must retain a scrollable viewport")
    XCTAssertGreaterThanOrEqual(composer.minX, 0)
    XCTAssertLessThanOrEqual(composer.maxX, host.window.bounds.width + 1)
    XCTAssertLessThanOrEqual(transcript.maxY, composer.minY + 1, "Transcript and input must not overlap")
    try attach(host: host, state: state, name: name,
      extra: "baselineReconstruction=\(baseline); requestedLargeText=\(largeText); dark=\(dark)")
  }

  /// Scrolls the actual hosted production transcript. The overview capture is
  /// retained separately; source cards are ordinary content below that viewport.
  private func captureSourcesAtBottom(state: FixtureState, name: String, dark: Bool = false) async throws {
    let host = try makeHost(state: state, dark: dark)
    defer { host.close() }
    await settle(host)
    let viewport = try XCTUnwrap(state.frames["transcript"])
    let scroll = try XCTUnwrap(descendants(host.controller.view).compactMap { $0 as? UIScrollView }
      .filter { view in
        !(view is UITextView) && view.bounds.height > 80
          && abs(view.convert(view.bounds, to: host.window).width - viewport.width) < 2
      }.max { $0.bounds.height < $1.bounds.height }, "The production transcript must have a native scroll view")
    // Lazy stacks can update the content size after the first scroll/layout.
    for _ in 0..<3 {
      let bottom = max(-scroll.adjustedContentInset.top,
        scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
      scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: bottom), animated: false)
      await settle(host, passes: 5)
    }
    let visibleViewport = try XCTUnwrap(state.frames["transcript"])
    let rawNativeViewport = scroll.convert(scroll.bounds, to: host.window)
    let adjustedInsets = scroll.adjustedContentInset
    let nativeViewport = scroll.convert(scroll.bounds.inset(by: adjustedInsets), to: host.window)
    let expectedBottom = max(-scroll.adjustedContentInset.top,
      scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
    XCTAssertEqual(scroll.contentOffset.y, expectedBottom, accuracy: 2,
      "The actual production transcript must reach its native content end")
    XCTAssertGreaterThan(nativeViewport.height, 80)
    XCTAssertGreaterThanOrEqual(nativeViewport.minY, visibleViewport.minY - 1)
    XCTAssertLessThanOrEqual(nativeViewport.maxY, visibleViewport.maxY + 1)
    XCTAssertGreaterThanOrEqual(nativeViewport.minX, visibleViewport.minX - 1)
    XCTAssertLessThanOrEqual(nativeViewport.maxX, visibleViewport.maxX + 1)
    try attach(host: host, state: state, name: name,
      extra: "Scrolled production transcript: offset=\(scroll.contentOffset); expectedBottom=\(expectedBottom); contentSize=\(scroll.contentSize); rawNativeViewport=\(rawNativeViewport); adjustedInsets=\(adjustedInsets); effectiveNativeViewport=\(nativeViewport); transcriptViewport=\(visibleViewport). The hosted SwiftUI hierarchy does not expose source AX nodes in-process. This verifies scroll position and viewport geometry only; actual source heading/row visibility requires independent inspection of this PNG. No source touch-frame or VoiceOver pass is claimed. No standalone source recreation.")
  }

  private func makeHost(state: FixtureState, baseline: Bool = false,
    dark: Bool = false, largeText: Bool = false) throws -> Host {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    let controller = UIHostingController(rootView: FixtureScreen(state: state, baseline: baseline)
      .environment(\.dynamicTypeSize, largeText ? .accessibility3 : .large)
      .preferredColorScheme(dark ? .dark : .light))
    controller.overrideUserInterfaceStyle = dark ? .dark : .light
    window.rootViewController = controller
    window.backgroundColor = .systemBackground
    window.makeKeyAndVisible()
    return Host(window: window, controller: controller, previous: previous)
  }

  private func settle(_ host: Host, passes: Int = 12) async {
    for _ in 0..<passes {
      host.window.setNeedsLayout()
      host.window.layoutIfNeeded()
      host.controller.view.layoutIfNeeded()
      try? await Task.sleep(for: .milliseconds(25))
    }
  }

  private func descendants(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap { descendants($0) }
  }

  private func attach(host: Host, state: FixtureState, name: String, extra: String = "") throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    var drewHierarchy = false
    let image = UIGraphicsImageRenderer(bounds: host.window.bounds, format: format).image { _ in
      drewHierarchy = host.window.drawHierarchy(in: host.window.bounds, afterScreenUpdates: true)
    }
    XCTAssertTrue(drewHierarchy)
    let screenshot = XCTAttachment(image: image)
    screenshot.name = "ask-catbird-\(name)"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    let labels = descendants(host.controller.view).compactMap { view -> String? in
      guard let label = view.accessibilityLabel, !label.isEmpty else { return nil }
      return label
    }
    let receipt = """
    Native UIWindow fixture: \(name)
    window=\(host.window.bounds); safeArea=\(host.controller.view.safeAreaInsets)
    geometry=\(state.frames); drawHierarchy=\(drewHierarchy)
    UIKit accessibility labels=\(labels)
    Observed host settings: reduceMotion=\(UIAccessibility.isReduceMotionEnabled); reduceTransparency=\(UIAccessibility.isReduceTransparencyEnabled). These system settings are not forced by this fixture; this capture alone does not establish both settings were exercised.
    \(extra)
    Candidate uses production AskCatbirdTranscript/Composer/Proposal components with fixed local data.
    Baseline is a test-only reconstruction of the frozen empty-state/header/input composition; no claim of the original live sheet.
    The fixture itself does not initiate account/model/network/history operations. Catbird.app hosts the tests; process-wide startup activity is outside this receipt. UIKit label inventory is not a VoiceOver audit.
    """
    let metadata = XCTAttachment(string: receipt)
    metadata.name = "ask-catbird-\(name)-geometry"
    metadata.lifetime = .keepAlways
    add(metadata)
    if let directory = ProcessInfo.processInfo.environment["ASK_CATBIRD_SNAPSHOT_DIR"] {
      let destination = URL(fileURLWithPath: directory, isDirectory: true)
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      try image.pngData()?.write(to: destination.appendingPathComponent("ask-catbird-\(name).png"))
      try receipt.write(to: destination.appendingPathComponent("ask-catbird-\(name).txt"), atomically: true, encoding: .utf8)
    }
  }

  @MainActor
  private final class KeyboardReceipt: NSObject {
    private(set) var shownFrame: CGRect?

    override init() {
      super.init()
      NotificationCenter.default.addObserver(self, selector: #selector(didShow(_:)),
        name: UIResponder.keyboardDidShowNotification, object: nil)
    }

    @objc private func didShow(_ notification: Notification) {
      shownFrame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
    }

    func stop() { NotificationCenter.default.removeObserver(self) }
  }

  @MainActor
  private struct Host {
    let window: UIWindow
    let controller: UIViewController
    let previous: UIWindow?
    func close() {
      window.endEditing(true)
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
    }
  }
}

@MainActor
@Observable
private final class FixtureState {
  var prompt = ""
  var selectedImageID: String?
  var imageUnavailableReason: String?
  var turns: [CopilotStoredTurn] = []
  var streamingTurnID: UUID?
  var notice: String?
  var probeURL: URL?
  var callbacks: [String] = []
  var frames: [String: CGRect] = [:]
}

private struct FixtureScreen: View {
  @Bindable var state: FixtureState
  let baseline: Bool

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if baseline {
          LegacyEmptyPresentation()
            .modifier(FrameProbe(name: "transcript", state: state))
          LegacyInputPresentation(text: $state.prompt)
            .modifier(FrameProbe(name: "composer", state: state))
        } else {
          AskCatbirdTranscript(context: FixtureData.context, turns: state.turns,
            streamingTurnID: state.streamingTurnID, unavailableMessage: nil, onRetry: {},
            onSuggestion: { state.prompt = $0 }, onSource: { state.callbacks.append("source:\($0.uri ?? "")") }) { turn in
              if turn.proposal != nil {
                AskCatbirdProposalCard(confirmation: "Open a reply draft for this post? You can edit it before posting.",
                  isDedicatedFlow: true, isDisabled: false,
                  onConfirm: { state.callbacks.append("confirm") }, onCancel: { state.callbacks.append("dismiss") })
              }
            }
            .modifier(FrameProbe(name: "transcript", state: state))
          if let notice = state.notice {
            AskCatbirdNotice(text: notice, icon: "info.circle", color: .secondary) { state.notice = nil }
          }
          AskCatbirdComposer(text: $state.prompt, selectedImageID: $state.selectedImageID,
            candidates: FixtureData.candidates, imageUnavailableReason: state.imageUnavailableReason,
            isResponding: state.streamingTurnID != nil, isDisabled: state.turns.contains { $0.proposal != nil },
            hasUnresolvedProposal: state.turns.contains { $0.proposal != nil },
            onSend: { state.callbacks.append("send") }, onStop: { state.callbacks.append("stop") })
            .modifier(FrameProbe(name: "composer", state: state))
        }
      }
      .background {
        if let url = state.probeURL { URLActionProbe(url: url).frame(width: 0, height: 0) }
      }
      .modifier(AskCatbirdURLRouting(onOpenURL: { state.callbacks.append("url:\($0.absoluteString)"); return .handled }))
      .navigationTitle("Ask Catbird")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Done") {} }
        ToolbarItem(placement: .primaryAction) {
          Menu { Button("New Chat") {} } label: { Image(systemName: "clock.arrow.circlepath") }
            .accessibilityLabel("Conversation History")
        }
      }
    }
  }
}

/// Exercises the same environment OpenURLAction used by attributed Text links.
/// It invokes a recording handler only; it does not synthesize a physical tap.
private struct URLActionProbe: View {
  @Environment(\.openURL) private var openURL
  let url: URL
  var body: some View {
    Color.clear.task(id: url) { openURL(url) }
  }
}

private struct FrameProbe: ViewModifier {
  let name: String
  let state: FixtureState
  func body(content: Content) -> some View {
    content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
      if state.frames[name] != frame { state.frames[name] = frame }
    }
  }
}

/// Only the old empty layout is reconstructed. The frozen source remains the
/// source of truth; shared chat views require AppState and are intentionally not started.
private struct LegacyEmptyPresentation: View {
  var body: some View {
    VStack(spacing: 0) {
      Label(CopilotReferencePresentation.contextLabel(FixtureData.context), systemImage: "scope")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
      ScrollView {
        LazyVStack(spacing: 8) {
          ContentUnavailableView("Ask About This", systemImage: "sparkles",
            description: Text("Catbird can inspect Bluesky, answer questions, and propose actions for you to confirm."))
            .padding(.top, 40)
        }
        .padding(.vertical, 12)
      }
    }
  }
}

private struct LegacyInputPresentation: View {
  @Binding var text: String
  var body: some View {
    HStack(spacing: 12) {
      TextField("Ask Catbird…", text: $text, axis: .vertical)
        .textFieldStyle(.plain)
        .lineLimit(1...5)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
      Button {} label: {
        Image(systemName: "arrow.up.circle.fill")
          .font(.title2)
          .foregroundStyle(Color.secondary.opacity(0.5))
      }.disabled(true)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .modifier(LegacyInputBackground())
  }
}

private struct LegacyInputBackground: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 26.0, macOS 26.0, *) {
      content.background(.clear)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    } else {
      content.background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Material.regularMaterial))
    }
  }
}

private enum FixtureData {
  static let postURI = "at://did:plc:fixture/app.bsky.feed.post/garden"
  static let context: CopilotContext = {
    let post = CopilotPostEvidence.Post(uri: postURI, cid: "fixture-cid", authorDID: "did:plc:fixture",
      authorHandle: "maya.example", authorName: "Maya Chen",
      text: "The community garden is finally in bloom. We planted native flowers last spring, and the bees are already finding their way back.",
      media: [.init(kind: .image, altText: "Purple coneflowers beside a sunny garden path.")])
    return .post(uri: postURI, cid: "fixture-cid", authorDID: "did:plc:fixture", text: post.text ?? "",
      evidence: CopilotPostEvidence(selectedPost: post, quotedPosts: [], coverage: []))
  }()
  static let candidates = [CopilotImageCandidate(id: "fixture-image-1", label: "Image 1", thumbnailURL: nil,
    altText: "Purple coneflowers beside a sunny garden path.")]
  static let turns = [
    CopilotStoredTurn(role: .user, text: "What is this post about?"),
    CopilotStoredTurn(role: .assistant,
      text: "Maya is celebrating the community garden’s first season of native flowers. She says bees are returning after last spring’s planting.\n\nThe image description mentions purple coneflowers beside a garden path. I have the description, but haven’t inspected the image itself.",
      sources: [CopilotSource(label: "Maya Chen · Community garden in bloom", uri: postURI)])
  ]
}
#endif
