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
  private static var isComposerAlignmentFixture: Bool {
    ProcessInfo.processInfo.arguments.contains("--messages-composer-alignment")
  }
  private static var composerScenario: String {
    let prefix = "--messages-composer-scenario="
    return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }
      .map { String($0.dropFirst(prefix.count)) } ?? "empty"
  }

  private static var presentationScenario: String? {
    let prefix = "--chat-message-presentation="
    return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }
      .map { String($0.dropFirst(prefix.count)) }
  }
  private static var isPresentationFixture: Bool { presentationScenario != nil }

  @State private var presentationNarrow = false
  @State private var presentationLargeText = false
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
    let fixtureSource = MessagesViewportFixtureSource(count: short ? 2 : 32)
    if let scenario = Self.presentationScenario {
      fixtureSource.configurePresentation(scenario: scenario)
      _presentationLargeText = State(initialValue:
        ProcessInfo.processInfo.arguments.contains("--chat-message-presentation-large-text"))
    }
    if Self.isComposerAlignmentFixture {
      switch Self.composerScenario {
      case "hi", "accessibility3": fixtureSource.draftText = "hi"
      case "multiline": fixtureSource.draftText = "one\nsecond\nthird"
      case "counter950": fixtureSource.draftText = String(repeating: "x", count: 950)
      case "attached":
        fixtureSource.draftText = "hi"
        _attachedPost = State(initialValue: ChatSharedPostPreview(
          authorDisplayName: "Local peer", authorHandle: "local.invalid",
          text: "A supplied local post preview. No resolver or message transport is used."))
      default: break
      }
    }
    _source = State(initialValue: fixtureSource)
  }

  var body: some View {
    NavigationStack {
      if let account, let sceneContext {
        ChatCollectionViewBridge(dataSource: source, navigationPath: $path,
          onRequestEmojiPicker: Self.isPresentationFixture ? { source.recordAction("more", id: $0) } : nil,
          onEditMessage: Self.isPresentationFixture ? { source.recordAction("edit", id: $0.id) } : nil,
          onUnsendMessage: Self.isPresentationFixture ? { source.recordAction("unsend", id: $0.id) } : nil,
          onReply: Self.isPresentationFixture ? { source.recordAction("reply", id: $0.id) } : nil,
          onDeleteMessage: Self.isPresentationFixture ? { source.recordAction("delete", id: $0.id) } : nil,
          onReportMessage: Self.isPresentationFixture ? { source.recordAction("report", id: $0.id) } : nil)
          .environment(\.chatPresentationFixtureRecords, source.presentationRecords)
          .modifier(ChatPresentationWidthModifier(enabled: Self.isPresentationFixture, narrow: presentationNarrow))
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
              placeholderText: "Local fixture text",
              fixtureSendingDisabled: !Self.isComposerAlignmentFixture
            )
            .background { MessagesViewportFooterMarker(measurements: measurements) }
          }
          .overlay(alignment: .topLeading) {
            HStack(spacing: 0) {
              MessagesViewportNativeProbe(source: source, measurements: measurements)
                .frame(width: 2, height: 2)
              MessagesViewportGestureReadout(measurements: measurements)
                .frame(width: 2, height: 2)
              if Self.isPresentationFixture {
                ChatPresentationNativeProbe(source: source, navigationDepth: path.count)
                  .frame(width: 2, height: 2)
              }
            }
          }
          .environment(account)
          .environment(sceneContext)
          .environment(\.fontManager, account.fontManager)
          .environment(\.openURL, OpenURLAction { _ in .discarded })
          .navigationTitle(source.messages.count == 2 ? "Short local chat" : "Long local chat")
          .toolbarTitleDisplayMode(.inline)
          .toolbar {
            if Self.isPresentationFixture {
              ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Narrow", systemImage: "arrow.left.and.right") { presentationNarrow.toggle() }
                  .accessibilityIdentifier("chat.fixture.narrow")
                Button("Larger Text", systemImage: "textformat.size") { presentationLargeText.toggle() }
                  .accessibilityIdentifier("chat.fixture.typeSize")
                if source.presentationScenario?.hasPrefix("menu-") == true {
                  Menu("Fixture actions", systemImage: "ellipsis.circle") {
                    Button("Accessible actions") { source.presentationAccessibleRequest += 1 }
                      .accessibilityIdentifier("chat.fixture.accessibleActions")
                  }
                  .accessibilityIdentifier("chat.fixture.controls")
                } else {
                  Button("Change record", systemImage: "rectangle.expand.vertical") {
                    source.changePresentationRecord()
                  }
                  .accessibilityIdentifier("chat.fixture.changeRecord")
                }
                Button("Keyboard", systemImage: "keyboard.chevron.compact.down") {
                  UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                    to: nil, from: nil, for: nil)
                }
                .accessibilityIdentifier("messages.fixture.dismissKeyboard")
              }
            } else {
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
              Menu("Record native gestures", systemImage: "waveform.path") {
                Button("Record center drag") { measurements.requestGestureTrace(kind: "center") }
                  .accessibilityIdentifier("messages.fixture.armCenter")
                Button("Record gutter drag") { measurements.requestGestureTrace(kind: "gutter") }
                  .accessibilityIdentifier("messages.fixture.armGutter")
              }
              .accessibilityIdentifier("messages.fixture.gesturesMenu")
            }
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
    .dynamicTypeSize((Self.isComposerAlignmentFixture && Self.composerScenario == "accessibility3")
      || (Self.isPresentationFixture && presentationLargeText) ? .accessibility3 : .large)
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
      if Self.isPresentationFixture {
        try source.preparePresentationRecords()
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
  var reactions: [UnifiedReaction] = []
  var embed: UnifiedEmbed?
  var canEdit = false
  var canUnsend = false
  var isTombstone = false
  var isSystemMessage = false
  var replyContext: UnifiedMessageReplyContext?
  var sendState: MessageSendState { .sent }
}

