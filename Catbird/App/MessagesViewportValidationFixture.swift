#if DEBUG && os(iOS)
import Foundation
import Observation
import Petrel
import QuartzCore
import SwiftData
import SwiftUI
import UIKit

/// Explicit, offline presentation route. Use only a disposable simulator app and
/// app-group container: AppState's ordinary initial theme/font reads still run.
@MainActor
struct MessagesViewportValidationFixture: View {
  static let launchArgument = "--messages-viewport-validation-fixture"
  static let composerID = "viewporttest"
  private static let accountDID = "did:plc:messagesviewportfixture"

  @State private var source: MessagesViewportFixtureSource
  @State private var account: AppState?
  @State private var sceneContext: SceneNavigationContext?
  @State private var container: ModelContainer?
  @State private var failure: String?
  @State private var path = NavigationPath()
  @State private var attachedPost: ChatSharedPostPreview?
  @State private var coralBackdrop = false
  @State private var measurements = MessagesViewportFixtureMeasurements()

  init() {
    let short = ProcessInfo.processInfo.arguments.contains("--messages-viewport-short")
    _source = State(initialValue: MessagesViewportFixtureSource(count: short ? 2 : 32))
  }

  var body: some View {
    NavigationStack {
      if let account, let sceneContext {
        ChatCollectionViewBridge(dataSource: source, navigationPath: $path)
          .background {
            (coralBackdrop ? Color.pink : Color.cyan).opacity(0.35)
          }
          .chatTranscriptViewport {
            ChatMessageComposerView(
              text: $source.draftText,
              attachedPost: $attachedPost,
              conversationId: Self.composerID,
              onSend: { _, _ in source.sendCallbackCount += 1 },
              clearsDraftOnSend: false,
              placeholderText: "Local fixture text"
            )
            .background { MessagesViewportFooterMarker(measurements: measurements) }
          }
          .overlay(alignment: .topLeading) {
            MessagesViewportNativeProbe(source: source, measurements: measurements)
              .frame(width: 2, height: 2)
          }
          .environment(account)
          .environment(sceneContext)
          .environment(\.fontManager, account.fontManager)
          .environment(\.openURL, OpenURLAction { _ in .discarded })
          .navigationTitle(source.messages.count == 2 ? "Short local chat" : "Long local chat")
          .toolbarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
              Button("Backdrop", systemImage: "paintpalette") {
                coralBackdrop.toggle()
                measurements.backdrop = coralBackdrop ? "coral" : "cyan"
              }
              .accessibilityIdentifier("messages.fixture.backdrop")
              Button("Grow local row", systemImage: "rectangle.expand.vertical") {
                source.growRow(id: measurements.latest?.anchorID)
              }
              .accessibilityIdentifier("messages.fixture.grow")
              Button("Reset drag witnesses", systemImage: "arrow.counterclockwise") {
                measurements.resetSequence += 1
              }
              .accessibilityIdentifier("messages.fixture.resetDrags")
              Button("Keyboard", systemImage: "keyboard.chevron.compact.down") {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                  to: nil, from: nil, for: nil)
              }
              .accessibilityIdentifier("messages.fixture.dismissKeyboard")
            }
          }
      } else if let failure {
        Text("Messages fixture failed: \(failure)")
          .accessibilityIdentifier("messages.fixture.failure")
      } else {
        ProgressView("Preparing local messages")
      }
    }
    .preferredColorScheme(.light)
    .dynamicTypeSize(.large)
    .task { await prepare() }
    .onDisappear { sceneContext?.invalidate() }
  }

  private func prepare() async {
    guard account == nil else { return }
    do {
      let storage = try ModelContainer(for: DraftPost.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
      guard let defaults = UserDefaults(suiteName: "messages.viewport.fixture.\(UUID().uuidString)") else {
        throw CocoaError(.fileReadUnknown)
      }
      let client = await ATProtoClient(baseURL: URL(string: "http://127.0.0.1:1")!)
      guard !Task.isCancelled else { return }
      let state = AppState(userDID: Self.accountDID, client: client, regulatoryChecker: NoAgePrompt())
      // Cancel the default draft observer before it can use account services.
      // Do not initialize AppSettings, preferences, authentication or chat services.
      state.composerDraftManager.configureForTesting(modelContext: storage.mainContext)
      let manager = ComposerDraftManager(accountDID: Self.accountDID,
        modelContext: storage.mainContext, defaults: defaults)
      let sceneID = UUID()
      let session = SceneComposerEditingSession(manager: manager, accountDID: Self.accountDID,
        sceneID: sceneID, defaults: defaults)
      let context = SceneNavigationContext(appState: state, sceneID: sceneID,
        composerEditingSession: session)
      container = storage
      sceneContext = context
      account = state
    } catch {
      failure = error.localizedDescription
    }
  }

  private struct NoAgePrompt: AgeRegulatoryChecking {
    func preflight() async -> PlatformAgeSignal {
      PlatformAgeSignal(requirement: .none, ageBand: nil, significantChangeConsentRequired: false)
    }
    @MainActor
    func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
  }
}

