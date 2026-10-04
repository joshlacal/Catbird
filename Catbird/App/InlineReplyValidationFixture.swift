#if DEBUG && os(iOS)
import Foundation
@testable import Petrel
import SwiftData
import SwiftUI
import UIKit

/// Local data enters the ordinary scene sheet, composer creation and editing lease.
/// The probe observes UIKit and recovery bytes; it never writes editor/model state.
@MainActor
struct InlineReplyValidationFixture: View {
  static let launchArgument = "--inline-reply-ui-fixture"
  static let accountDID = "did:plc:inlinereplyfixtureviewer"
  static let sourceURI = "at://did:plc:inlinereplyfixtureauthor/app.bsky.feed.post/inline-source"
  static let sourceStart = "Inline source start marker."
  static let sourceEnd = "Inline source end marker."

  @State private var appState: AppState?
  @State private var context: SceneNavigationContext?
  @State private var source: AppBskyFeedDefs.PostView?
  @State private var container: ModelContainer?
  @State private var defaults: UserDefaults?
  @State private var issue: String?

  var body: some View {
    Group {
      if let appState, let context, let source, let defaults {
        SceneNavigationHost(appState: appState, appStateManager: .shared, context: context) {
          NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
              Text("Offline inline reply validation").font(.headline)
              Text("Local source, in-memory draft library and isolated session recovery. No authenticated account or external transport.")
                .font(.caption)
              Button("Reply to local source") {
                context.presentPostComposer(parentPost: source)
              }
              .accessibilityIdentifier("inline-reply.open")
              Button("Open new post") { context.presentPostComposer() }
                .accessibilityIdentifier("inline-reply.new-post")
              if let claim = context.composerEditingSession.activeClaim,
                 context.composerEditingSession.isMinimized {
                Button("Resume local reply") {
                  guard context.composerEditingSession.resume(claim: claim) else { return }
                  context.postComposerRequest = ScenePostComposerRequest(editingClaim: claim)
                }
                .accessibilityIdentifier("inline-reply.resume")
              }
              Spacer()
            }
            .padding()
            .navigationTitle("Inline Reply Fixture")
          }
          .background {
            InlineReplyNativeProbe(session: context.composerEditingSession,
                                   defaults: defaults, appState: appState)
              .frame(width: 0, height: 0)
              .accessibilityHidden(true)
          }
        }
      } else if let issue {
        Text(issue).accessibilityIdentifier("inline-reply.error")
      } else {
        ProgressView("Preparing offline reply")
      }
    }
    .task { await prepare() }
  }

  private func prepare() async {
    guard appState == nil else { return }
    do {
      let (source, response) = try makeSource()
      InlineReplyLocalProtocol.configure(response: response)
      guard URLProtocol.registerClass(InlineReplyLocalProtocol.self) else {
        throw FixtureError.transportRegistration
      }
      await NetworkService.setNetworkTestProtocolClasses([InlineReplyLocalProtocol.self])
      let client = await ATProtoClient(baseURL: URL(string: "https://127.0.0.1")!)
      let state = AppState(userDID: Self.accountDID, client: client,
                           regulatoryChecker: NoAgePrompt())
      state.currentUserProfile = try JSONDecoder().decode(AppBskyActorDefs.ProfileViewBasic.self, from:
        Data(#"{"did":"did:plc:inlinereplyfixtureviewer","handle":"reply-viewer.test","displayName":"Local Reply Writer"}"#.utf8))
      let memory = try ModelContainer(for: DraftPost.self, Preferences.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
      let isolated = UserDefaults(suiteName: "InlineReplyValidation.\(UUID().uuidString)")!
      state.composerDraftManager.configureForTesting(modelContext: memory.mainContext)
      let manager = ComposerDraftManager(accountDID: Self.accountDID,
        modelContext: memory.mainContext, defaults: isolated)
      state.composerDraftManager = manager
      state.preferencesManager.setModelContext(memory.mainContext)
      // A separate library row exposes the production Drafts toolbar control.
      try manager.createSavedDraft(Self.libraryDraft(), accountDID: Self.accountDID)
      let sceneID = UUID()
      let session = SceneComposerEditingSession(manager: manager, accountDID: Self.accountDID,
        sceneID: sceneID, defaults: isolated)
      let navigation = SceneNavigationContext(appState: state, sceneID: sceneID,
                                             composerEditingSession: session)
      guard !Task.isCancelled else { return }
      self.container = memory
      self.defaults = isolated
      self.source = source
      self.context = navigation
      self.appState = state
    } catch {
      issue = "Inline reply fixture could not prepare: \(error.localizedDescription)"
    }
  }

  private func makeSource() throws -> (AppBskyFeedDefs.PostView, Data) {
    // Newline-heavy source stays within the protocol's 300-grapheme post limit.
    let text = ([Self.sourceStart] + Array(repeating: "Context.", count: 24)
      + [Self.sourceEnd]).joined(separator: "\n\n")
    let post: [String: Any] = [
      "uri": Self.sourceURI,
      "cid": CID.fromDAGCBOR(Data("inline-reply-source".utf8)).string,
      "author": ["did": "did:plc:inlinereplyfixtureauthor", "handle": "inline-source.test",
                 "displayName": "Inline Original Source"],
      "record": ["$type": "app.bsky.feed.post", "text": text, "createdAt": "2026-01-01T00:00:00Z"],
      "indexedAt": "2026-01-01T00:00:00Z",
    ]
    let decoded = try JSONDecoder().decode(AppBskyFeedDefs.PostView.self,
      from: JSONSerialization.data(withJSONObject: post))
    return (decoded, try JSONSerialization.data(withJSONObject: ["posts": [post]]))
  }

  private static func libraryDraft() -> PostComposerDraft {
    PostComposerDraft(postText: "Independent local saved draft", mediaItems: [], videoItem: nil,
      selectedGif: nil, selectedLanguages: [], selectedLabels: [], outlineTags: [], threadEntries: [],
      isThreadMode: false, currentThreadIndex: 0, parentPostURI: nil, quotedPostURI: nil)
  }

  private enum FixtureError: Error { case transportRegistration }
  private struct NoAgePrompt: AgeRegulatoryChecking {
    func preflight() async -> PlatformAgeSignal {
      PlatformAgeSignal(requirement: .none, ageBand: nil, significantChangeConsentRequired: false)
    }
    @MainActor
    func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
  }
}

/// All HTTP(S) requests terminate locally, including unexpected hosts and writes.
/// Only the source hydration read receives a response; no real service is contacted.
private final class InlineReplyLocalProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var sourceResponse = Data()
  nonisolated(unsafe) private static var sourceReads = 0
  nonisolated(unsafe) private static var refusedRequests = 0
  private var responseWork: DispatchWorkItem?

  static func configure(response: Data) {
    lock.withLock { sourceResponse = response; sourceReads = 0; refusedRequests = 0 }
  }

  static var counts: (reads: Int, refused: Int) {
    lock.withLock { (sourceReads, refusedRequests) }
  }

  override class func canInit(with request: URLRequest) -> Bool {
    ["http", "https"].contains(request.url?.scheme?.lowercased() ?? "")
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url, url.scheme == "https", url.host == "127.0.0.1",
          url.port == nil, url.user == nil, url.password == nil, url.fragment == nil,
          request.httpMethod == "GET", request.httpBody == nil, request.httpBodyStream == nil,
          url.path == "/xrpc/app.bsky.feed.getPosts",
          let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
          query == [URLQueryItem(name: "uris",
            value: "at://did:plc:inlinereplyfixtureauthor/app.bsky.feed.post/inline-source")] else {
      Self.lock.withLock { Self.refusedRequests += 1 }
      client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
      return
    }
    let data = Self.lock.withLock { Self.sourceReads += 1; return Self.sourceResponse }
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                     headerFields: ["Content-Type": "application/json"])!
      self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      self.client?.urlProtocol(self, didLoad: data)
      self.client?.urlProtocolDidFinishLoading(self)
    }
    responseWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
  }
  override func stopLoading() { responseWork?.cancel(); responseWork = nil }
}