@MainActor @Observable
private final class MessagesViewportFixtureSource: UnifiedChatDataSource {
  let instanceID = UUID().uuidString
  var messages: [MessagesViewportFixtureMessage]
  var draftText = ""
  var isLoading: Bool { false }
  var error: Error? { nil }
  var hasMoreMessages: Bool { false }
  var localRevision = 0
  var sendCallbackCount = 0
  var presentationScenario: String?
  var presentationRecords: [String: AppBskyEmbedRecord.ViewRecordUnion] = [:]
  var presentationActions: [String] = []
  var presentationRecordRevision = 0
  var presentationAppliedRecordRevision = 0
  var presentationAccessibleRequest = 0
  private var shortPresentationRecord: AppBskyEmbedRecord.ViewRecordUnion?
  private var longPresentationRecord: AppBskyEmbedRecord.ViewRecordUnion?

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
  func toggleReaction(messageID: String, emoji: String) {
    guard presentationScenario != nil else { return }
    recordAction("toggle:" + emoji, id: messageID)
    guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
    if messages[index].reactions.contains(where: { $0.emoji == emoji && $0.isFromCurrentUser }) {
      messages[index].reactions.removeAll { $0.emoji == emoji && $0.isFromCurrentUser }
    } else {
      messages[index].reactions.append(.init(messageID: messageID, emoji: emoji,
        senderDID: "did:plc:messagesviewportfixture", isFromCurrentUser: true, reactedAt: nil))
    }
  }
  func addReaction(messageID: String, emoji: String) {
    guard presentationScenario != nil else { return }
    recordAction("add:" + emoji, id: messageID)
    guard let index = messages.firstIndex(where: { $0.id == messageID }),
      !messages[index].reactions.contains(where: { $0.emoji == emoji && $0.isFromCurrentUser }) else { return }
    messages[index].reactions.append(.init(messageID: messageID, emoji: emoji,
      senderDID: "did:plc:messagesviewportfixture", isFromCurrentUser: true, reactedAt: nil))
  }
  func deleteMessage(messageID: String) async {}

  func growRow(id: String?) {
    guard localRevision == 0, let index = messages.firstIndex(where: { $0.id == id }) else { return }
    messages[index].text += "\n" + Array(repeating: "Additional local text wraps this existing row.", count: 8)
      .joined(separator: "\n")
    messages[index].embed = Self.link(title: "Late local metadata with a longer supplied title that wraps")
    localRevision += 1
  }

  static let presentationID = "presentation-target"
  static let presentationURI = "at://did:plc:chatfixtureauthor/app.bsky.feed.post/external"
  static let presentationCID = "bafyreicj3hqoqmwwqfnf7juwf6pm5avc6imdw3lxw7lbcz63gumteobfnq"
  static let externalTitle = "Local external card: a deliberately long headline that wraps at the message width cap"
  static let externalDescription = "Local description with enough words to wrap across several lines and expose a clipped final line. End of local description."
  static let recordText = "Local shared post body with enough text to exercise the production quoted-post layout and its external preview. Final body marker."