private struct MessagesViewportFixtureMessage: UnifiedChatMessage {
  let id: String
  var text: String
  let senderID: String
  let senderDisplayName: String?
  var senderAvatarURL: URL? { nil }
  // One timestamp intentionally yields one date separator in the real snapshot.
  let sentAt = Date(timeIntervalSince1970: 1_780_000_000)
  let isFromCurrentUser: Bool
  var reactions: [UnifiedReaction] { [] }
  var embed: UnifiedEmbed?
  var sendState: MessageSendState { .sent }
}

@MainActor @Observable
private final class MessagesViewportFixtureSource: UnifiedChatDataSource {
  var messages: [MessagesViewportFixtureMessage]
  var draftText = ""
  var isLoading: Bool { false }
  var error: Error? { nil }
  var hasMoreMessages: Bool { false }
  var localRevision = 0
  var sendCallbackCount = 0

  init(count: Int) {
    messages = (0..<count).map { index in
      MessagesViewportFixtureMessage(
        id: "local-\(index)",
        text: "Local row \(index + 1)\nColored messages continue behind the composer glass.",
        senderID: index.isMultiple(of: 2) ? "did:plc:localfixturepeer" : "did:plc:messagesviewportfixture",
        senderDisplayName: index.isMultiple(of: 2) ? "Local peer" : "Local viewer",
        isFromCurrentUser: !index.isMultiple(of: 2),
        embed: index == count - 1 ? Self.link(title: "Already supplied local link metadata") : nil
      )
    }
  }

  func message(for id: String) -> MessagesViewportFixtureMessage? {
    messages.first { $0.diffableID == id }
  }
  func loadMessages() async {}
  func loadMoreMessages() async {}
  func sendMessage(text: String) async { sendCallbackCount += 1 }
  func toggleReaction(messageID: String, emoji: String) {}
  func addReaction(messageID: String, emoji: String) {}
  func deleteMessage(messageID: String) async {}

  func growRow(id: String?) {
    guard localRevision == 0, let index = messages.firstIndex(where: { $0.id == id }) else { return }
    messages[index].text += "\n" + Array(repeating: "Additional local text wraps this existing row.", count: 8)
      .joined(separator: "\n")
    messages[index].embed = Self.link(title: "Late local metadata with a longer supplied title that wraps")
    localRevision += 1
  }

  private static func link(title: String) -> UnifiedEmbed {
    .link(LinkEmbedData(url: URL(string: "https://viewport-fixture.invalid/local")!,
      title: title, description: "Known local metadata. No thumbnail, resolver or transport is used.",
      thumbnailURL: nil))
  }
}

@MainActor
private final class MessagesViewportFixtureMeasurements {
  var footerFrame = CGRect.zero
  var backdrop = "cyan"
  var resetSequence = 0
  var latest: MessagesViewportFixtureSample?
}

private struct MessagesViewportFixtureRect: Codable {
  let x: Double
  let y: Double
  let width: Double
  let height: Double
  init(_ rect: CGRect) {
    x = Double(rect.minX); y = Double(rect.minY)
    width = Double(rect.width); height = Double(rect.height)
  }
}

