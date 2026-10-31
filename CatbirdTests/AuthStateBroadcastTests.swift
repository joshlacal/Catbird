//
//  AuthStateBroadcastTests.swift
//  CatbirdTests
//
//  AppStateManager, ComposerDraftManager, FeedsStartPageViewModel and
//  StarterPackOnboardingManager all iterate AuthenticationManager.stateChanges
//  at once. Each must see every change, and one of them stopping must not end
//  the others' streams.
//

import Foundation
import Testing
@testable import Catbird

@Suite("Auth state broadcast")
struct AuthStateBroadcastTests {
  @Test("Every subscriber receives every state")
  func everySubscriberReceivesEveryState() async {
    let broadcast = AuthStateBroadcast()
    let first = broadcast.subscribe()
    let second = broadcast.subscribe()

    broadcast.yield(.unauthenticated)
    broadcast.yield(.authenticated(userDID: "did:plc:alice"))

    var firstIterator = first.makeAsyncIterator()
    var secondIterator = second.makeAsyncIterator()
    #expect(await firstIterator.next() == .unauthenticated)
    #expect(await firstIterator.next() == .authenticated(userDID: "did:plc:alice"))
    #expect(await secondIterator.next() == .unauthenticated)
    #expect(await secondIterator.next() == .authenticated(userDID: "did:plc:alice"))
  }

  @Test("A subscriber only sees states yielded after it subscribed")
  func subscriberSeesLaterStatesOnly() async {
    let broadcast = AuthStateBroadcast()
    broadcast.yield(.unauthenticated)
    let late = broadcast.subscribe()
    broadcast.yield(.authenticated(userDID: "did:plc:bob"))

    var iterator = late.makeAsyncIterator()
    #expect(await iterator.next() == .authenticated(userDID: "did:plc:bob"))
  }

  @Test("A subscription can start from the current state, then see later changes")
  func subscriptionStartingWithCurrentState() async {
    let broadcast = AuthStateBroadcast()
    broadcast.yield(.authenticated(userDID: "did:plc:alice"))
    let changes = broadcast.subscribe(startingWith: .authenticated(userDID: "did:plc:alice"))
    broadcast.yield(.unauthenticated)

    var iterator = changes.makeAsyncIterator()
    #expect(await iterator.next() == .authenticated(userDID: "did:plc:alice"))
    #expect(await iterator.next() == .unauthenticated)
  }

  @Test("Cancelling one subscriber leaves the others subscribed")
  func cancellingOneSubscriberLeavesOthers() async {
    let broadcast = AuthStateBroadcast()
    let survivor = broadcast.subscribe()
    let cancelled = broadcast.subscribe()

    let task = Task {
      for await _ in cancelled {}
    }
    task.cancel()
    await task.value

    for _ in 0..<100 where broadcast.subscriberCount > 1 {
      await Task.yield()
    }
    #expect(broadcast.subscriberCount == 1)

    broadcast.yield(.unauthenticated)
    var iterator = survivor.makeAsyncIterator()
    #expect(await iterator.next() == .unauthenticated)
  }

  @Test("finishAll ends every subscriber's iteration")
  func finishAllEndsEverySubscriber() async {
    let broadcast = AuthStateBroadcast()
    let first = broadcast.subscribe()
    let second = broadcast.subscribe()
    let firstTask = Task { for await _ in first {} }
    let secondTask = Task { for await _ in second {} }

    broadcast.finishAll()
    #expect(broadcast.subscriberCount == 0)

    // Both loops return; without finishAll they would wait forever.
    await firstTask.value
    await secondTask.value
  }
}

@Suite("Authentication manager state streams")
struct AuthenticationManagerStateStreamTests {
  private func makeManager() -> AuthenticationManager {
    AuthenticationManager(
      userDefaults: UserDefaults(suiteName: "AuthStateStreams-\(UUID())")!,
      configureBiometrics: false
    )
  }

  @Test("currentAndFutureStates starts from the state already reached; stateChanges doesn't")
  @MainActor
  func currentAndFutureStatesReplaysCurrentState() async {
    let manager = makeManager()
    manager.setAuthenticatedForTesting(did: "did:plc:alice")

    let fromCurrent = manager.currentAndFutureStates
    let laterOnly = manager.stateChanges
    manager.updateState(.unauthenticated)

    var fromCurrentIterator = fromCurrent.makeAsyncIterator()
    #expect(await fromCurrentIterator.next() == .authenticated(userDID: "did:plc:alice"))
    #expect(await fromCurrentIterator.next() == .unauthenticated)

    var laterOnlyIterator = laterOnly.makeAsyncIterator()
    #expect(await laterOnlyIterator.next() == .unauthenticated)
  }

  @Test("Releasing the manager ends its subscribers' streams")
  @MainActor
  func releasingManagerFinishesStreams() async {
    var manager: AuthenticationManager? = makeManager()
    let changes = manager!.stateChanges
    manager = nil

    var iterator = changes.makeAsyncIterator()
    #expect(await iterator.next() == nil)
  }
}