  func configurePresentation(scenario: String) {
    presentationScenario = scenario
    let menu = scenario.hasPrefix("menu-")
    if menu { messages = Array(messages.prefix(1)); draftText = "local draft" }
    var message = MessagesViewportFixtureMessage(id: Self.presentationID,
      text: menu ? "Local menu message" : "",
      senderID: scenario == "menu-own" ? "did:plc:messagesviewportfixture" : "did:plc:localfixturepeer",
      senderDisplayName: scenario == "menu-own" ? "Local viewer" : "Local peer",
      isFromCurrentUser: scenario == "menu-own",
      embed: menu ? nil : .blueskyRecord(recordData: .init(uri: Self.presentationURI, cid: Self.presentationCID)))
    if scenario == "text-reply" {
      message.text = "Local message above the shared external card."
      message.replyContext = .init(kind: .message(id: "local-0", senderDID: "did:plc:localfixturepeer",
        senderDisplayName: "Local peer", text: "Local reply preview"), referencedMessageID: "local-0",
        senderDisplayName: "Local peer", previewText: "Local reply preview", isTappable: false)
    }
    if scenario == "menu-own" { message.canEdit = true; message.canUnsend = true }
    if scenario == "menu-tombstone" { message.isTombstone = true }
    if scenario == "menu-system" { message.isSystemMessage = true }
    if scenario == "menu-incoming" {
      message.reactions = [.init(messageID: Self.presentationID, emoji: "❤️",
        senderDID: "did:plc:localfixturepeer", isFromCurrentUser: false, reactedAt: nil)]
    }
    messages.append(message)
  }

  func recordAction(_ action: String, id: String) {
    presentationActions.append(action + "|" + id)
  }

  func preparePresentationRecords() throws {
    guard let scenario = presentationScenario, !scenario.hasPrefix("menu-") else { return }
    // Supplied decoded records exercise real quote/external views without an
    // authenticated lifecycle or record network request. This is not a network
    // placeholder/loading test. The thumbnail is a local file with known pixel
    // dimensions, loaded by the production image pipeline without transport.
    let thumbnail = try Self.makePresentationThumbnail()
    func record(long: Bool) throws -> AppBskyEmbedRecord.ViewRecordUnion {
      var metadata: [String: Any] = ["uri": "https://fixture.invalid/local-card",
        "title": long ? Self.externalTitle : "Local short card",
        "description": long ? Self.externalDescription : "Short local description."]
      if long { metadata["thumb"] = thumbnail.absoluteString }
      let external: [String: Any] = ["$type": "app.bsky.embed.external#view", "external": metadata]
      let object: [String: Any] = ["$type": "app.bsky.embed.record#viewRecord",
        "uri": Self.presentationURI, "cid": Self.presentationCID,
        "author": ["did": "did:plc:chatfixtureauthor", "handle": "local-card.invalid", "displayName": "Local card author"],
        "value": ["$type": "app.bsky.feed.post", "text": long ? Self.recordText : "Short local post.",
          "createdAt": "2026-01-01T12:00:00Z"],
        "indexedAt": "2026-01-01T12:00:00Z", "embeds": [external]]
      return try JSONDecoder().decode(AppBskyEmbedRecord.ViewRecordUnion.self,
        from: JSONSerialization.data(withJSONObject: object))
    }
    shortPresentationRecord = try record(long: false)
    longPresentationRecord = try record(long: true)
    if let initial = scenario == "async" ? shortPresentationRecord : longPresentationRecord {
      presentationRecords = [Self.presentationURI: initial]
    }
  }

  func changePresentationRecord() {
    guard presentationScenario != nil else { return }
    presentationRecordRevision += 1
    let revision = presentationRecordRevision
    // Delay only local fixture data publication, leaving the production hosting
    // cell to react to the new record and recompute its actual intrinsic height.
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(180))
      guard let self, !Task.isCancelled, self.presentationRecordRevision == revision,
        let record = revision.isMultiple(of: 2) ? self.shortPresentationRecord : self.longPresentationRecord else { return }
      self.presentationRecords = [Self.presentationURI: record]
      self.presentationAppliedRecordRevision = revision
    }
  }

  private static func makePresentationThumbnail() throws -> URL {
    // A real decoded PNG, not a replacement SwiftUI rectangle. The source image
    // is 382x200 pixels, matching the production external-card 1.91 aspect ratio.
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 382, height: 200), format: format)
    let png = renderer.pngData { context in
      UIColor.systemIndigo.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 382, height: 200))
      UIColor.systemTeal.setFill()
      context.fill(CGRect(x: 12, y: 12, width: 358, height: 176))
      UIColor.white.setStroke()
      context.cgContext.setLineWidth(3)
      context.cgContext.move(to: CGPoint(x: 12, y: 12))
      context.cgContext.addLine(to: CGPoint(x: 370, y: 188))
      context.cgContext.move(to: CGPoint(x: 370, y: 12))
      context.cgContext.addLine(to: CGPoint(x: 12, y: 188))
      context.cgContext.strokePath()
      ("LOCAL 382 × 200" as NSString).draw(at: CGPoint(x: 105, y: 88), withAttributes: [
        .font: UIFont.systemFont(ofSize: 21, weight: UIFont.Weight.bold), .foregroundColor: UIColor.black])
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-presentation-thumb.png")
    try png.write(to: url, options: .atomic)
    return url
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
  var gestureSequence = 0
  var gestureKind = ""
  weak var gestureReadout: UILabel?

  func requestGestureTrace(kind: String) {
    gestureKind = kind
    gestureSequence += 1
  }
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

