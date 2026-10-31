import SwiftUI
import Testing
@testable import Catbird

@MainActor
struct AskCatbirdPresentationActionTests {
  @Test("The production send/stop handler respects disabled and whitespace states")
  func composerDispatch() {
    var sends = 0
    var stops = 0
    func composer(text: String, responding: Bool = false, disabled: Bool = false) -> AskCatbirdComposer {
      AskCatbirdComposer(text: .constant(text), selectedImageID: .constant(nil), candidates: [],
        imageUnavailableReason: nil, isResponding: responding, isDisabled: disabled,
        hasUnresolvedProposal: false, onSend: { sends += 1 }, onStop: { stops += 1 })
    }
    composer(text: " \n ").performPrimaryAction()
    composer(text: "Hello", disabled: true).performPrimaryAction()
    #expect(sends == 0)
    composer(text: "Hello").performPrimaryAction()
    #expect(sends == 1)
    composer(text: "", responding: true, disabled: true).performPrimaryAction()
    #expect(stops == 1)
    #expect(sends == 1)
  }

  @Test("Source and inline reference callbacks preserve the native route identity")
  func sourceAndProseRoutes() throws {
    let uri = "at://did:plc:fixture/app.bsky.feed.post/a"
    let source = CopilotSource(label: "Selected post", uri: uri)
    let rendered = CopilotReferencePresentation.render("Read \(uri)", sources: [source])
    let proseURL = try #require(rendered.runs.compactMap(\.link).first)
    var openedURLs: [URL] = []
    let routing = AskCatbirdURLRouting(onOpenURL: { openedURLs.append($0); return .handled })
    _ = routing.handle(proseURL)
    var openedSources: [CopilotSource] = []
    let sources = AskCatbirdSourcesView(sources: [source], onSource: { openedSources.append($0) })
    sources.openSource(source)
    sources.openSource(.init(label: "Unavailable source"))
    #expect(openedURLs.map(\.absoluteString) == ["https://bsky.app/profile/did:plc:fixture/post/a"])
    #expect(openedSources == [source])

    let user = ChatTextRenderer.attributedString(for: "See https://bsky.app/profile/maya.example/post/a")
    let userURL = try #require(user.runs.compactMap(\.link).first)
    _ = routing.handle(userURL)
    #expect(openedURLs.last == userURL)
    #expect(openedURLs.count == 2)
  }

  @Test("Proposal callbacks are distinct and disabled actions cannot execute")
  func proposalCallbacks() {
    var actions: [String] = []
    func card(disabled: Bool) -> AskCatbirdProposalCard {
      AskCatbirdProposalCard(confirmation: "Review draft?", isDedicatedFlow: true,
        isDisabled: disabled, onConfirm: { actions.append("confirm") }, onCancel: { actions.append("dismiss") })
    }
    card(disabled: true).confirm()
    card(disabled: true).dismissSuggestion()
    #expect(actions.isEmpty)
    card(disabled: false).confirm()
    card(disabled: false).dismissSuggestion()
    #expect(actions == ["confirm", "dismiss"])
  }
}
