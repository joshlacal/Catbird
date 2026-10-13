import Foundation
import Petrel
import Testing

@testable import Catbird

/// Header loads run inside cancellable work: a screen's `.task`, or a refresh superseded by a
/// newer one. A cancelled load must not leave `isLoading` set, or empty tabs keep a spinner.
@Suite("Profile header load", .serialized)
@MainActor
struct ProfileHeaderLoadTests {
  @Test("A cancelled header load clears the loading flag")
  func cancelledLoadClearsLoading() async throws {
    let viewModel = try await Self.makeViewModel()

    let load = Task { await viewModel.loadProfile() }
    load.cancel()
    await load.value

    #expect(!viewModel.isLoading)
    #expect(viewModel.profile == nil)
  }

  @Test("A header load that fails without cancellation clears the loading flag (control)")
  func failedLoadClearsLoading() async throws {
    let viewModel = try await Self.makeViewModel()

    await viewModel.loadProfile()

    #expect(!viewModel.isLoading)
    #expect(viewModel.error != nil)
  }

  /// Nothing listens on port 9, so every request fails at once.
  private static func makeViewModel() async throws -> ProfileViewModel {
    let client = await ATProtoClient(baseURL: try #require(URL(string: "http://127.0.0.1:9")))
    return ProfileViewModel(client: client, userDID: "did:plc:other", currentUserDID: "did:plc:me")
  }
}