private struct MessagesViewportFixtureInsets: Codable {
  let top: Double, left: Double, bottom: Double, right: Double
  init(_ insets: UIEdgeInsets) {
    top = Double(insets.top); left = Double(insets.left)
    bottom = Double(insets.bottom); right = Double(insets.right)
  }
}

private struct MessagesViewportFixtureSize: Codable {
  let width: Double, height: Double
  init(_ size: CGSize) { width = Double(size.width); height = Double(size.height) }
}

private struct MessagesViewportDragWitness: Codable {
  let offsetY: Double
  let legalTop: Double
  let legalBottom: Double
  let isDragging: Bool
  let timestamp: Double
}

private struct MessagesViewportGesturePoint: Codable {
  let x: Double, y: Double
  init(_ point: CGPoint) { x = Double(point.x); y = Double(point.y) }
}

private struct MessagesViewportGestureView: Codable {
  let identity: String
  let className: String
  let frame: MessagesViewportFixtureRect
}

private struct MessagesViewportGestureRecognizer: Codable {
  let identity: String
  let className: String
  let owner: MessagesViewportGestureView?
  let isCollectionPan: Bool
}

private struct MessagesViewportGestureState: Codable {
  let identity: String
  let state: String
  let numberOfTouches: Int
  let location: MessagesViewportGesturePoint?
  let translation: MessagesViewportGesturePoint?
  let velocity: MessagesViewportGesturePoint?
}

private struct MessagesViewportGestureFrame: Codable {
  let timestamp: Double
  let offsetY: Double, legalTop: Double, legalBottom: Double
  let isTracking: Bool, isDragging: Bool, isDecelerating: Bool
  let recognizers: [MessagesViewportGestureState]
}

/// Process-local identities and public UIKit state are observations, not a
/// declaration that any particular private SwiftUI recognizer won arbitration.
private struct MessagesViewportGestureTrace: Codable {
  let sequence: Int
  let kind: String
  let timelineLimit = 64
  let viewLimit = 12
  let recognizerLimit = 16
  let byteLimit = 65_536
  var status = "waitingForTarget"
  var collectionIdentity: String?
  var fixtureInstanceID: String?
  var editorIdentity: String?
  var finalCollectionIdentity: String?
  var finalEditorIdentity: String?
  var collectionFrame: MessagesViewportFixtureRect?
  var footerFrame: MessagesViewportFixtureRect?
  var baselineSample: MessagesViewportFixtureSample?
  var finalSample: MessagesViewportFixtureSample?
  var start: MessagesViewportGesturePoint?
  var end: MessagesViewportGesturePoint?
  var armedAt: Double?
  var completedAt: Double?
  var viewPath: [MessagesViewportGestureView] = []
  var recognizers: [MessagesViewportGestureRecognizer] = []
  var timeline: [MessagesViewportGestureFrame] = []
  var firstInputFrame: MessagesViewportGestureFrame?
  var firstReleasedFrame: MessagesViewportGestureFrame?
  var observedFrameCount = 0
  var recordedFrameCount = 0
  var droppedRecordCount = 0
  var viewPathTruncated = false
  var recognizersTruncated = false
  var inputObserved = false
  var minimumOffsetY: Double?
  var maximumOffsetY: Double?
}

private struct MessagesViewportFixtureSample: Codable {
  let ready: Bool
  let fixtureInstanceID: String
  let sampleCount: Int
  let resetSequence: Int
  let messageCount: Int
  let localRevision: Int
  let sendCallbackCount: Int
  let backdrop: String
  let scale: Double
  let collectionIdentity: String
  let editorIdentity: String?
  let collectionFrame: MessagesViewportFixtureRect
  let footerFrame: MessagesViewportFixtureRect
  let editorFrame: MessagesViewportFixtureRect
  let caretFrame: MessagesViewportFixtureRect?
  let editorFontLineHeight: Double?
  let editorTextContainerInset: MessagesViewportFixtureInsets?
  let editorContentInset: MessagesViewportFixtureInsets?
  let editorContentSize: MessagesViewportFixtureSize?
  let editorContentOffset: MessagesViewportGesturePoint?
  let editorTextBounds: MessagesViewportFixtureRect?
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
}

