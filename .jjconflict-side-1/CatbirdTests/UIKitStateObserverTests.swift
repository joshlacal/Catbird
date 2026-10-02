//
//  UIKitStateObserverTests.swift
//  CatbirdTests
//
//  Tests for UIKitStateObserver observation lifecycle and single callback delivery.
//

import Foundation
import Testing
import Petrel
@testable import Catbird

@Suite("UIKitStateObserver lifecycle and callback delivery", .serialized)
@MainActor
struct UIKitStateObserverTests {
    private func makeAppState() async -> AppState {
        let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
        return AppState(userDID: "did:plc:testuser1234567890ab", client: client)
    }

    private func drainCallbacks() async {
        for _ in 0..<5 {
            await Task.yield()
        }
    }

    @Test("singleRelevantMutationDeliversOneCallback delivers exactly one callback per mutation")
    func singleRelevantMutationDeliversOneCallback() async {
        let appState = await makeAppState()
        var callbackCount = 0

        let observer = UIKitStateObserver(observing: appState) { _ in
            callbackCount += 1
        }
        #expect(callbackCount == 0)

        // Mutate a tracked property: isTransitioningAccounts
        appState.isTransitioningAccounts = true

        // Allow main actor tasks to drain
        await drainCallbacks()

        #expect(callbackCount == 1)

        // Mutate back to false
        appState.isTransitioningAccounts = false

        await drainCallbacks()

        #expect(callbackCount == 2)
        withExtendedLifetime(observer) {}
    }

    @Test("account transition true to false produces exactly one completion action")
    func accountTransitionProducesSingleCompletion() async {
        let appState = await makeAppState()
        var previous = appState.isTransitioningAccounts
        var completionCount = 0

        let observer = UIKitStateObserver(observing: appState) { _ in
            let now = appState.isTransitioningAccounts
            if previous && !now {
                completionCount += 1
            }
            previous = now
        }
        // Transition starts: false -> true
        appState.isTransitioningAccounts = true
        await drainCallbacks()
        #expect(completionCount == 0)

        // Transition completes: true -> false
        appState.isTransitioningAccounts = false
        await drainCallbacks()
        #expect(completionCount == 1)
        withExtendedLifetime(observer) {}
    }

    @Test("stopObserving prevents future callbacks and does not rearm")
    func stopObservingPreventsCallbacks() async {
        let appState = await makeAppState()
        var callbackCount = 0

        let observer = UIKitStateObserver(observing: appState) { _ in
            callbackCount += 1
        }

        // Initial mutation delivers callback
        appState.isTransitioningAccounts = true
        await drainCallbacks()
        #expect(callbackCount == 1)

        // Stop observing
        observer.stopObserving()

        // Mutation while stopped delivers no callbacks
        appState.isTransitioningAccounts = false
        await drainCallbacks()
        #expect(callbackCount == 1)

        // Subsequent mutation still delivers no callbacks and does not rearm
        appState.tabTappedAgain = 1
        await drainCallbacks()
        #expect(callbackCount == 1)
        withExtendedLifetime(observer) {}
    }

    @Test("redundant startObserving calls do not create duplicate callback delivery")
    func redundantStartObservingIsIdempotent() async {
        let appState = await makeAppState()
        var callbackCount = 0

        let observer = UIKitStateObserver(observing: appState) { _ in
            callbackCount += 1
        }

        // Call startObserving multiple times while already observing
        observer.startObserving()
        observer.startObserving()

        // Single mutation should still only deliver exactly one callback
        appState.isTransitioningAccounts = true
        await drainCallbacks()
        #expect(callbackCount == 1)
        withExtendedLifetime(observer) {}
    }

    @Test("restart observing resumes callback delivery after being stopped")
    func restartObservingWorks() async {
        let appState = await makeAppState()
        var callbackCount = 0

        let observer = UIKitStateObserver(observing: appState) { _ in
            callbackCount += 1
        }

        // Stop observing immediately
        observer.stopObserving()

        appState.isTransitioningAccounts = true
        await drainCallbacks()
        #expect(callbackCount == 0)

        // Restart observing
        observer.startObserving()

        // Mutation after restart delivers callback
        appState.isTransitioningAccounts = false
        await drainCallbacks()
        #expect(callbackCount == 1)
        withExtendedLifetime(observer) {}
    }

    @Test("observer deallocates when released even if observed object is held alive")
    func observerDeallocatesWhileObservedObjectIsAlive() async {
        let appState = await makeAppState()
        var callbackCount = 0

        weak var weakObserver: UIKitStateObserver<AppState>?

        do {
            let observer = UIKitStateObserver(observing: appState) { _ in
                callbackCount += 1
            }
            weakObserver = observer
            #expect(weakObserver != nil)
        }

        // Before another mutation, observer must deallocate because appState
        // only holds a weak reference via onChange
        #expect(weakObserver == nil)

        // Mutating appState after observer deallocated must not trigger callbacks
        appState.isTransitioningAccounts = true
        await drainCallbacks()
        #expect(callbackCount == 0)
    }
}
