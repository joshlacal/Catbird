import Foundation
import Testing
@testable import Catbird

@MainActor
struct FeedPreferenceEditorTests {
  @Test("Opening reads without writing or clearing a local source")
  func openingIsReadOnly() async {
    var writes = 0
    let editor = FeedPreferenceEditor(accountDID: "fixture", isCurrentAccount: { true },
      read: { FeedViewPreference(hideReplies: true, hideRepliesByUnfollowed: nil, hideRepliesByLikeCount: nil, hideReposts: nil, hideQuotePosts: nil) }, write: { _, _ in writes += 1; return nil })
    await editor.load()
    #expect(editor.hasLoaded)
    #expect(editor.confirmed?.hideReplies == true)
    #expect(writes == 0)
  }

  @Test("A failed sparse save retains its edit and clears local sources only after confirmation")
  func localSourceWaitsForAcceptedSave() async {
    var localHidden = true
    var writes: [FeedPreferenceEdit] = []
    var fail = true
    let editor = FeedPreferenceEditor(accountDID: "fixture", isCurrentAccount: { true },
      read: { FeedViewPreference(hideReplies: true, hideRepliesByUnfollowed: nil, hideRepliesByLikeCount: nil, hideReposts: nil, hideQuotePosts: nil) }, write: { edit, did in
        #expect(did == "fixture")
        writes.append(edit)
        if fail { throw NSError(domain: "Fixture", code: 1) }
        return FeedViewPreference(hideReplies: false, hideRepliesByUnfollowed: nil, hideRepliesByLikeCount: nil, hideReposts: nil, hideQuotePosts: nil)
      })
    await editor.load()
    await editor.submit(.replies(false)) { localHidden = false }
    #expect(localHidden)
    #expect(editor.confirmed?.hideReplies == true)
    #expect(editor.pending == .replies(false))
    fail = false
    await editor.retry()
    #expect(!localHidden)
    #expect(editor.confirmed?.hideReplies == false)
    #expect(editor.pending == nil)
    #expect(writes == [.replies(false), .replies(false)])
  }

  @Test("Account replacement prevents a suspended edit from reconciling device filters")
  func accountFence() async {
    var active = true
    var clearedLocal = false
    let editor = FeedPreferenceEditor(accountDID: "fixture", isCurrentAccount: { active },
      read: { FeedViewPreference(hideReplies: true, hideRepliesByUnfollowed: nil, hideRepliesByLikeCount: nil, hideReposts: nil, hideQuotePosts: nil) }, write: { _, _ in
        active = false
        return FeedViewPreference(hideReplies: false, hideRepliesByUnfollowed: nil, hideRepliesByLikeCount: nil, hideReposts: nil, hideQuotePosts: nil)
      })
    await editor.load()
    await editor.submit(.replies(false)) { clearedLocal = true }
    #expect(!clearedLocal)
    #expect(editor.confirmed?.hideReplies == true)
  }
}