/// A separate, noninteractive accessibility value keeps the bounded recognizer
/// timeline out of the ordinary geometry sample used by existing assertions.
private struct MessagesViewportGestureReadout: UIViewRepresentable {
  let measurements: MessagesViewportFixtureMeasurements
  func makeUIView(context: Context) -> UILabel {
    let view = UILabel()
    view.isUserInteractionEnabled = false
    view.isAccessibilityElement = true
    view.accessibilityIdentifier = "messages.fixture.gestures"
    view.accessibilityLabel = "Passive native gesture timeline"
    view.accessibilityTraits = .staticText
    view.accessibilityValue = "{\"sequence\":0,\"status\":\"idle\"}"
    measurements.gestureReadout = view
    return view
  }
  func updateUIView(_ view: UILabel, context: Context) { measurements.gestureReadout = view }
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
    private var gestureSequence = 0
    private var gestureRequestedAt: TimeInterval?
    private var gestureQuietSince: TimeInterval?
    private var tracedRecognizers: [UIGestureRecognizer] = []
    private var gestureTrace: MessagesViewportGestureTrace?

    init(source: MessagesViewportFixtureSource, measurements: MessagesViewportFixtureMeasurements) {
      self.source = source
      self.measurements = measurements
      super.init(frame: .zero)
      isUserInteractionEnabled = false
      isAccessibilityElement = true
      accessibilityIdentifier = "messages.fixture.geometry"
      accessibilityLabel = "Actual transcript geometry and held drag witnesses"
      accessibilityTraits = .staticText

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
      tracedRecognizers = []
    }

