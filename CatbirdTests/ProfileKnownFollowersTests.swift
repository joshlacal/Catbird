import Foundation
import Petrel
import Testing

@testable import Catbird

/// A profile screen's `.task` is cancelled when the user pushes a post or switches tabs while
/// the "Followed by" row is still loading. The loading flag must clear anyway: while it is set,
/// every later load of that screen is refused, pull to refresh included.
@Suite("Profile known followers", .serialized)
@MainActor
struct ProfileKnownFollowersTests {
  @Test("A cancelled load clears the loading flag")
  func flagClearsAfterCancellation() async throws {
    let viewModel = try await Self.makeViewModel()

    let load = Task { await viewModel.loadKnownFollowers() }
    load.cancel()
    await load.value

    #expect(!viewModel.isLoadingKnownFollowers)
  }

  @Test("A load that fails without cancellation clears the loading flag (control)")
  func flagClearsAfterFailure() async throws {
    let viewModel = try await Self.makeViewModel()

    await viewModel.loadKnownFollowers()

    #expect(!viewModel.isLoadingKnownFollowers)
    #expect(viewModel.knownFollowers.isEmpty)
  }

  /// Nothing listens on port 9, so every request fails at once.
  private static func makeViewModel() async throws -> ProfileViewModel {
    let client = await ATProtoClient(baseURL: try #require(URL(string: "http://127.0.0.1:9")))
    return ProfileViewModel(client: client, userDID: "did:plc:other", currentUserDID: "did:plc:me")
  }
}
