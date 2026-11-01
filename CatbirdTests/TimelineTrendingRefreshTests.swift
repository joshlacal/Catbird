import Foundation
import Petrel
import Testing
import UIKit
@testable import Catbird

/// The timeline interstitial's use of the per-account trend lists shared with Search.
@Suite("Timeline trending refresh", .serialized)
@MainActor
struct TimelineTrendingRefreshTests {
  private let suspendedAccountDID = "did:plc:timelinetrendingsuspend"

  @Test("An account admits trend requests until it is suspended or retired")
  func accountSuspensionClosesTrendRequests() async throws {
    let appState = try await makeAppState(did: suspendedAccountDID)
    #expect(appState.trendingTopicMediaStore.lists.admitsRequests())

    appState.cleanup()

    #expect(!appState.trendingTopicMediaStore.lists.admitsRequests(),
      "A retired or switching account's client may already carry another account's credentials")
  }

  // MARK: Helpers

  private func makeAppState(did: String) async throws -> AppState {
    let client = await ATProtoClient(baseURL: try #require(URL(string: "https://timeline-trending-refresh.invalid")))
    return AppState(userDID: did, client: client, regulatoryChecker: TrendingRefreshAgeChecker())
  }
}

private struct TrendingRefreshAgeChecker: AgeRegulatoryChecking {
  func preflight() async -> PlatformAgeSignal {
    .init(requirement: .none, ageBand: nil, significantChangeConsentRequired: false)
  }

  @MainActor
  func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
}
