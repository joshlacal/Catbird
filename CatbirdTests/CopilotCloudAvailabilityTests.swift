import Foundation
import Testing
@testable import Catbird

struct CopilotCloudAvailabilityTests {
    @Test func unprovisionedBuildCannotEnableCloudThroughPreferences() {
        #expect(CopilotCloudAvailability.unavailableReason != nil)
        #expect(!CopilotCloudAvailability.isProvisionedBuild)
    }

    #if canImport(FoundationModels)
    @Test(.enabled(if: {
        if #available(iOS 26.0, macOS 26.0, *) { return true }
        return false
    }()))
    func cloudRequestFailsBeforeClientOrFrameworkAccess() async {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let agent = BlueskyIntelligenceAgent()
        let stream = await agent.streamTurn(
            conversationID: UUID(), accountDID: "did:plc:test", prompt: "Hello",
            context: .search(query: "test"), history: [], route: .privateCloudCompute
        )
        do {
            for try await _ in stream {
                Issue.record("An unsupported cloud request emitted an event")
            }
            Issue.record("An unsupported cloud request did not return its explanation")
        } catch let error as CopilotCloudUnavailableError {
            #expect(error.reason == CopilotCloudAvailability.unavailableReason)
        } catch {
            Issue.record("Cloud request reached another dependency: \(error)")
        }
    }
    #endif
}
