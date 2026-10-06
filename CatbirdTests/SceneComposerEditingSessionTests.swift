import Foundation
import SwiftData
import Testing
@testable import Catbird

@MainActor
@Suite("Scene Composer Editing Sessions")
struct SceneComposerEditingSessionTests {
  @Test("Two scenes stash and discard only their own saved rows")
  func twoScenesKeepSavedRowsIndependent() throws {
    let fixture = try Fixture()
    let rowA = try fixture.save(makeDraft("Scene A"))
    let rowB = try fixture.save(makeDraft("Scene B"))
    let sceneA = fixture.session()
    let sceneB = fixture.session()
    defer {
      sceneA.invalidate()
      sceneB.invalidate()
      fixture.cleanUp()
    }
    let claimA = try sceneA.restoreSaved(DraftPostViewModel(draftPost: rowA))
    let claimB = try sceneB.restoreSaved(DraftPostViewModel(draftPost: rowB))

    #expect(sceneA.update(makeDraft("A edited"), claim: claimA))
    #expect(sceneB.update(makeDraft("B edited"), claim: claimB))
    let capturedA = try #require(sceneA.snapshot())
    let savedID = try sceneA.stash(capturedA)

    #expect(savedID == rowA.id)
    #expect(try rowA.decodeDraft().postText == "A edited")
    #expect(try rowB.decodeDraft().postText == "Scene B")
    #expect(sceneA.currentDraft == nil)
    #expect(sceneB.currentDraft?.postText == "B edited")
    #expect(sceneB.savedDraftID == rowB.id)

    #expect(sceneB.discard(claim: claimB))
    #expect(try fixture.persistence.syncState(for: rowA).deletedAt == nil)
    #expect(try fixture.persistence.syncState(for: rowB).deletedAt != nil)
    #expect(try fixture.persistence.fetchDrafts(for: fixture.accountDID).map(\.id) == [rowA.id])
  }

  @Test("Debounced autosave writes each scene body into its explicitly claimed row")
  func autosaveWritesOnlyClaimedRows() async throws {
    let fixture = try Fixture()
    let rowA = try fixture.save(makeDraft("Stored A"))
    let rowB = try fixture.save(makeDraft("Stored B"))
    let sceneA = fixture.session(persistDelay: .milliseconds(5))
    let sceneB = fixture.session(persistDelay: .milliseconds(5))
    defer {
      sceneA.invalidate()
      sceneB.invalidate()
      fixture.cleanUp()
    }
    let claimA = try sceneA.restoreSaved(DraftPostViewModel(draftPost: rowA))
    let claimB = try sceneB.restoreSaved(DraftPostViewModel(draftPost: rowB))
    #expect(sceneA.update(makeDraft("Autosaved A"), claim: claimA))
    #expect(sceneB.update(makeDraft("Autosaved B"), claim: claimB))
    for _ in 0..<100 {
      if try rowA.decodeDraft().postText == "Autosaved A",
         try rowB.decodeDraft().postText == "Autosaved B" { break }
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(try rowA.decodeDraft().postText == "Autosaved A")
    #expect(try rowB.decodeDraft().postText == "Autosaved B")
    #expect(sceneA.savedDraftID == rowA.id)
    #expect(sceneB.savedDraftID == rowB.id)
    #expect(sceneA.activeClaim == claimA)
    #expect(sceneB.activeClaim == claimB)
  }

  @Test("A saved row has one writable scene claim until its owner releases it")
  func savedRowClaimIsExclusive() throws {
    let fixture = try Fixture()
    let row = try fixture.save(makeDraft("Exclusive saved row"))
    let sceneA = fixture.session()
    let sceneB = fixture.session()
    defer {
      sceneA.invalidate()
      sceneB.invalidate()
      fixture.cleanUp()
    }
    let claimA = try sceneA.restoreSaved(DraftPostViewModel(draftPost: row))
    let claimB = try sceneB.beginNew(draft: makeDraft("Existing scene B work"))

    #expect(throws: (any Error).self) {
      try sceneB.restoreSaved(DraftPostViewModel(draftPost: row))
    }
    #expect(sceneA.activeClaim == claimA)
    #expect(sceneB.activeClaim == claimB)
    #expect(sceneB.currentDraft?.postText == "Existing scene B work")
    #expect(sceneB.savedDraftID == nil)

    sceneA.invalidate()
    let releasedClaim = try sceneB.restoreSaved(DraftPostViewModel(draftPost: row))
    #expect(releasedClaim != claimA)
    #expect(sceneB.savedDraftID == row.id)
    #expect(!sceneA.discard(claim: claimA))
    #expect(try fixture.persistence.syncState(for: row).deletedAt == nil)
  }

  @Test("Separate managers for the same account still share one saved-row claim")
  func managerReplacementCannotStealSavedRow() throws {
    let fixture = try Fixture()
    let row = try fixture.save(makeDraft("Shared account row"))
    let first = fixture.session()
    let secondManager = ComposerDraftManager(
      accountDID: fixture.accountDID,
      modelContext: fixture.container.mainContext,
      defaults: fixture.defaults
    )
    let second = SceneComposerEditingSession(
      manager: secondManager, accountDID: fixture.accountDID,
      sceneID: UUID(), defaults: fixture.defaults
    )
    defer {
      first.invalidate()
      second.invalidate()
      fixture.cleanUp()
    }
    let firstClaim = try first.restoreSaved(DraftPostViewModel(draftPost: row))
    #expect(throws: (any Error).self) {
      try second.restoreSaved(DraftPostViewModel(draftPost: row))
    }
    #expect(first.activeClaim == firstClaim)
    #expect(second.activeClaim == nil)
    secondManager.deleteSavedDraft(row.id)
    #expect(try fixture.persistence.syncState(for: row).deletedAt == nil)

