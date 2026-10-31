//
//  ChatTranscriptObservationTests.swift
//  CatbirdTests
//
//  The transcript controller's observation loop must not keep the controller
//  alive while it waits for a change, and cancelling the loop's task must end
//  the wait even when the transcript never changes again (perf teardown P143).
//

#if os(iOS)
import Foundation
import Petrel
import SwiftUI
import Testing
import UIKit
@testable import Catbird

@Suite("Chat transcript observation")
@MainActor
struct ChatTranscriptObservationTests {
  private typealias Controller = ChatCollectionViewController<BlueskyConversationDataSource>

  @Test("A controller whose observation loop is waiting is released when its owner lets go")
  func parkedLoopDoesNotRetainController() async throws {
    let client = await ATProtoClient(baseURL: URL(string: "https://observation.invalid")!)
    let appState = AppState(userDID: "did:plc:observationfixture", client: client)
    let source = makeSource(client: client)

    weak var weakController: Controller?
    var controller: Controller? = autoreleasepool {
      let controller = Controller(
        dataSource: source, navigationPath: .constant(NavigationPath()), appState: appState,
        sceneContext: SceneNavigationContext(appState: appState, sceneID: UUID()))
      controller.loadViewIfNeeded()  // viewDidLoad starts the observation task
      return controller
    }
    weakController = controller

    // Let the initial snapshot run so the task is parked in its wait. Dropping
    // the controller before that would end the task early on any version.
    try await Task.sleep(for: .milliseconds(300))
    #expect(weakController != nil)

    autoreleasepool { controller = nil }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while weakController != nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(weakController == nil, "the parked observation task kept the controller alive")
    withExtendedLifetime(source) {}
  }

  @Test("Cancelling a task parked in the transcript wait ends the wait with no change")
  func cancelWhileParkedEndsWait() async throws {
    let client = await ATProtoClient(baseURL: URL(string: "https://observation.invalid")!)
    let source = makeSource(client: client)
    let progress = WaitProgress()

    let task = Task { @MainActor in
      progress.started = true
      await Controller.waitForTranscriptChange(in: source)
      progress.finished = true
    }
    let parked = ContinuousClock.now.advanced(by: .seconds(1))
    while !progress.started, ContinuousClock.now < parked { await Task.yield() }
    try await Task.sleep(for: .milliseconds(50))
    #expect(progress.started && !progress.finished, "nothing changed, so the wait must still be parked")

    task.cancel()
    try await waitUntilFinished(progress)
    #expect(progress.finished, "a cancelled wait must resume without a transcript change")
  }

  @Test("A task cancelled before it reaches the transcript wait returns at once")
  func cancelBeforeWaitReturns() async throws {
    let client = await ATProtoClient(baseURL: URL(string: "https://observation.invalid")!)
    let source = makeSource(client: client)
    let progress = WaitProgress()

    // The task cannot start until this test suspends, so it begins cancelled.
    let task = Task { @MainActor in
      await Controller.waitForTranscriptChange(in: source)
      progress.finished = true
    }
    task.cancel()
    try await waitUntilFinished(progress)
    #expect(progress.finished)
  }

  // MARK: - Helpers

  private func makeSource(client: ATProtoClient) -> BlueskyConversationDataSource {
    // No message is ever loaded: the loader is never called by these tests.
    let manager = ChatManager(client: client, messagePageLoader: { _, _ in
      Issue.record("Unexpected message fetch")
      throw URLError(.badServerResponse)
    })
    return BlueskyConversationDataSource(
      chatManager: manager, convoID: "observation-conversation", currentUserDID: "did:plc:observationfixture")
  }

  private func waitUntilFinished(_ progress: WaitProgress) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while !progress.finished, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

@MainActor
private final class WaitProgress {
  var started = false
  var finished = false
}
#endif
