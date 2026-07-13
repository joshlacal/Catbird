@testable import Catbird
import XCTest

@MainActor
final class MLSAccountSwitchSuspensionContractTests: XCTestCase {
    func testScenePhaseUsesManagerOwnedSuspensionWithOwnerlessFallback() throws {
        let source = try appSource(relativePath: "Catbird/App/CatbirdApp.swift")
        let body = try XCTUnwrap(
            appFunctionBody(
                signature: "func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase)",
                in: source
            )
        )
        let managerBranch = try XCTUnwrap(
            appFunctionBody(
                signature: "if let manager = appStateManager.lifecycle.appState?.mlsConversationManager",
                in: body
            )
        )
        let managerBranchRange = try XCTUnwrap(body.range(of: managerBranch))
        let ownerlessBranch = try XCTUnwrap(
            appFunctionBody(
                signature: "else",
                in: String(body[managerBranchRange.upperBound...])
            )
        )

        XCTAssertTrue(
            managerBranch.contains("rustPathAvailable = manager.suspendMLSOperations()")
        )
        XCTAssertFalse(managerBranch.contains("MLSClient.markSuspensionInProgress("))
        XCTAssertTrue(
            ownerlessBranch.contains(
                "MLSClient.markSuspensionInProgress(reason: \"scenePhase → \\(String(describing: newPhase))\")"
            )
        )
        XCTAssertFalse(ownerlessBranch.contains("manager.suspendMLSOperations()"))
        XCTAssertEqual(
            body.components(
                separatedBy: "rustPathAvailable = manager.suspendMLSOperations()"
            ).count - 1,
            1
        )
        XCTAssertEqual(
            body.components(separatedBy: "MLSClient.markSuspensionInProgress(").count - 1,
            1
        )
    }

    func testOnlyAccountSwitchShutdownConsumesSuspensionAbandonmentAuthorization() throws {
        let source = try appSource(relativePath: "Catbird/Core/State/AppState.swift")
        let cleanupBody = try XCTUnwrap(
            appFunctionBody(signature: "func cleanup()", in: source)
        )
        let accountSwitchBody = try XCTUnwrap(
            appFunctionBody(signature: "private func reinitializeMLSAfterSwitch() async", in: source)
        )
        let normalizedAccountSwitchBody = normalizedWhitespace(accountSwitchBody)

        XCTAssertTrue(cleanupBody.contains("await manager.shutdown()"))
        XCTAssertFalse(cleanupBody.contains("authorizeSuspensionAbandonmentForAccountSwitch"))
        XCTAssertFalse(cleanupBody.contains("accountSwitchSuspensionAuthorization"))
        let suspendRange = try XCTUnwrap(
            normalizedAccountSwitchBody.range(
                of: "let rustAvailable = oldManager.suspendMLSOperations()"
            )
        )
        let authorizationRange = try XCTUnwrap(
            normalizedAccountSwitchBody.range(
                of: "guard let authorization = oldManager.authorizeSuspensionAbandonmentForAccountSwitch()"
            )
        )
        let shutdownRange = try XCTUnwrap(
            normalizedAccountSwitchBody.range(
                of: "oldManager.shutdown(accountSwitchSuspensionAuthorization: authorization)"
            )
        )
        XCTAssertLessThan(suspendRange.lowerBound, authorizationRange.lowerBound)
        XCTAssertLessThan(authorizationRange.lowerBound, shutdownRange.lowerBound)
        XCTAssertFalse(accountSwitchBody.contains("guard rustAvailable"))
        XCTAssertFalse(accountSwitchBody.contains("prepareRustRuntimeForSuspensionAfterDrain"))
        XCTAssertFalse(accountSwitchBody.contains("emergencyCloseAllContexts"))
        XCTAssertFalse(accountSwitchBody.contains("markRustRuntimeClosedForSuspend"))
        XCTAssertEqual(
            source.components(
                separatedBy: "authorizeSuspensionAbandonmentForAccountSwitch()"
            ).count - 1,
            1
        )
        XCTAssertEqual(
            source.components(
                separatedBy: "accountSwitchSuspensionAuthorization: authorization"
            ).count - 1,
            1
        )
    }

    private func appSource(relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func normalizedWhitespace(_ source: String) -> String {
        source.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }

    private func appFunctionBody(signature: String, in source: String) -> String? {
        guard let signatureRange = source.range(of: signature),
              let openingBrace = source[signatureRange.upperBound...].firstIndex(of: "{")
        else {
            return nil
        }

        var depth = 0
        var cursor = openingBrace
        while cursor < source.endIndex {
            switch source[cursor] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[openingBrace ... cursor])
                }
            default:
                break
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }
}
