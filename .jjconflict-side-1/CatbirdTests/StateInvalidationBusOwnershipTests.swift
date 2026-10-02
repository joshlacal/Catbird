//
//  StateInvalidationBusOwnershipTests.swift
//  CatbirdTests
//

import Foundation
import Testing
import Petrel
@testable import Catbird
@Suite("State Invalidation Bus Ownership")
struct StateInvalidationBusOwnershipTests {
  private final class TestSubscriber: StateInvalidationSubscriber {
    var receivedEvents: [StateInvalidationEvent] = []
    let interestedFilter: ((StateInvalidationEvent) -> Bool)?

    init(interestedFilter: ((StateInvalidationEvent) -> Bool)? = nil) {
      self.interestedFilter = interestedFilter
    }

    func handleStateInvalidation(_ event: StateInvalidationEvent) async {
      receivedEvents.append(event)
    }

    func isInterestedIn(_ event: StateInvalidationEvent) -> Bool {
      interestedFilter?(event) ?? true
    }
  }

  @Test("Bus holds subscribers weakly and dead subscribers are compacted")
  @MainActor
  func weakSubscriberCompaction() async {
    let bus = StateInvalidationBus()
    var subscriber1: TestSubscriber? = TestSubscriber()
    let subscriber2 = TestSubscriber()

    bus.subscribe(subscriber1!)
    bus.subscribe(subscriber2)

    #expect(bus.subscriberCount == 2)

    // Deallocate subscriber1
    subscriber1 = nil

    // subscriberCount should compact and return 1
    #expect(bus.subscriberCount == 1)

    // Notifying should also compact and only notify live subscriber
    bus.notifyAccountSwitched()

    // Wait a brief moment for Task on MainActor to complete
    try? await Task.sleep(for: .milliseconds(50))

    #expect(subscriber2.receivedEvents.count == 1)
  }

  @Test("Explicit unsubscribe removes subscriber eagerly")
  @MainActor
  func explicitUnsubscribe() async {
    let bus = StateInvalidationBus()
    let subscriber = TestSubscriber()

    bus.subscribe(subscriber)
    #expect(bus.subscriberCount == 1)

    bus.unsubscribe(subscriber)
    #expect(bus.subscriberCount == 0)

    bus.notifyAccountSwitched()
    try? await Task.sleep(for: .milliseconds(50))

    #expect(subscriber.receivedEvents.isEmpty)
  }

  @Test("Duplicate subscription is ignored")
  @MainActor
  func duplicateSubscriptionIgnored() {
    let bus = StateInvalidationBus()
    let subscriber = TestSubscriber()

    bus.subscribe(subscriber)
    bus.subscribe(subscriber)

    #expect(bus.subscriberCount == 1)
  }

  @Test("Event filtering via isInterestedIn only dispatches to interested subscribers")
  @MainActor
  func eventFiltering() async {
    let bus = StateInvalidationBus()
    let replySubscriber = TestSubscriber { event in
      if case .replyCreated = event { return true }
      return false
    }
    let threadSubscriber = TestSubscriber { event in
      if case .threadUpdated = event { return true }
      return false
    }

    bus.subscribe(replySubscriber)
    bus.subscribe(threadSubscriber)

    bus.notifyThreadUpdated("at://did:plc:test/app.bsky.feed.post/123")
    try? await Task.sleep(for: .milliseconds(50))

    #expect(replySubscriber.receivedEvents.isEmpty)
    #expect(threadSubscriber.receivedEvents.count == 1)
  }

  @Test("ThreadManager deallocates and does not leak on replacement")
  @MainActor
  func threadManagerDeallocation() async {
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let appState = AppState(userDID: "did:plc:testuser", client: client)
    let bus = appState.stateInvalidationBus
    let initialCount = bus.subscriberCount

    var manager: ThreadManager? = ThreadManager(appState: appState)
    weak var managerReference: ThreadManager?
    managerReference = manager
    #expect(managerReference != nil)
    #expect(bus.subscriberCount == initialCount + 1)

    // Dropping the owner must deallocate the manager and remove its weak subscription.
    manager = nil
    #expect(managerReference == nil)
    #expect(bus.subscriberCount == initialCount)
  }

}