private struct MessagesViewportDragWitness: Codable {
  let offsetY: Double
  let legalTop: Double
  let legalBottom: Double
  let isDragging: Bool
  let timestamp: Double
}

private struct MessagesViewportFixtureSample: Codable {
  let ready: Bool
  let sampleCount: Int
  let resetSequence: Int
  let messageCount: Int
  let localRevision: Int
  let sendCallbackCount: Int
  let backdrop: String
  let scale: Double
  let collectionFrame: MessagesViewportFixtureRect
  let footerFrame: MessagesViewportFixtureRect
  let editorFrame: MessagesViewportFixtureRect
  let editorIsFirstResponder: Bool
  let editorTextCount: Int
  let contentHeight: Double
  let offsetY: Double
  let legalTop: Double
  let legalBottom: Double
  let insetBottom: Double
  let adjustedInsetBottom: Double
  let bounces: Bool
  let alwaysBounceVertical: Bool
  let adjustsInsetAutomatically: Bool
  let isDragging: Bool
  let isTracking: Bool
  let isDecelerating: Bool
  let settledFor: Double
  let anchorID: String?
  let anchorY: Double?
  let anchorHeight: Double?
  let rowsUnderFooter: Int
  let topWitness: MessagesViewportDragWitness?
  let bottomWitness: MessagesViewportDragWitness?
  let topHeldSeconds: Double
  let bottomHeldSeconds: Double
  let sendShieldInstalled: Bool
}

private struct MessagesViewportFooterMarker: UIViewRepresentable {
  let measurements: MessagesViewportFixtureMeasurements
  func makeUIView(context: Context) -> MarkerView {
    let view = MarkerView()
    view.measurements = measurements
    view.isUserInteractionEnabled = false
    return view
  }
  func updateUIView(_ view: MarkerView, context: Context) { view.publish() }
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: MarkerView, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
  }
  final class MarkerView: UIView {
    var measurements: MessagesViewportFixtureMeasurements?
    override func layoutSubviews() { super.layoutSubviews(); publish() }
    override func didMoveToWindow() { super.didMoveToWindow(); publish() }
    func publish() {
      guard let window else { return }
      measurements?.footerFrame = convert(bounds, to: window)
    }
  }
}