    /// Observe laid-out text through UITextInput, without changing selection or
    /// requesting layoutManager (which can switch a TextKit 2 view to TextKit 1).
    /// Rectangles are intentionally not clipped to the editor's visible bounds.
    private func textBounds(of editor: UITextView, in window: UIWindow) -> MessagesViewportFixtureRect? {
      guard editor.hasText,
        let range = editor.textRange(from: editor.beginningOfDocument, to: editor.endOfDocument)
      else { return nil }
      let bounds = editor.selectionRects(for: range).reduce(CGRect.null) { result, selection in
        guard !selection.rect.isEmpty, !selection.rect.isInfinite else { return result }
        return result.union(selection.rect)
      }
      guard !bounds.isNull, !bounds.isEmpty else { return nil }
      return .init(editor.convert(bounds, to: window))
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
      let caretFrame = editor.map { view in
        view.convert(view.caretRect(for: view.selectedTextRange?.end ?? view.endOfDocument), to: window)
      }.flatMap { $0.isEmpty ? nil : MessagesViewportFixtureRect($0) }
      if let footer = views.compactMap({ $0 as? MessagesViewportFooterMarker.MarkerView }).first {
        measurements.footerFrame = footer.convert(footer.bounds, to: window)
      }
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
        fixtureInstanceID: source.instanceID,
        sampleCount: sampleCount, resetSequence: resetSequence, messageCount: source.messages.count,
        localRevision: source.localRevision, sendCallbackCount: source.sendCallbackCount,
        backdrop: measurements.backdrop, scale: Double(scale),
        collectionIdentity: identity(collection), editorIdentity: editor.map { self.identity($0) },
        collectionFrame: .init(collection.convert(collection.bounds, to: window)),
        footerFrame: .init(measurements.footerFrame),
        editorFrame: .init(editor.map { $0.convert($0.bounds, to: window) } ?? .zero),
        caretFrame: caretFrame,
        editorFontLineHeight: editor.flatMap { $0.font }.map { Double($0.lineHeight) },
        editorTextContainerInset: editor.map { .init($0.textContainerInset) },
        editorContentInset: editor.map { .init($0.contentInset) },
        editorContentSize: editor.map { .init($0.contentSize) },
        editorContentOffset: editor.map { .init($0.contentOffset) },
        editorTextBounds: editor.flatMap { textBounds(of: $0, in: window) },
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
        topHeldSeconds: topHeldSeconds, bottomHeldSeconds: bottomHeldSeconds
      )
      measurements.latest = snapshot
      if let data = try? JSONEncoder().encode(snapshot) {
        accessibilityValue = String(decoding: data, as: UTF8.self)
      }
      observeGestures(collection: collection, editor: editor, window: window,
        top: top, bottom: bottom, time: time, quiet: quiet)
    }

    private func observeGestures(collection: ChatTranscriptCollectionView, editor: UITextView?,
      window: UIWindow, top: CGFloat, bottom: CGFloat, time: TimeInterval, quiet: Bool) {
      let newRequest = gestureSequence != measurements.gestureSequence
      if newRequest {
        gestureSequence = measurements.gestureSequence
        gestureRequestedAt = time
        gestureQuietSince = nil
        tracedRecognizers = []
        gestureTrace = .init(sequence: gestureSequence, kind: measurements.gestureKind)
      }
      guard var trace = gestureTrace, trace.status == "waitingForTarget" || trace.status == "recording"
      else { return }
      let previousStatus = trace.status
      let previousFrameCount = trace.recordedFrameCount
      let frame = collection.convert(collection.bounds, to: window)
      let footer = measurements.footerFrame
      if trace.status == "waitingForTarget" {
        // Both native drags use the same measured vertical travel on identical
        // launches. Hit-testing is read-only and waits for the menu to disappear.
        let upper = frame.minY + 16
        let lower = min(frame.maxY, footer.minY) - 16
        let travel = min(CGFloat(200), max(0, lower - upper) * 0.4)
        let startY = min(max(frame.midY - travel / 2, upper), lower - travel)
        let start = CGPoint(x: frame.minX + frame.width * (trace.kind == "center" ? 0.5 : 0.97), y: startY)
        let end = CGPoint(x: start.x, y: start.y + travel)
        if travel > 0, let hit = window.hitTest(start, with: nil), hit.isDescendant(of: collection) {
          trace.status = "recording"
          trace.collectionIdentity = identity(collection)
          trace.fixtureInstanceID = source.instanceID
          trace.editorIdentity = editor.map { self.identity($0) }
          trace.collectionFrame = .init(frame)
          trace.footerFrame = .init(footer)
          trace.baselineSample = measurements.latest
          trace.start = .init(start); trace.end = .init(end)
          trace.armedAt = time
          var views: [UIView] = []
          var ancestor: UIView? = hit
          while let view = ancestor, views.count < trace.viewLimit {
            views.append(view)
            ancestor = view.superview
          }
          trace.viewPathTruncated = ancestor != nil
          trace.viewPath = views.map { self.describe($0, in: window) }
          // Keep the native collection pan first even if the hit-view ancestor
          // path is truncated. Inspect no delegates or private recognizer APIs.
          tracedRecognizers = [collection.panGestureRecognizer]
          var seen: Set<ObjectIdentifier> = [ObjectIdentifier(collection.panGestureRecognizer)]
          for view in views {
            for recognizer in view.gestureRecognizers ?? [] where seen.insert(ObjectIdentifier(recognizer)).inserted {
              if tracedRecognizers.count < trace.recognizerLimit { tracedRecognizers.append(recognizer) }
              else { trace.recognizersTruncated = true }
            }
          }
          trace.recognizers = tracedRecognizers.map { recognizer in
            MessagesViewportGestureRecognizer(identity: self.identity(recognizer),
              className: String(String(reflecting: type(of: recognizer)).prefix(96)),
              owner: recognizer.view.map { self.describe($0, in: window) },
              isCollectionPan: recognizer === collection.panGestureRecognizer)
          }
        }
      }
      if trace.status == "recording" {
        let states = tracedRecognizers.map { recognizer in
          let touches = recognizer.numberOfTouches
          let active = recognizer.state == .began || recognizer.state == .changed
          let pan = recognizer as? UIPanGestureRecognizer
          return MessagesViewportGestureState(identity: self.identity(recognizer),
            state: self.stateName(recognizer.state), numberOfTouches: touches,
            location: touches > 0 || active ? .init(recognizer.location(in: window)) : nil,
            translation: pan.map { .init($0.translation(in: window)) },
            velocity: pan.map { .init($0.velocity(in: window)) })
        }
        let touchInTranscript = states.contains { state in
          guard state.numberOfTouches > 0, let point = state.location else { return false }
          return frame.contains(CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))) && point.y < Double(footer.minY)
        }
        trace.inputObserved = trace.inputObserved || collection.isTracking || collection.isDragging || touchInTranscript
        let offset = Double(collection.contentOffset.y)
        trace.minimumOffsetY = min(trace.minimumOffsetY ?? offset, offset)
        trace.maximumOffsetY = max(trace.maximumOffsetY ?? offset, offset)
        trace.finalCollectionIdentity = identity(collection)
        trace.finalEditorIdentity = editor.map { self.identity($0) }
        trace.finalSample = measurements.latest
        let observation = MessagesViewportGestureFrame(timestamp: time, offsetY: offset,
          legalTop: Double(top), legalBottom: Double(bottom),
          isTracking: collection.isTracking, isDragging: collection.isDragging,
          isDecelerating: collection.isDecelerating, recognizers: states)
        trace.observedFrameCount += 1
        if trace.inputObserved && trace.firstInputFrame == nil { trace.firstInputFrame = observation }
        let recognizersQuiet = states.allSatisfy { $0.numberOfTouches == 0 && $0.state != "began" && $0.state != "changed" }
        if trace.inputObserved && trace.firstReleasedFrame == nil && recognizersQuiet
          && !collection.isTracking && !collection.isDragging {
          trace.firstReleasedFrame = observation
        }
        // Observe at display-link cadence, but retain state/offset transitions
        // plus at most 10Hz unchanged baseline samples. Touch onset and release
        // are separately retained even if pre-drag XCTest latency fills the ring.
        let previous = trace.timeline.last
        let changed = previous.map { prior in
          abs(prior.offsetY - offset) > Double(2 / window.screen.scale)
            || prior.isTracking != observation.isTracking || prior.isDragging != observation.isDragging
            || prior.isDecelerating != observation.isDecelerating
            || zip(prior.recognizers, states).contains { old, new in
              old.state != new.state || old.numberOfTouches != new.numberOfTouches
            }
        } ?? true
        if changed || time - (previous?.timestamp ?? time) >= 0.1 {
          trace.timeline.append(observation)
          trace.recordedFrameCount += 1
          if trace.timeline.count > trace.timelineLimit {
            trace.timeline.remove(at: 8) // Retain the first eight and the latest samples.
            trace.droppedRecordCount += 1
          }
        }
        gestureQuietSince = trace.inputObserved && quiet && recognizersQuiet ? (gestureQuietSince ?? time) : nil
        if let since = gestureQuietSince, time - since >= 0.4 {
          trace.status = "captured"
          trace.completedAt = time
        }
      }
      if time - (gestureRequestedAt ?? time) >= 8, trace.status != "captured" {
        trace.status = "timedOut"
        trace.completedAt = time
      }
      gestureTrace = trace
      if newRequest || trace.status != previousStatus || trace.recordedFrameCount != previousFrameCount {
        publishGestureTrace()
      }
      if trace.status == "captured" || trace.status == "timedOut" { tracedRecognizers = [] }
    }

    private func publishGestureTrace() {
      guard var trace = gestureTrace, var data = try? JSONEncoder().encode(trace) else { return }
      // Bound the actual AX payload as well as record count. Retain the first
      // eight and the end of the native drag; account for every removed record.
      while data.count > trace.byteLimit && trace.timeline.count > 8 {
        trace.timeline.remove(at: 8)
        trace.droppedRecordCount += 1
        guard let smaller = try? JSONEncoder().encode(trace) else { return }
        data = smaller
      }
      gestureTrace = trace
      guard data.count <= trace.byteLimit else {
        measurements.gestureReadout?.accessibilityValue =
          "{\"sequence\":\(trace.sequence),\"status\":\"byteLimitExceeded\"}"
        return
      }
      measurements.gestureReadout?.accessibilityValue = String(decoding: data, as: UTF8.self)
    }

    private func identity(_ object: AnyObject) -> String { String(describing: ObjectIdentifier(object)) }

    private func describe(_ view: UIView, in window: UIWindow) -> MessagesViewportGestureView {
      .init(identity: identity(view), className: String(String(reflecting: type(of: view)).prefix(96)),
        frame: .init(view.convert(view.bounds, to: window)))
    }

    private func stateName(_ state: UIGestureRecognizer.State) -> String {
      switch state {
      case .possible: return "possible"
      case .began: return "began"
      case .changed: return "changed"
      case .ended: return "ended"
      case .cancelled: return "cancelled"
      case .failed: return "failed"
      @unknown default: return "unknown"
      }
    }

    private func descendants(of view: UIView) -> [UIView] {
      [view] + view.subviews.flatMap { descendants(of: $0) }
    }


  }
}

