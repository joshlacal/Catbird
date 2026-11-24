import Foundation
import Testing
@testable import Catbird

struct CopilotCloudAvailabilityTests {
    @Test func provisionedBuildDefersToRolloutFlagAndOperatingSystem() {
        #expect(CopilotCloudAvailability.isProvisionedBuild)
        let reason = CopilotCloudAvailability.unavailableReason
        guard IntelligenceFeatureFlags.privateCloudComputeEnabled else {
            #expect(reason != nil)
            return
        }
        if #available(iOS 27.0, macOS 27.0, *) {
            #expect(reason == nil)
        } else {
            #expect(reason == CopilotCloudAvailability.operatingSystemRequirement)
        }
    }

    #if canImport(FoundationModels)
    @Test(.enabled(if: {
        if #available(iOS 26.0, macOS 26.0, *) { return true }
        return false
    }()))
    func cloudRequestWithoutAClientFailsBeforeFrameworkAccess() async {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let agent = BlueskyIntelligenceAgent()
        let stream = await agent.streamTurn(
            conversationID: UUID(), accountDID: "did:plc:test", prompt: "Hello",
            context: .search(query: "test"), history: [], route: .privateCloudCompute, currentClient: nil
        )
        let gateReason = CopilotCloudAvailability.unavailableReason
        do {
            for try await _ in stream {
                Issue.record("A cloud request without a client emitted an event")
            }
            Issue.record("A cloud request without a client did not report why it stopped")
        } catch let error as CopilotCloudUnavailableError {
            // A closed gate explains itself before any client or model is touched.
            #expect(gateReason != nil)
            #expect(error.reason == gateReason)
        } catch BlueskyAgentError.missingClient {
            // An open gate still needs the account's client before contacting Apple.
            #expect(gateReason == nil)
        } catch {
            Issue.record("Cloud request reached another dependency: \(error)")
        }
    }
    #endif
}