/// Observes actual UIKit geometry. It never writes contentOffset, scrolls to an
/// item, synthesizes a keyboard inset, or replaces the production scroll delegate.
private struct MessagesViewportNativeProbe: UIViewRepresentable {
  let source: MessagesViewportFixtureSource
  let measurements: MessagesViewportFixtureMeasurements
  func makeUIView(context: Context) -> ProbeView {
    let view = ProbeView(source: source, measurements: measurements)
    return view
  }
  func updateUIView(_ view: ProbeView, context: Context) {}
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: ProbeView, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? 2, height: proposal.height ?? 2)
  }
  static func dismantleUIView(_ view: ProbeView, coordinator: ()) { view.stop() }

  @MainActor
  final class ProbeView: UIView {
    private let source: MessagesViewportFixtureSource
    private let measurements: MessagesViewportFixtureMeasurements
    private var displayLink: CADisplayLink?
    private let sendShield = UIView()
    private weak var sendNode: NSObject?
    private var sampleCount = 0
    private var resetSequence = 0
    private var lastOffset: CGFloat?
    private var quietSince: TimeInterval?
    private var topSince: TimeInterval?
    private var bottomSince: TimeInterval?
    private var topHeldSeconds = 0.0
    private var bottomHeldSeconds = 0.0
    private var topWitness: MessagesViewportDragWitness?
    private var bottomWitness: MessagesViewportDragWitness?

    init(source: MessagesViewportFixtureSource, measurements: MessagesViewportFixtureMeasurements) {
      self.source = source
      self.measurements = measurements
      super.init(frame: .zero)
      isUserInteractionEnabled = false
      isAccessibilityElement = true
      accessibilityIdentifier = "messages.fixture.geometry"
      accessibilityLabel = "Actual transcript geometry and held drag witnesses"
      accessibilityTraits = .staticText
      sendShield.backgroundColor = .clear
      sendShield.isAccessibilityElement = true
      sendShield.accessibilityIdentifier = "messages.fixture.sendDisabled"
      sendShield.accessibilityLabel = "Sending disabled in local fixture"
      sendShield.accessibilityTraits = [.button, .notEnabled]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      stop()
      guard window != nil else { return }
      let link = CADisplayLink(target: self, selector: #selector(sample(_:)))
      link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
      link.add(to: .main, forMode: .common)
      displayLink = link
    }
    func stop() {
      displayLink?.invalidate()
      displayLink = nil
      sendShield.removeFromSuperview()
    }

    @objc private func sample(_ link: CADisplayLink) {
      guard let window else { return }
      let views = descendants(of: window)
      guard let collection = views.compactMap({ $0 as? ChatTranscriptCollectionView }).first
      else { return }
      collection.accessibilityIdentifier = "messages.fixture.transcript"
      // This route has one UITextView: the production composer TextEditor.
      // SwiftUI may place its AX identifier on a virtual element rather than
      // on that native view, so native identity does not depend on the AX tag.
      let editor = views.compactMap { $0 as? UITextView }.first { $0.isEditable }
      if let footer = views.compactMap({ $0 as? MessagesViewportFooterMarker.MarkerView }).first {
        measurements.footerFrame = footer.convert(footer.bounds, to: window)
      }
      installSendShield(in: window)
      if resetSequence != measurements.resetSequence {
        resetSequence = measurements.resetSequence
        topWitness = nil; bottomWitness = nil
        topSince = nil; bottomSince = nil
        topHeldSeconds = 0; bottomHeldSeconds = 0
      }
      let scale = window.screen.scale
      let epsilon = 2 / scale
      let top = -collection.adjustedContentInset.top
      let bottom = max(top, collection.contentSize.height - collection.bounds.height
        + collection.adjustedContentInset.bottom)
      let y = collection.contentOffset.y
      let time = link.timestamp
      let witness = MessagesViewportDragWitness(offsetY: Double(y), legalTop: Double(top),
        legalBottom: Double(bottom), isDragging: collection.isDragging, timestamp: time)
      if collection.isDragging && y < top - epsilon {
        topSince = topSince ?? time
        topHeldSeconds = max(topHeldSeconds, time - (topSince ?? time))
        if y < CGFloat(topWitness?.offsetY ?? .infinity) { topWitness = witness }
      } else { topSince = nil }
      if collection.isDragging && y > bottom + epsilon {
        bottomSince = bottomSince ?? time
        bottomHeldSeconds = max(bottomHeldSeconds, time - (bottomSince ?? time))
        if y > CGFloat(bottomWitness?.offsetY ?? -.infinity) { bottomWitness = witness }
      } else { bottomSince = nil }
      let quiet = !collection.isDragging && !collection.isTracking && !collection.isDecelerating
        && lastOffset.map { abs($0 - y) <= epsilon } == true
        && y >= top - epsilon && y <= bottom + epsilon
      quietSince = quiet ? (quietSince ?? time) : nil
      lastOffset = y
      sampleCount += 1

      // The fixture's one day separator occupies item zero. Real bubbles remain
      // in UIHostingConfiguration; only their native cell backdrop is tinted.
      var rowsUnderFooter = 0
      for cell in collection.visibleCells {
        guard let index = collection.indexPath(for: cell)?.item, index > 0 else { continue }
        if cell.convert(cell.bounds, to: window).intersects(measurements.footerFrame) { rowsUnderFooter += 1 }
        let tint = (index.isMultiple(of: 2) ? UIColor.systemPink : UIColor.systemTeal)
          .withAlphaComponent(0.24)
        if cell.backgroundColor != tint { cell.backgroundColor = tint }
      }
      let visible = collection.indexPathsForVisibleItems.sorted().compactMap { index -> (Int, CGRect)? in
        guard index.item > 0, source.messages.indices.contains(index.item - 1),
              let frame = collection.layoutAttributesForItem(at: index)?.frame,
              frame.maxY > y + collection.adjustedContentInset.top else { return nil }
        return (index.item - 1, frame)
      }.first
      let snapshot = MessagesViewportFixtureSample(
        ready: collection.alpha > 0 && collection.contentSize.height > 0 && editor != nil
          && measurements.footerFrame.height > 0,
        sampleCount: sampleCount, resetSequence: resetSequence, messageCount: source.messages.count,
        localRevision: source.localRevision, sendCallbackCount: source.sendCallbackCount,
        backdrop: measurements.backdrop, scale: Double(scale),
        collectionFrame: .init(collection.convert(collection.bounds, to: window)),
        footerFrame: .init(measurements.footerFrame),
        editorFrame: .init(editor.map { $0.convert($0.bounds, to: window) } ?? .zero),
        editorIsFirstResponder: editor?.isFirstResponder == true,
        editorTextCount: editor?.text.count ?? 0,
        contentHeight: Double(collection.contentSize.height), offsetY: Double(y),
        legalTop: Double(top), legalBottom: Double(bottom),
        insetBottom: Double(collection.contentInset.bottom),
        adjustedInsetBottom: Double(collection.adjustedContentInset.bottom),
        bounces: collection.bounces, alwaysBounceVertical: collection.alwaysBounceVertical,
        adjustsInsetAutomatically: collection.contentInsetAdjustmentBehavior != .never,
        isDragging: collection.isDragging, isTracking: collection.isTracking,
        isDecelerating: collection.isDecelerating, settledFor: quietSince.map { time - $0 } ?? 0,
        anchorID: visible.map { source.messages[$0.0].id },
        anchorY: visible.map { Double($0.1.minY - y) },
        anchorHeight: visible.map { Double($0.1.height) },
        rowsUnderFooter: rowsUnderFooter,
        topWitness: topWitness, bottomWitness: bottomWitness,
        topHeldSeconds: topHeldSeconds, bottomHeldSeconds: bottomHeldSeconds,
        sendShieldInstalled: sendShield.superview === window && !sendShield.frame.isEmpty
          && measurements.footerFrame.contains(sendShield.frame)
      )
      measurements.latest = snapshot
      if let data = try? JSONEncoder().encode(snapshot) {
        accessibilityValue = String(decoding: data, as: UTF8.self)
      }
    }

    private func descendants(of view: UIView) -> [UIView] {
      [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func installSendShield(in window: UIWindow) {
      // Public accessibility container APIs locate the real SwiftUI button.
      // The clear touch shield and AX hiding leave panel size/material intact.
      var visited = Set<ObjectIdentifier>()
      func find(_ node: NSObject, depth: Int) -> NSObject? {
        guard depth < 16, visited.insert(ObjectIdentifier(node)).inserted else { return nil }
        if (node as? UIAccessibilityIdentification)?.accessibilityIdentifier
          == "chat.composer.sendButton.viewporttest" { return node }
        let count = node.accessibilityElementCount()
        let elements = node.accessibilityElements ?? ((count > 0 && count < 128)
          ? (0..<count).compactMap { node.accessibilityElement(at: $0) } : [])
        for child in elements {
          if let child = child as? NSObject, let found = find(child, depth: depth + 1) { return found }
        }
        if let view = node as? UIView {
          for child in view.subviews {
            if let found = find(child, depth: depth + 1) { return found }
          }
        }
        return nil
      }
      guard let node = find(window, depth: 0) ?? sendNode, !node.accessibilityFrame.isEmpty else { return }
      sendNode = node
      if !node.accessibilityElementsHidden { node.accessibilityElementsHidden = true }
      if !node.accessibilityTraits.contains(.notEnabled) { node.accessibilityTraits.insert(.notEnabled) }
      let frame = window.convert(node.accessibilityFrame, from: nil)
      if sendShield.frame != frame { sendShield.frame = frame }
      if sendShield.superview !== window { window.addSubview(sendShield) }
      if window.subviews.last !== sendShield { window.bringSubviewToFront(sendShield) }
    }
  }
}
#endif