    first.invalidate()
    let secondClaim = try second.restoreSaved(DraftPostViewModel(draftPost: row))
    #expect(secondClaim != firstClaim)
    #expect(second.savedDraftID == row.id)
    #expect(try fixture.persistence.syncState(for: row).deletedAt == nil)
  }

  @Test("A resumed composer replaces its presentation lease without releasing the saved row")
  func resumedEditorRejectsDismissedModelsCallback() async throws {
    let fixture = try Fixture()
    let row = try fixture.save(makeDraft("Owned saved editor"))
    let scene = fixture.session()
    defer { scene.invalidate(); fixture.cleanUp() }
    let claim = try scene.restoreSaved(DraftPostViewModel(draftPost: row))
    let oldEditor = UUID()
    let newEditor = UUID()
    #expect(scene.claimEditor(oldEditor, claim: claim))
    let before = try #require(scene.snapshot())
    let lateDraft = makeDraft("Dismissed model media callback")
    let callback = Task { @MainActor in
      guard scene.ownsEditor(oldEditor, claim: claim) else { return false }
      return scene.update(lateDraft, claim: claim)
    }
    #expect(scene.minimize(claim: claim))
    #expect(scene.resume(claim: claim))
    #expect(scene.claimEditor(newEditor, claim: claim))
    let callbackApplied = await callback.value

    #expect(!callbackApplied)
    #expect(!scene.ownsEditor(oldEditor, claim: claim))
    #expect(!scene.releaseEditor(oldEditor, claim: claim))
    #expect(scene.ownsEditor(newEditor, claim: claim))
    #expect(scene.activeClaim == claim)
    #expect(scene.savedDraftID == row.id)
    #expect(scene.snapshot()?.revision == before.revision)
    #expect(scene.currentDraft?.postText == "Owned saved editor")
    #expect(scene.releaseEditor(newEditor, claim: claim))
    #expect(!scene.ownsEditor(newEditor, claim: claim))
  }

  @Test("Presentation leases clear on replacement, completion and invalidation")
  func presentationLeasesFollowEditorLifecycle() throws {
    let fixture = try Fixture()
    let scene = fixture.session()
    defer { scene.invalidate(); fixture.cleanUp() }
    let editorID = UUID()
    let oldClaim = try scene.beginNew(draft: makeDraft("First editor"))
    #expect(scene.claimEditor(editorID, claim: oldClaim))
    let replacement = try scene.beginNew(draft: makeDraft("Replacement editor"))
    #expect(!scene.ownsEditor(editorID, claim: oldClaim))
    #expect(!scene.ownsEditor(editorID, claim: replacement))
    #expect(scene.claimEditor(editorID, claim: replacement))
    let saved = try #require(scene.snapshot())
    _ = try scene.stash(saved)
    #expect(!scene.ownsEditor(editorID, claim: replacement))
    let finalClaim = try scene.beginNew()
    #expect(!scene.ownsEditor(editorID, claim: finalClaim))
    #expect(scene.claimEditor(editorID, claim: finalClaim))
    scene.invalidate()
    #expect(!scene.ownsEditor(editorID, claim: finalClaim))
    #expect(!scene.claimEditor(UUID(), claim: finalClaim))
  }

  @Test("A cancelled attachment cannot take the current presentation lease")
  func cancelledEditorAttachmentDoesNotStealLease() async throws {
    let fixture = try Fixture()
    let scene = fixture.session()
    defer { scene.invalidate(); fixture.cleanUp() }
    let claim = try scene.beginNew()
    let owner = UUID()
    #expect(scene.claimEditor(owner, claim: claim))
    let task = Task { @MainActor in scene.claimEditor(UUID(), claim: claim) }
    task.cancel()
    let attached = await task.value
    #expect(!attached)
    #expect(scene.ownsEditor(owner, claim: claim))
  }

  @Test("Remote changes survive an open editor's stash, discard and submission", arguments: ["stash", "discard", "submission"])
  func changedLiveRowCannotBeOverwrittenOrTombstoned(operation: String) throws {
    let fixture = try Fixture()
    let initial = makeDraft("Original saved version")
    let local = makeDraft("Current local editor")
    let remote = makeDraft("New remote saved version")
    let row = try fixture.save(initial)
    row.remoteId = "remote-existing-draft"
    let scene = fixture.session()
    defer { scene.invalidate(); fixture.cleanUp() }
    let claim = try scene.restoreSaved(DraftPostViewModel(draftPost: row))
    #expect(scene.update(local, claim: claim))
    let captured = try #require(scene.snapshot())
    try row.apply(remote)
    row.touch()
    var remoteState = DraftSyncState()
    remoteState.baselineLocal = remote
    try fixture.persistence.saveSyncState(remoteState, for: row)
    let remoteBytes = row.draftData
    let remoteMetadata = row.syncMetadata
    let remoteModified = row.modifiedDate

    switch operation {
    case "stash":
      #expect(throws: (any Error).self) { try scene.stash(captured) }
    case "discard":
      #expect(!scene.discard(claim: claim))
    default:
      #expect(!scene.completeSubmission(captured))
    }

    #expect(row.draftData == remoteBytes)
    #expect(row.syncMetadata == remoteMetadata)
    #expect(row.modifiedDate == remoteModified)
    #expect(row.remoteId == "remote-existing-draft")
    #expect(try fixture.persistence.syncState(for: row).deletedAt == nil)
    #expect(scene.currentDraft == local)
    let recoveryID = try #require(scene.savedDraftID)
    #expect(recoveryID != row.id)
    let fetchedRecovery = try fixture.persistence.fetchDraftModel(id: recoveryID)
    let recovery = try #require(fetchedRecovery)
    #expect(try recovery.decodeDraft() == local)
    #expect(try fixture.persistence.syncState(for: recovery).recoveryReason != nil)
    #expect(fixture.manager.savedDrafts.contains { $0.id == recoveryID })
    #expect(!scene.completeSubmission(captured))
    let otherScene = fixture.session()
    defer { otherScene.invalidate() }
    _ = try otherScene.restoreSaved(DraftPostViewModel(draftPost: row))
    #expect(otherScene.currentDraft == remote)
  }

  @Test("Autosave preserves both versions when remote sync changed the open saved row")
  func autosaveDetectsChangedLiveSavedRow() async throws {
    let fixture = try Fixture()
    let row = try fixture.save(makeDraft("Original saved version"))
    let scene = fixture.session(persistDelay: .milliseconds(5))
    defer { scene.invalidate(); fixture.cleanUp() }
    let claim = try scene.restoreSaved(DraftPostViewModel(draftPost: row))
    let local = makeDraft("Unsaved local autosave content")
    #expect(scene.update(local, claim: claim))
    let remote = makeDraft("Remote replaced the stored version")
    try row.apply(remote)
    row.touch()
    try fixture.container.mainContext.save()
    let remoteBytes = row.draftData
    let remoteMetadata = row.syncMetadata
    let remoteModified = row.modifiedDate
    for _ in 0..<100 {
      if scene.savedDraftID != row.id { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(scene.savedDraftID != row.id)
    #expect(scene.currentDraft == local)
    #expect(row.draftData == remoteBytes)
    #expect(row.syncMetadata == remoteMetadata)
    #expect(row.modifiedDate == remoteModified)
    #expect(try fixture.persistence.syncState(for: row).deletedAt == nil)
    let recoveryID = try #require(scene.savedDraftID)
    let fetchedRecovery = try fixture.persistence.fetchDraftModel(id: recoveryID)
    let recovery = try #require(fetchedRecovery)
    #expect(try recovery.decodeDraft() == local)
    #expect(try fixture.persistence.syncState(for: recovery).recoveryReason != nil)
  }

  @Test("Live typing is preserved before invalidation, replacement and transfer", arguments: ["invalidate", "replace", "transfer"])
  func liveProviderPreservesTypingWithoutAutosave(action: String) throws {
    let fixture = try Fixture()
    let scene = fixture.session()
    defer { scene.invalidate(); fixture.cleanUp() }
    let initial = makeDraft("Last autosaved body")
    let latest = makeDraft("Final typing with autosave disabled")
    let provider = LiveDraftBox(draft: latest)
    let editorID = UUID()
    let claim = try scene.beginNew(draft: initial)
    #expect(scene.claimEditor(editorID, claim: claim))
    let providerRegistered = scene.registerLiveDraftProvider(editorID: editorID, claim: claim) { [weak provider] in
      provider?.draft
    }
    #expect(providerRegistered)
    let earlier = try #require(scene.snapshot())
    #expect(earlier.draft == initial)

    switch action {
    case "invalidate":
      scene.invalidate()
    case "replace":
      _ = try scene.beginNew(draft: makeDraft("Next composer"))
      #expect(scene.currentDraft?.postText == "Next composer")
    default:
      #expect(!scene.detachForTransfer(earlier))
      #expect(scene.currentDraft == latest)
      #expect(scene.activeClaim == claim)
      let refreshed = try #require(scene.snapshot())
      #expect(refreshed.revision > earlier.revision)
      #expect(scene.detachForTransfer(refreshed))
    }

    let recoveries = try fixture.persistence.fetchDrafts(for: fixture.accountDID)
    #expect(recoveries.count == 1)
    let recovery = try #require(recoveries.first)
    #expect(try recovery.decodeDraft() == latest)
    #expect(try fixture.persistence.syncState(for: recovery).recoveryReason != nil)
  }

  @Test("A stale provider or unregister cannot replace the current presentation's live typing")
  func liveProviderOwnershipIsExact() throws {
    let fixture = try Fixture()
    let scene = fixture.session()
    defer { scene.invalidate(); fixture.cleanUp() }
    let claim = try scene.beginNew(draft: makeDraft("Initial body"))
    let oldEditor = UUID()
    let newEditor = UUID()
    let oldProvider = LiveDraftBox(draft: makeDraft("Last outgoing typing"))
    let newProvider = LiveDraftBox(draft: makeDraft("New presentation live typing"))
    var oldCalls = 0
    var newCalls = 0
    #expect(scene.claimEditor(oldEditor, claim: claim))
    let oldProviderRegistered = scene.registerLiveDraftProvider(editorID: oldEditor, claim: claim) { [weak oldProvider] in
      oldCalls += 1
      return oldProvider?.draft
    }
    #expect(oldProviderRegistered)
    #expect(scene.claimEditor(newEditor, claim: claim))
    #expect(scene.currentDraft == oldProvider.draft)
    let newProviderRegistered = scene.registerLiveDraftProvider(editorID: newEditor, claim: claim) { [weak newProvider] in
      newCalls += 1
      return newProvider?.draft
    }
    #expect(newProviderRegistered)
    #expect(!scene.unregisterLiveDraftProvider(editorID: oldEditor, claim: claim))
    let staleProviderRegistered = scene.registerLiveDraftProvider(editorID: oldEditor, claim: claim) { [weak oldProvider] in
      oldProvider?.draft
    }
    #expect(!staleProviderRegistered)
    oldProvider.draft = makeDraft("Stale dismissed view model mutation")
    #expect(scene.minimize(claim: claim))
    #expect(scene.currentDraft == newProvider.draft)
    #expect(oldCalls == 1)
    #expect(newCalls == 1)
    let replacement = try scene.beginNew(draft: makeDraft("Next draft claim"))
    #expect(!scene.unregisterLiveDraftProvider(editorID: newEditor, claim: claim))
    #expect(scene.claimEditor(newEditor, claim: replacement))
    #expect(!scene.unregisterLiveDraftProvider(editorID: newEditor, claim: claim))
    #expect(scene.currentDraft?.postText == "Next draft claim")
  }

  @Test("A weak live provider does not retain its view model owner")
  func liveProviderDoesNotRetainOwner() throws {
    let fixture = try Fixture()
    let scene = fixture.session()
    defer { scene.invalidate(); fixture.cleanUp() }
    let original = makeDraft("Previously captured content")
    let claim = try scene.beginNew(draft: original)
    let editorID = UUID()
    #expect(scene.claimEditor(editorID, claim: claim))
    var owner: LiveDraftBox? = LiveDraftBox(draft: makeDraft("Released model"))
    weak var weakOwner = owner
    let providerRegistered = scene.registerLiveDraftProvider(editorID: editorID, claim: claim) { [weak owner] in
      owner?.draft
    }
    #expect(providerRegistered)
    owner = nil
    #expect(weakOwner == nil)
    scene.invalidate()
    let rows = try fixture.persistence.fetchDrafts(for: fixture.accountDID)
    let recovery = try #require(rows.first)
    #expect(try recovery.decodeDraft() == original)
  }

  @Test("Cancelled scene teardown still flushes the exact current live provider")
  func cancelledInvalidationPreservesLiveTyping() async throws {
    let fixture = try Fixture()
    let scene = fixture.session()
    defer { scene.invalidate(); fixture.cleanUp() }
    let claim = try scene.beginNew(draft: makeDraft("Autosaved body"))
    let editorID = UUID()
    let owner = LiveDraftBox(draft: makeDraft("Live body during cancelled teardown"))
    #expect(scene.claimEditor(editorID, claim: claim))
    let providerRegistered = scene.registerLiveDraftProvider(editorID: editorID, claim: claim) { [weak owner] in
      owner?.draft
    }
    #expect(providerRegistered)
    let task = Task { @MainActor in scene.invalidate() }
    task.cancel()
    await task.value
    let rows = try fixture.persistence.fetchDrafts(for: fixture.accountDID)
    let recovery = try #require(rows.first)
    #expect(try recovery.decodeDraft() == owner.draft)
    #expect(scene.snapshot() == nil)
  }

  @Test("A stale token cannot edit, minimize, discard, save, or complete a replacement editor")
  func replacedEditorRejectsStaleCallbacks() throws {
    let fixture = try Fixture()
    let scene = fixture.session()
    defer { scene.invalidate(); fixture.cleanUp() }
    let oldClaim = try scene.beginNew(draft: makeDraft("Old editor"))
    let submitted = try #require(scene.snapshot())
    let replacement = try scene.beginNew(draft: makeDraft("Replacement editor"))

    #expect(replacement != oldClaim)
    #expect(!scene.update(makeDraft("Late autosave"), claim: oldClaim))
    #expect(!scene.minimize(claim: oldClaim))
    #expect(!scene.resume(claim: oldClaim))
    #expect(!scene.discard(claim: oldClaim))
    #expect(!scene.completeSubmission(submitted))
    #expect(!scene.detachForTransfer(submitted))
    #expect(throws: (any Error).self) { try scene.stash(submitted) }
    #expect(scene.activeClaim == replacement)
    #expect(scene.currentDraft?.postText == "Replacement editor")
    #expect(scene.savedDraftID == nil)
  }

  @Test("Another scene or account cannot use a captured claim")
  func foreignClaimsCannotMutateSession() throws {
    let fixture = try Fixture()
    let sceneA = fixture.session()
    let sceneB = fixture.session()
    let otherAccount = fixture.session(accountDID: "did:plc:other-account")
    defer {
      sceneA.invalidate()
      sceneB.invalidate()
      otherAccount.invalidate()
      fixture.cleanUp()
    }
    let claimA = try sceneA.beginNew(draft: makeDraft("Owned content"))
    let claimB = try sceneB.beginNew(draft: makeDraft("Other scene"))
    let otherClaim = try otherAccount.beginNew(draft: makeDraft("Other account"))

    for foreignClaim in [claimB, otherClaim] {
      #expect(!sceneA.update(makeDraft("Foreign autosave"), claim: foreignClaim))
      #expect(!sceneA.minimize(claim: foreignClaim))
      #expect(!sceneA.discard(claim: foreignClaim))
    }
    let otherSceneSnapshot = try #require(sceneB.snapshot())
    #expect(!sceneA.completeSubmission(otherSceneSnapshot))
    #expect(sceneA.activeClaim == claimA)
    #expect(sceneA.currentDraft?.postText == "Owned content")
    #expect(!sceneA.isMinimized)
  }

  @Test("An older revision cannot save, tombstone, or detach newer typing")
  func staleRevisionDoesNotPersistOrClear() throws {
    let fixture = try Fixture()
    let row = try fixture.save(makeDraft("Saved original"))
    let scene = fixture.session()
    defer { scene.invalidate(); fixture.cleanUp() }
    let claim = try scene.restoreSaved(DraftPostViewModel(draftPost: row))
    let older = try #require(scene.snapshot())
    #expect(scene.update(makeDraft("Newer typing"), claim: claim))
    let latest = try #require(scene.snapshot())

    #expect(latest.revision > older.revision)
    #expect(latest.claim == older.claim)
    #expect(throws: (any Error).self) { try scene.stash(older) }
    #expect(!scene.completeSubmission(older))
    #expect(!scene.detachForTransfer(older))
    #expect(try row.decodeDraft().postText == "Saved original")
    #expect(try fixture.persistence.syncState(for: row).deletedAt == nil)
    #expect(scene.currentDraft?.postText == "Newer typing")
    #expect(scene.savedDraftID == row.id)
  }

  @Test("Successful submission deletes its own row exactly once")
  func successfulSubmissionIsScopedAndCannotRepeat() throws {
    let fixture = try Fixture()
    let rowA = try fixture.save(makeDraft("Submitted A"))
    let rowB = try fixture.save(makeDraft("Unsubmitted B"))
    let sceneA = fixture.session()
    let sceneB = fixture.session()
    defer {
      sceneA.invalidate()
      sceneB.invalidate()
      fixture.cleanUp()
    }
    _ = try sceneA.restoreSaved(DraftPostViewModel(draftPost: rowA))
    let claimB = try sceneB.restoreSaved(DraftPostViewModel(draftPost: rowB))
    let submitted = try #require(sceneA.snapshot())

    #expect(sceneA.completeSubmission(submitted))
    #expect(!sceneA.completeSubmission(submitted))
    #expect(sceneA.snapshot() == nil)
    #expect(try fixture.persistence.syncState(for: rowA).deletedAt != nil)
    #expect(try fixture.persistence.syncState(for: rowB).deletedAt == nil)
    #expect(sceneB.activeClaim == claimB)
    #expect(sceneB.currentDraft?.postText == "Unsubmitted B")
  }

  @Test("Minimize and resume preserve the same claim and saved row")
  func minimizeAndResumeKeepOwnership() throws {
    let fixture = try Fixture()
    let row = try fixture.save(makeDraft("Minimized saved draft"))
    let scene = fixture.session()
    defer { scene.invalidate(); fixture.cleanUp() }
    let claim = try scene.restoreSaved(DraftPostViewModel(draftPost: row))

    #expect(scene.minimize(claim: claim))
    #expect(scene.isMinimized)
    #expect(scene.resume(claim: claim))
    #expect(!scene.isMinimized)
    #expect(scene.activeClaim == claim)
    #expect(scene.savedDraftID == row.id)
    #expect(scene.currentDraft?.postText == "Minimized saved draft")
  }

  @Test("A canceled persistence task cannot overwrite a replacement scene envelope")
  func canceledDebounceCannotOverwriteReplacementRecovery() async throws {
    let fixture = try Fixture()
    let sceneID = UUID()
    let oldScene = fixture.session(sceneID: sceneID, persistDelay: .milliseconds(800))
    let oldClaim = try oldScene.beginNew(draft: makeDraft("Old pending recovery"))
    #expect(oldScene.update(makeDraft("Old late autosave"), claim: oldClaim))
    await Task.yield()
    oldScene.invalidate()
    let key = SceneComposerEditingSession.persistenceKey(sceneID: sceneID, accountDID: fixture.accountDID)
    let oldData = try #require(fixture.defaults.data(forKey: key))
    let replacement = fixture.session(sceneID: sceneID, persistDelay: .milliseconds(5))
    defer {
      oldScene.invalidate()
      replacement.invalidate()
      fixture.cleanUp()
    }
    let claim = try replacement.beginNew(draft: makeDraft("Replacement recovery"))
    #expect(replacement.minimize(claim: claim))
    for _ in 0..<50 {
      if fixture.defaults.data(forKey: key) != oldData { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let replacementData = try #require(fixture.defaults.data(forKey: key))
    #expect(replacementData != oldData)

    try await Task.sleep(for: .seconds(1))

    #expect(fixture.defaults.data(forKey: key) == replacementData)
    #expect(replacement.activeClaim == claim)
    #expect(replacement.currentDraft?.postText == "Replacement recovery")
  }

  @Test("A canceled callback cannot mutate even its still-current claim")
  func canceledCallbackCannotWriteOrComplete() async throws {
    let fixture = try Fixture()
    let row = try fixture.save(makeDraft("Current owned row"))
    let scene = fixture.session()
    defer { scene.invalidate(); fixture.cleanUp() }
    let claim = try scene.restoreSaved(DraftPostViewModel(draftPost: row))
    let captured = try #require(scene.snapshot())
    let lateDraft = makeDraft("Canceled autosave")
    let callback = Task { @MainActor in
      try? await Task.sleep(for: .seconds(10))
      return [
        scene.update(lateDraft, claim: claim),
        scene.minimize(claim: claim),
        scene.discard(claim: claim),
        scene.completeSubmission(captured),
        scene.detachForTransfer(captured)
      ]
    }
    callback.cancel()
    let outcomes = await callback.value

    #expect(outcomes.allSatisfy { !$0 })
    #expect(scene.activeClaim == claim)
    #expect(scene.currentDraft?.postText == "Current owned row")
    #expect(try row.decodeDraft().postText == "Current owned row")
    #expect(try fixture.persistence.syncState(for: row).deletedAt == nil)
  }

  @Test("Invalidation preserves unsaved edits in a visible recovery row with a fresh claim")
  func invalidatedEditsBecomeVisibleRecoveryWithFreshClaim() throws {
    let fixture = try Fixture()
    let sceneID = UUID()
    let row = try fixture.save(makeDraft("Persisted saved row"))
    let scene = fixture.session(sceneID: sceneID)
    let claim = try scene.restoreSaved(DraftPostViewModel(draftPost: row))
    #expect(scene.update(makeDraft("Latest unsaved recovery"), claim: claim))
    scene.invalidate()
    let recovered = fixture.session(sceneID: sceneID)
    let unrelated = fixture.session()
    let otherAccount = fixture.session(sceneID: sceneID, accountDID: "did:plc:other-account")
    defer {
      scene.invalidate()
      recovered.invalidate()
      unrelated.invalidate()
      otherAccount.invalidate()
      fixture.cleanUp()
    }
    let restoredClaim = try #require(recovered.activeClaim)
    let recoveredID = try #require(recovered.savedDraftID)
    let fetchedRecovery = try fixture.persistence.fetchDraftModel(id: recoveredID)
    let recoveryRow = try #require(fetchedRecovery)

    #expect(restoredClaim != claim)
    #expect(restoredClaim.sceneID == sceneID)
    #expect(restoredClaim.accountDID == fixture.accountDID)
    #expect(recovered.currentDraft?.postText == "Latest unsaved recovery")
    #expect(recoveredID != row.id)
    #expect(recoveryRow.accountDID == fixture.accountDID)
    #expect(try recoveryRow.decodeDraft().postText == "Latest unsaved recovery")
    #expect(recoveryRow.remoteId == nil)
    #expect(try fixture.persistence.syncState(for: recoveryRow).recoveryReason != nil)
    #expect(fixture.manager.savedDrafts.contains { $0.id == recoveredID })
    #expect(unrelated.currentDraft == nil)
    #expect(otherAccount.currentDraft == nil)
    #expect(!recovered.update(makeDraft("Stale recovery callback"), claim: claim))
    #expect(try row.decodeDraft().postText == "Persisted saved row")
    #expect(try fixture.persistence.syncState(for: row).deletedAt == nil)
    #expect(try fixture.persistence.fetchDrafts(for: fixture.accountDID).count == 2)
  }

  @Test("An old scene recovery cannot overwrite a saved row changed by another scene")
  func changedSavedRowRestoresAsDetachedRecovery() throws {
    let fixture = try Fixture()
    let sceneID = UUID()
    let original = try fixture.save(makeDraft("Scene A original"))
    let sceneA = fixture.session(sceneID: sceneID)
    let originalClaim = try sceneA.restoreSaved(DraftPostViewModel(draftPost: original))
    sceneA.invalidate()
    let sceneB = fixture.session()
    let claimB = try sceneB.restoreSaved(DraftPostViewModel(draftPost: original))
    #expect(sceneB.update(makeDraft("Scene B saved changes"), claim: claimB))
    let snapshotB = try #require(sceneB.snapshot())
    #expect(try sceneB.stash(snapshotB) == original.id)
    let savedBytes = original.draftData
    let savedModifiedDate = original.modifiedDate
    let savedSyncMetadata = original.syncMetadata
    let returningA = fixture.session(sceneID: sceneID)
    defer {
      sceneA.invalidate()
      sceneB.invalidate()
      returningA.invalidate()
      fixture.cleanUp()
    }
    let recoveredClaim = try #require(returningA.activeClaim)

    #expect(recoveredClaim != originalClaim)
    #expect(returningA.currentDraft?.postText == "Scene A original")
    #expect(returningA.savedDraftID == nil)
    #expect(returningA.lastIssue != nil)
    #expect(returningA.update(makeDraft("Scene A recovered edit"), claim: recoveredClaim))
    let recoverySnapshot = try #require(returningA.snapshot())
    let recoveryID = try returningA.stash(recoverySnapshot)
    let fetchedRecovery = try fixture.persistence.fetchDraftModel(id: recoveryID)
    let recoveryRow = try #require(fetchedRecovery)

    #expect(recoveryID != original.id)
    #expect(try recoveryRow.decodeDraft().postText == "Scene A recovered edit")
    #expect(original.draftData == savedBytes)
    #expect(original.modifiedDate == savedModifiedDate)
    #expect(original.syncMetadata == savedSyncMetadata)
    #expect(try original.decodeDraft().postText == "Scene B saved changes")
    #expect(try fixture.persistence.syncState(for: original).deletedAt == nil)
  }

  @Test("Missing or tombstoned saved recovery stays editable and becomes a visible library copy", arguments: [false, true])
  func unavailableSavedRowRemainsRecoverable(removeRow: Bool) throws {
    let fixture = try Fixture()
    let sceneID = UUID()
    let body = makeDraft("Recovery from an unavailable row")
    let original = try fixture.save(body)
    let originalID = original.id
    let scene = fixture.session(sceneID: sceneID)
    _ = try scene.restoreSaved(DraftPostViewModel(draftPost: original))
    scene.invalidate()
    if removeRow {
      fixture.container.mainContext.delete(original)
      try fixture.container.mainContext.save()
    } else {
      try fixture.persistence.markDeleted(id: originalID, accountDID: fixture.accountDID)
    }
    let tombstoneMetadata = removeRow ? nil : original.syncMetadata
    let restored = fixture.session(sceneID: sceneID)
    defer {
      scene.invalidate()
      restored.invalidate()
      fixture.cleanUp()
    }

    #expect(restored.currentDraft == body)
    #expect(restored.activeClaim != nil)
    #expect(restored.savedDraftID == nil)
    #expect(restored.lastIssue != nil)
    _ = try restored.beginNew()
    let visibleRows = try fixture.persistence.fetchDrafts(for: fixture.accountDID)
    let recoveryRow = try #require(visibleRows.first)

    #expect(visibleRows.count == 1)
    #expect(recoveryRow.id != originalID)
    #expect(recoveryRow.accountDID == fixture.accountDID)
    #expect(try recoveryRow.decodeDraft() == body)
    #expect(recoveryRow.remoteId == nil)
    #expect(try fixture.persistence.syncState(for: recoveryRow).recoveryReason != nil)
    #expect(fixture.manager.savedDrafts.contains { $0.id == recoveryRow.id })
    #expect(restored.currentDraft?.postText.isEmpty == true)
    #expect(restored.savedDraftID == nil)
    let unavailableOriginal = try fixture.persistence.fetchDraftModel(id: originalID)
    if removeRow {
      #expect(unavailableOriginal == nil)
    } else {
      let tombstoned = try #require(unavailableOriginal)
      #expect(tombstoned.syncMetadata == tombstoneMetadata)
      #expect(try fixture.persistence.syncState(for: tombstoned).deletedAt != nil)
      #expect(try tombstoned.decodeDraft() == body)
    }
  }

  @Test("Transfer retains source row identity and media while target save gets a new owner")
  func transferKeepsSourceRowAndSharedMedia() throws {
    let fixture = try Fixture()
    let imageURL = try makeSharedImageFile()
    defer { try? FileManager.default.removeItem(at: imageURL) }
    let body = makeDraft("Transferred attachment", imageURL: imageURL)
    let sourceRow = try fixture.save(body)
    sourceRow.remoteId = "3mfdraftsourcerow"
    sourceRow.lastSyncedAt = Date(timeIntervalSince1970: 1_000)
    var sourceSyncState = DraftSyncState()
    sourceSyncState.baselineLocal = body
    try fixture.persistence.saveSyncState(sourceSyncState, for: sourceRow)
    let sourceBytes = sourceRow.draftData
    let sourceMetadata = sourceRow.syncMetadata
    let sourceCreatedDate = sourceRow.createdDate
    let sourceModifiedDate = sourceRow.modifiedDate
    try fixture.container.mainContext.save()
    let source = fixture.session()
    let targetDID = "did:plc:transfer-target"
    let target = fixture.session(accountDID: targetDID)
    defer {
      source.invalidate()
      target.invalidate()
      fixture.cleanUp()
    }
    let sourceClaim = try source.restoreSaved(DraftPostViewModel(draftPost: sourceRow))
    let transferredBody = makeDraft("Unstashed transferred edit", imageURL: imageURL)
    #expect(source.update(transferredBody, claim: sourceClaim))
    let transfer = try #require(source.snapshot())

    #expect(source.detachForTransfer(transfer))
    #expect(source.currentDraft == nil)
    #expect(!source.discard(claim: sourceClaim))
    #expect(!source.completeSubmission(transfer))
    let sourceRecoveries = try fixture.persistence.fetchDrafts(for: fixture.accountDID)
      .filter { $0.id != sourceRow.id }
    let sourceRecovery = try #require(sourceRecoveries.first)
    #expect(sourceRecoveries.count == 1)
    #expect(sourceRecovery.accountDID == fixture.accountDID)
    #expect(sourceRecovery.remoteId == nil)
    #expect(try sourceRecovery.decodeDraft() == transferredBody)
    #expect(try fixture.persistence.syncState(for: sourceRecovery).recoveryReason != nil)
    #expect(fixture.manager.savedDrafts.contains { $0.id == sourceRecovery.id })
    _ = try target.beginNew(draft: transfer.draft)
    #expect(target.savedDraftID == nil)
    let targetSnapshot = try #require(target.snapshot())
    let targetID = try target.stash(targetSnapshot)
    let fetchedTarget = try fixture.persistence.fetchDraftModel(id: targetID)
    let targetRow = try #require(fetchedTarget)

    #expect(targetID != sourceRow.id)
    #expect(targetRow.accountDID == targetDID)
    #expect(targetRow.remoteId == nil)
    #expect(try targetRow.decodeDraft() == transferredBody)
    let targetClaim = try target.restoreSaved(DraftPostViewModel(draftPost: targetRow))
    #expect(target.discard(claim: targetClaim))
    #expect(try fixture.persistence.syncState(for: targetRow).deletedAt != nil)
    #expect(sourceRow.accountDID == fixture.accountDID)
    #expect(sourceRow.remoteId == "3mfdraftsourcerow")
    #expect(sourceRow.lastSyncedAt == Date(timeIntervalSince1970: 1_000))
    #expect(sourceRow.draftData == sourceBytes)
    #expect(sourceRow.syncMetadata == sourceMetadata)
    #expect(sourceRow.createdDate == sourceCreatedDate)
    #expect(sourceRow.modifiedDate == sourceModifiedDate)
    #expect(try fixture.persistence.syncState(for: sourceRow).deletedAt == nil)
    #expect(try fixture.persistence.syncState(for: sourceRecovery).deletedAt == nil)
    #expect(try sourceRecovery.decodeDraft() == transferredBody)
    #expect(FileManager.default.fileExists(atPath: imageURL.path))
  }

  @Test("Unowned legacy bytes remain untouched during session initialization and invalidation")
  func legacyRecoveryIsNeverAutomaticallyClaimed() throws {
    let fixture = try Fixture()
    let legacyBytes = try JSONEncoder().encode(makeDraft("Unowned legacy recovery"))
    let key = SceneComposerEditingSession.legacyRecoveryKey
    fixture.defaults.set(legacyBytes, forKey: key)
    let sceneA = fixture.session()
    let sceneB = fixture.session(accountDID: "did:plc:other-account")
    defer { fixture.cleanUp() }

    #expect(sceneA.currentDraft == nil)
    #expect(sceneB.currentDraft == nil)
    #expect(fixture.defaults.data(forKey: key) == legacyBytes)
    sceneA.invalidate()
    sceneB.invalidate()
    #expect(fixture.defaults.data(forKey: key) == legacyBytes)
    #expect(try fixture.persistence.fetchDrafts(for: fixture.accountDID).isEmpty)
  }

  @Test("Explicit legacy recovery creates a durable owned row before consuming its bytes")
  func explicitLegacyRecoverySavesOwnedRow() throws {
    let fixture = try Fixture()
    let legacy = makeDraft("Explicit recovery")
    let key = SceneComposerEditingSession.legacyRecoveryKey
    fixture.defaults.set(try JSONEncoder().encode(legacy), forKey: key)
    let scene = fixture.session()
    defer { scene.invalidate(); fixture.cleanUp() }

    let claim = try scene.recoverLegacyDraft()
    let savedID = try #require(scene.savedDraftID)
    let fetchedSaved = try fixture.persistence.fetchDraftModel(id: savedID)
    let saved = try #require(fetchedSaved)

    #expect(scene.activeClaim == claim)
    #expect(claim.accountDID == fixture.accountDID)
    #expect(scene.currentDraft == legacy)
    #expect(saved.accountDID == fixture.accountDID)
    #expect(try saved.decodeDraft() == legacy)
    #expect(try fixture.persistence.syncState(for: saved).deletedAt == nil)
    #expect(fixture.defaults.data(forKey: key) == nil)
  }

  @Test("Malformed legacy recovery never consumes the original bytes")
  func malformedLegacyRecoveryRemainsRecoverable() throws {
    let fixture = try Fixture()
    let bytes = Data("{\"postText\":\"incomplete legacy body\"}".utf8)
    let key = SceneComposerEditingSession.legacyRecoveryKey
    fixture.defaults.set(bytes, forKey: key)
    let scene = fixture.session()
    defer { scene.invalidate(); fixture.cleanUp() }

    #expect(throws: (any Error).self) { try scene.recoverLegacyDraft() }

    #expect(fixture.defaults.data(forKey: key) == bytes)
    #expect(scene.currentDraft == nil)
    #expect(try fixture.persistence.fetchDrafts(for: fixture.accountDID).isEmpty)
  }

  @Test("A failed owned save cannot consume legacy recovery")
  func failedDurableRecoveryPreservesLegacyBytes() throws {
    let fixture = try Fixture()
    let bytes = try JSONEncoder().encode(makeDraft("Needs a durable owner"))
    let key = SceneComposerEditingSession.legacyRecoveryKey
    fixture.defaults.set(bytes, forKey: key)
    let unconfiguredManager = ComposerDraftManager()
    let scene = SceneComposerEditingSession(
      manager: unconfiguredManager,
      accountDID: fixture.accountDID,
      sceneID: UUID(),
      defaults: fixture.defaults
    )
    defer { scene.invalidate(); fixture.cleanUp() }

    #expect(throws: (any Error).self) { try scene.recoverLegacyDraft() }

    #expect(fixture.defaults.data(forKey: key) == bytes)
    #expect(scene.savedDraftID == nil)
    #expect(try fixture.persistence.fetchDrafts(for: fixture.accountDID).isEmpty)
  }

  @Test("Repeated empty replies release context and recovery without leaving a minimized draft")
  func emptyRepliesResetOnMinimize() throws {
    let fixture = try Fixture()
    let scene = fixture.session()
    defer { scene.invalidate(); fixture.cleanUp() }
    let key = SceneComposerEditingSession.persistenceKey(sceneID: scene.sceneID, accountDID: fixture.accountDID)
    for _ in 0..<3 {
      let claim = try scene.beginNew(draft: makeDraft(" \n ", parentURI: "at://did:plc:source/app.bsky.feed.post/reply"))
      #expect(scene.minimize(claim: claim))
      #expect(scene.currentDraft == nil)
      #expect(scene.activeClaim == nil)
      #expect(!scene.isMinimized)
      #expect(fixture.defaults.data(forKey: key) == nil)
      #expect(!scene.resume(claim: claim))
    }
    _ = try scene.beginNew()
    #expect(scene.currentDraft?.parentPostURI == nil)
  }

  @Test("Minimizing an empty saved reply releases its row and preserves unrelated drafts")
  func emptyReplyDoesNotDeleteSavedRows() throws {
    let fixture = try Fixture()
    let empty = makeDraft("", parentURI: "at://did:plc:source/app.bsky.feed.post/reply")
    let row = try fixture.save(empty)
    let other = try fixture.save(makeDraft("Unrelated saved work"))
    let scene = fixture.session()
    let second = fixture.session()
    defer { scene.invalidate(); second.invalidate(); fixture.cleanUp() }
    let claim = try scene.restoreSaved(DraftPostViewModel(draftPost: row))
    #expect(scene.minimize(claim: claim))
    #expect(try fixture.persistence.syncState(for: row).deletedAt == nil)
    #expect(try fixture.persistence.syncState(for: other).deletedAt == nil)
    #expect(try row.decodeDraft() == empty)
    #expect(try other.decodeDraft().postText == "Unrelated saved work")
    _ = try second.restoreSaved(DraftPostViewModel(draftPost: row))
    #expect(second.savedDraftID == row.id)
  }

  @Test("Minimization flushes newly typed reply content before deciding whether to reset")
  func lateReplyTypingSurvivesMinimize() throws {
    let fixture = try Fixture()
    let scene = fixture.session()
    defer { scene.invalidate(); fixture.cleanUp() }
    let empty = makeDraft("", parentURI: "at://did:plc:source/app.bsky.feed.post/reply")
    let claim = try scene.beginNew(draft: empty)
    let editor = UUID()
    let live = LiveDraftBox(draft: empty)
    #expect(scene.claimEditor(editor, claim: claim))
    #expect(scene.registerLiveDraftProvider(editorID: editor, claim: claim) { live.draft })
    live.draft = makeDraft("Typing after the last save", parentURI: empty.parentPostURI)
    #expect(scene.minimize(claim: claim))
    #expect(scene.isMinimized)
    #expect(scene.activeClaim == claim)
    #expect(scene.currentDraft == live.draft)
    #expect(scene.resume(claim: claim))
    #expect(scene.currentDraft?.parentPostURI == empty.parentPostURI)
  }

  @Test("An attachment-only reply retains its media reference when minimized")
  func attachmentReplySurvivesMinimize() throws {
    let fixture = try Fixture()
    let scene = fixture.session()
    defer { scene.invalidate(); fixture.cleanUp() }
    let draft = makeDraft("", imageURL: URL(fileURLWithPath: "/tmp/synthetic-reply-attachment.jpg"),
                          parentURI: "at://did:plc:source/app.bsky.feed.post/reply")
    let claim = try scene.beginNew(draft: draft)
    #expect(scene.minimize(claim: claim))
    #expect(scene.isMinimized)
    #expect(scene.currentDraft == draft)
    #expect(scene.resume(claim: claim))
    #expect(scene.currentDraft?.mediaItems == draft.mediaItems)
  }

  @Test("An empty active reply cannot discard content in another thread entry", arguments: ["text", "video", "quote"])
  func inactiveThreadReplySurvivesMinimize(kind: String) throws {
    let fixture = try Fixture()
    let scene = fixture.session()
    defer { scene.invalidate(); fixture.cleanUp() }
    var first = ThreadEntry()
    if kind == "text" {
      first.text = "Earlier thread post"
    } else if kind == "video" {
      var video = PostComposerViewModel.MediaItem()
      video.rawVideoURL = URL(fileURLWithPath: "/tmp/synthetic-thread-video.mp4")
      first.videoItem = video
    } else {
      first.draftQuotedPostURI = "at://did:plc:source/app.bsky.feed.post/quoted"
    }
    let entries = [first, ThreadEntry()].map {
      CodableThreadEntry(from: $0, parentPost: nil, quotedPost: nil)
    }
    let draft = makeDraft("", parentURI: "at://did:plc:source/app.bsky.feed.post/reply", entries: entries)
    let claim = try scene.beginNew(draft: draft)
    #expect(scene.minimize(claim: claim))
    #expect(scene.isMinimized)
    #expect(scene.currentDraft == draft)
    #expect(scene.resume(claim: claim))
    #expect(scene.currentDraft?.threadEntries == entries)
  }

  @Test("An audio-only reply survives minimize, recovery and saved-draft restoration")
  func pendingAudioReplySurvivesRecovery() throws {
    let fixture = try Fixture()
    let sceneID = UUID()
    let scene = fixture.session(sceneID: sceneID)
    var draft = makeDraft("", parentURI: "at://did:plc:source/app.bsky.feed.post/reply")
    draft.pendingAudioURLString = "file:///Documents/recording.m4a"
    let claim = try scene.beginNew(draft: draft)
    #expect(scene.minimize(claim: claim))
    #expect(scene.isMinimized)
    #expect(scene.currentDraft == draft)
    #expect(draft.hasMeaningfulContent)
    #expect(draft.hasRecoverableContent)
    #expect(!draft.isEmptyReply)

    let restored = fixture.session(sceneID: sceneID)
    defer { scene.invalidate(); restored.invalidate(); fixture.cleanUp() }
    #expect(restored.currentDraft?.pendingAudioURLString == draft.pendingAudioURLString)
    let snapshot = try #require(restored.snapshot())
    let id = try restored.stash(snapshot)
    let fetchedSaved = try fixture.persistence.fetchDraftModel(id: id)
    let saved = try #require(fetchedSaved)
    #expect(try saved.decodeDraft().pendingAudioURLString == draft.pendingAudioURLString)
    _ = try restored.restoreSaved(DraftPostViewModel(draftPost: saved))
    #expect(restored.currentDraft?.pendingAudioURLString == draft.pendingAudioURLString)
  }

  private func makeDraft(_ text: String, imageURL: URL? = nil, parentURI: String? = nil,
                         entries: [CodableThreadEntry] = []) -> PostComposerDraft {
    let images = imageURL.map {
      [CodableMediaItem(
        altText: "Shared draft attachment",
        aspectRatio: nil,
        isLoading: false,
        isAudioVisualizerVideo: false,
        rawVideoURLString: nil,
        rawImageURLString: $0.absoluteString
      )]
    } ?? []
    return PostComposerDraft(
      postText: text,
      mediaItems: images,
      videoItem: nil,
      selectedGif: nil,
      selectedLanguages: [],
      selectedLabels: [],
      outlineTags: [],
      threadEntries: entries,
      isThreadMode: !entries.isEmpty,
      currentThreadIndex: 0,
      parentPostURI: parentURI,
      quotedPostURI: nil
    )
  }

  private func makeSharedImageFile() throws -> URL {
    let container = try #require(FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: "group.blue.catbird.shared"
    ))
    let directory = container.appendingPathComponent("SharedDrafts", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("scene-session-test-\(UUID().uuidString).jpg")
    try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: url)
    return url
  }

  @MainActor
  private final class LiveDraftBox {
    var draft: PostComposerDraft

    init(draft: PostComposerDraft) { self.draft = draft }
  }

  @MainActor
  private struct Fixture {
    let accountDID = "did:plc:scene-session-owner"
    let container: ModelContainer
    let defaults: UserDefaults
    let suiteName: String
    let manager: ComposerDraftManager
    let persistence: DraftPersistence

    init() throws {
      suiteName = "blue.catbird.tests.scene-session.\(UUID().uuidString)"
      defaults = try #require(UserDefaults(suiteName: suiteName))
      let configuration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
      container = try ModelContainer(for: DraftPost.self, configurations: configuration)
      persistence = DraftPersistence(modelContext: container.mainContext)
      manager = ComposerDraftManager(
        accountDID: accountDID,
        modelContext: container.mainContext,
        defaults: defaults
      )
    }

    func save(_ draft: PostComposerDraft) throws -> DraftPost {
      let id = try persistence.saveDraft(draft, accountDID: accountDID)
      let model = try persistence.fetchDraftModel(id: id)
      return try #require(model)
    }

    func session(
      sceneID: UUID = UUID(),
      accountDID requestedDID: String? = nil,
      persistDelay: Duration = .seconds(60)
    ) -> SceneComposerEditingSession {
      let selectedDID = requestedDID ?? accountDID
      let selectedManager = selectedDID == accountDID ? manager : ComposerDraftManager(
        accountDID: selectedDID,
        modelContext: container.mainContext,
        defaults: defaults
      )
      return SceneComposerEditingSession(
        manager: selectedManager,
        accountDID: selectedDID,
        sceneID: sceneID,
        defaults: defaults,
        persistDelay: persistDelay
      )
    }

    func cleanUp() {
      defaults.removePersistentDomain(forName: suiteName)
    }
  }
}