private struct ChatPresentationWidthModifier: ViewModifier {
  let enabled: Bool
  let narrow: Bool
  @ViewBuilder
  func body(content: Content) -> some View {
    if enabled { content.frame(maxWidth: narrow ? 260 : 600) } else { content }
  }
}

/// Reads visible native cells and public interaction types. An explicit DEBUG
/// toolbar request can invoke the existing accessible-actions presentation route;
/// it never scrolls, resizes, reloads or synthesizes a touch context menu.
private struct ChatPresentationNativeProbe: UIViewRepresentable {
  let source: MessagesViewportFixtureSource
  let navigationDepth: Int
  func makeUIView(context: Context) -> ProbeView { ProbeView(source: source) }
  func updateUIView(_ uiView: ProbeView, context: Context) {
    uiView.navigationDepth = navigationDepth
    uiView.publish()
  }
  static func dismantleUIView(_ uiView: ProbeView, coordinator: ()) { uiView.stop() }

  @MainActor
  final class ProbeView: UIView {
    let source: MessagesViewportFixtureSource
    private var timer: Timer?
    private let initialPasteboardChangeCount = UIPasteboard.general.changeCount
    private var handledAccessibleRequest = 0
    var navigationDepth = 0
    init(source: MessagesViewportFixtureSource) {
      self.source = source
      super.init(frame: .zero)
      isUserInteractionEnabled = false
      isAccessibilityElement = true
      accessibilityIdentifier = "chat.fixture.presentation"
      accessibilityLabel = "Local message presentation state"
      accessibilityTraits = .staticText
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() {
      super.didMoveToWindow()
      stop()
      guard window != nil else { return }
      timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.publish() }
      }
      publish()
    }
    func stop() { timer?.invalidate(); timer = nil }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    func publish() {
      guard let window,
        let collection = descendants(window).compactMap({ $0 as? ChatTranscriptCollectionView }).first else { return }
      var rows: [[String: Any]] = []
      for cell in collection.visibleCells {
        guard let index = collection.indexPath(for: cell)?.item, index > 0,
          source.messages.indices.contains(index - 1) else { continue }
        let id = source.messages[index - 1].id
        cell.accessibilityIdentifier = "chat.fixture.cell." + id
        let frame = cell.convert(cell.bounds, to: window)
        rows.append(["id": id, "cellIdentity": String(describing: ObjectIdentifier(cell)),
          "x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height])
      }
      let interactions = descendants(collection).flatMap(\.interactions)
        .filter { $0 is UIContextMenuInteraction }.count
      var responder: UIResponder? = collection
      var nativeMenuRequests = 0
      var nativeMenuAttempts = 0
      var nativeMenuStatus = "reporter-unavailable"
      var nativeMenuAnchor = "reporter-unavailable"
      while let current = responder {
        if let reporter = current as? ChatMessageContextMenuFixtureReporting {
          nativeMenuRequests = reporter.fixtureNativeContextMenuRequestCount
          nativeMenuAttempts = reporter.fixtureNativeContextMenuAttemptCount
          nativeMenuStatus = reporter.fixtureNativeContextMenuLastStatus
          nativeMenuAnchor = reporter.fixtureMessageMenuAnchorStatus(messageID: MessagesViewportFixtureSource.presentationID)
          if source.presentationAccessibleRequest > handledAccessibleRequest {
            handledAccessibleRequest = source.presentationAccessibleRequest
            Task { @MainActor [weak reporter] in
              await Task.yield()
              reporter?.fixturePresentAccessibleMessageActions(messageID: MessagesViewportFixtureSource.presentationID)
            }
          }
          break
        }
        responder = current.next
      }
      // Only compare after a clipboard change in this disposable local fixture.
      // Never expose or retain arbitrary clipboard contents in diagnostics.
      let copiedSyntheticText = source.presentationScenario?.hasPrefix("menu-") == true
        && UIPasteboard.general.changeCount != initialPasteboardChangeCount
        && UIPasteboard.general.string == "Local menu message"
      let value: [String: Any] = ["scenario": source.presentationScenario ?? "",
        "actions": source.presentationActions, "recordRevision": source.presentationRecordRevision,
        "appliedRecordRevision": source.presentationAppliedRecordRevision,
        "nativeMenuRequests": nativeMenuRequests, "copiedSyntheticText": copiedSyntheticText,
        "nativeMenuAttempts": nativeMenuAttempts, "nativeMenuStatus": nativeMenuStatus,
        "nativeMenuAnchor": nativeMenuAnchor,
        "navigationDepth": navigationDepth, "accessibleRequestsHandled": handledAccessibleRequest,
        "contentSizeCategory": collection.traitCollection.preferredContentSizeCategory.rawValue,
        "applicationContentSizeCategory": UIApplication.shared.preferredContentSizeCategory.rawValue,
        "sendCount": source.sendCallbackCount, "nativeMenuInteractions": interactions,
        "rows": rows, "collectionIdentity": String(describing: ObjectIdentifier(collection))]
      if let data = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys) {
        accessibilityValue = String(decoding: data, as: UTF8.self)
      }
    }
  }
}

#endif