/// Adapted from the historical R6 editor probe, without its injected view-model bypass.
private struct InlineReplyNativeProbe: UIViewRepresentable {
  let session: SceneComposerEditingSession
  let defaults: UserDefaults
  let appState: AppState

  func makeUIView(context: Context) -> ProbeView {
    let view = ProbeView()
    view.session = session
    view.defaults = defaults
    view.appState = appState
    return view
  }
  func updateUIView(_ uiView: ProbeView, context: Context) { uiView.publish() }
  static func dismantleUIView(_ uiView: ProbeView, coordinator: ()) { uiView.stop() }

  @MainActor
  final class ProbeView: UIView {
    var session: SceneComposerEditingSession?
    var defaults: UserDefaults?
    weak var appState: AppState?
    private var timer: Timer?
    private let oracle = UILabel()

    override func didMoveToWindow() {
      super.didMoveToWindow()
      stop()
      guard window != nil else { return }
      oracle.isAccessibilityElement = true
      oracle.accessibilityIdentifier = "inline-reply.probe"
      oracle.font = .systemFont(ofSize: 1)
      oracle.textColor = .clear
      oracle.isUserInteractionEnabled = false
      timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.publish() }
      }
      publish()
    }
    func stop() { timer?.invalidate(); timer = nil; oracle.removeFromSuperview() }

    func publish() {
      guard let window, let session, let defaults else { return }
      var presenter = window.rootViewController
      while let next = presenter?.presentedViewController, !next.isBeingDismissed { presenter = next }
      guard let surface = presenter?.view else { return }
      if oracle.superview !== surface {
        oracle.removeFromSuperview()
        surface.addSubview(oracle)
      }
      oracle.frame = CGRect(x: surface.bounds.midX, y: surface.safeAreaInsets.top + 1, width: 1, height: 1)
      let textViews = descendants(of: surface).compactMap { $0 as? UITextView }
      let editors = textViews.filter { $0.isEditable && !$0.isHidden && $0.alpha > 0 }
      let editor = editors.first(where: \.isFirstResponder) ?? editors.first
      let recovery = defaults.data(forKey: SceneComposerEditingSession.persistenceKey(
        sceneID: session.sceneID, accountDID: session.accountDID))
      let envelope = recovery.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
      let savedBody = envelope?["draft"] as? [String: Any]
      let counts = InlineReplyLocalProtocol.counts
      var data: [String: Any] = [
        "claim": session.activeClaim?.token.uuidString ?? "none",
        "minimized": session.isMinimized,
        "draftText": session.currentDraft?.postText ?? "",
        "parentURI": session.currentDraft?.parentPostURI ?? "none",
        "hasDraft": session.currentDraft != nil,
        "hasRecovery": recovery != nil,
        "persistedText": savedBody?["postText"] as? String ?? "",
        "persistedParentURI": savedBody?["parentPostURI"] as? String ?? "none",
        "savedCount": appState?.composerDraftManager.savedDrafts.count ?? 0,
        "systemCategory": UIApplication.shared.preferredContentSizeCategory.rawValue,
        "fontCategory": appState?.fontManager.currentContentSizeCategory.rawValue ?? "unknown",
        "sourceReads": counts.reads, "refusedRequests": counts.refused,
        "editorCount": editors.count,
        "windowWidth": window.bounds.width, "windowHeight": window.bounds.height,
        "interfaceOrientation": window.windowScene?.interfaceOrientation.rawValue ?? 0,
      ]
      if let editor {
        for inactive in editors where inactive !== editor && inactive.accessibilityIdentifier == "inline-reply.editor" {
          inactive.accessibilityIdentifier = "inline-reply.inactive-editor"
        }
        editor.accessibilityIdentifier = "inline-reply.editor"
        data["identity"] = String(describing: ObjectIdentifier(editor))
        data["focused"] = editor.isFirstResponder
        data["text"] = editor.text ?? ""
        data["selectionStart"] = editor.selectedRange.location
        data["selectionLength"] = editor.selectedRange.length
        data["editorFrame"] = NSCoder.string(for: editor.convert(editor.bounds, to: window))
        let viewport = readingViewport(for: editor, window: window)
        data["editorReadingViewport"] = NSCoder.string(for: viewport)
        data["editorScrollInsets"] = scrollInsets(for: editor)

        let wholeText = editor.textRange(from: editor.beginningOfDocument, to: editor.endOfDocument)
        let glyphs = wholeText.map { selectionFrames($0, in: editor, window: window) } ?? []
        let caret = editor.selectedTextRange.map { editor.convert(editor.caretRect(for: $0.end), to: window) }
        data["editorGlyphFrames"] = glyphs.map { NSCoder.string(for: $0) }
        data["editorCaretFrame"] = caret.map { NSCoder.string(for: $0) } ?? "none"
        data["editorTextAndCaretVisible"] = !glyphs.isEmpty && glyphs.allSatisfy { viewport.contains($0) }
          && caret.map { !$0.isEmpty && viewport.contains($0) } == true

      }
      if let original = textViews.first(where: { !$0.isEditable && ($0.text ?? "").contains(InlineReplyValidationFixture.sourceStart) }) {
        data["sourceReadingViewport"] = NSCoder.string(for: readingViewport(for: original, window: window))
        data["sourceScrollInsets"] = scrollInsets(for: original)
        data["sourceStartGlyphFrames"] = markerFrames(InlineReplyValidationFixture.sourceStart, in: original, window: window)
          .map { NSCoder.string(for: $0) }
        data["sourceEndGlyphFrames"] = markerFrames(InlineReplyValidationFixture.sourceEnd, in: original, window: window)
          .map { NSCoder.string(for: $0) }
        data["sourceStartVisible"] = markerVisible(InlineReplyValidationFixture.sourceStart, in: original, window: window)
        data["sourceEndVisible"] = markerVisible(InlineReplyValidationFixture.sourceEnd, in: original, window: window)
      } else {
        data["sourceStartVisible"] = false
        data["sourceEndVisible"] = false
      }
      guard let encoded = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]) else { return }
      oracle.accessibilityLabel = String(decoding: encoded, as: UTF8.self)
    }

    private func descendants(of view: UIView) -> [UIView] {
      [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func selectionFrames(_ range: UITextRange, in textView: UITextView,
                                 window: UIWindow) -> [CGRect] {
      textView.selectionRects(for: range).map { textView.convert($0.rect, to: window) }
        .filter { !$0.isEmpty && !$0.isNull && !$0.isInfinite }
    }

    private func readingViewport(for textView: UITextView, window: UIWindow) -> CGRect {
      var visible = window.bounds
      var responder: UIResponder? = textView
      while responder != nil && !(responder is UIViewController) { responder = responder?.next }
      guard let presenter = responder as? UIViewController else { return .null }
      let surface = presenter.view!
      let keyboard = surface.convert(surface.keyboardLayoutGuide.layoutFrame, to: window)
      if keyboard.minY < visible.maxY { visible.size.height = max(0, keyboard.minY - visible.minY) }
      if let bar = presenter.navigationController?.navigationBar, !bar.isHidden {
        let bottom = bar.convert(bar.bounds, to: window).maxY
        visible = visible.intersection(CGRect(x: visible.minX, y: bottom,
          width: visible.width, height: max(0, visible.maxY - bottom)))
      }
      var ancestor: UIView? = textView
      var observedOuterScroll = false
      while let current = ancestor {
        if current.isHidden || current.alpha == 0 { return .null }
        if current.clipsToBounds { visible = visible.intersection(current.convert(current.bounds, to: window)) }
        if let scroll = current as? UIScrollView, scroll !== textView,
           scroll.contentSize.height > scroll.bounds.height {
          // Record UIKit's actual receiving inset; the XCTest independently excludes
          // measured AX sibling footer controls even if this inset is zero.
          let inset = scroll.adjustedContentInset
          visible = visible.intersection(scroll.convert(scroll.bounds.inset(by: inset), to: window))
          observedOuterScroll = true
        }
        ancestor = current.superview
      }
      return observedOuterScroll ? visible : .null
    }

    private func scrollInsets(for textView: UITextView) -> [[String: Any]] {
      var observations: [[String: Any]] = []
      var ancestor: UIView? = textView.superview
      while let current = ancestor {
        if let scroll = current as? UIScrollView {
          let inset = scroll.adjustedContentInset
          observations.append(["bounds": NSCoder.string(for: scroll.bounds),
            "contentSize": NSCoder.string(for: scroll.contentSize),
            "adjustedTop": inset.top, "adjustedBottom": inset.bottom,
            "adjustedLeft": inset.left, "adjustedRight": inset.right])
        }
        ancestor = current.superview
      }
      return observations
    }

    private func markerFrames(_ marker: String, in textView: UITextView, window: UIWindow) -> [CGRect] {
      let range = (textView.text as NSString).range(of: marker)
      guard range.location != NSNotFound,
            let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
            let end = textView.position(from: start, offset: range.length),
            let textRange = textView.textRange(from: start, to: end) else { return [] }
      return selectionFrames(textRange, in: textView, window: window)
    }

    private func markerVisible(_ marker: String, in textView: UITextView, window: UIWindow) -> Bool {
      let glyphs = markerFrames(marker, in: textView, window: window)
      let viewport = readingViewport(for: textView, window: window)
      return !glyphs.isEmpty && glyphs.allSatisfy { viewport.contains($0) }
    }

  }
}
#endif
