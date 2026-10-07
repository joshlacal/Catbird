import Testing
@testable import Catbird

@Suite("Login reauthentication completion")
struct LoginReauthenticationCompletionTests {
    private let sourceDID = "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"
    private let targetDID = "did:plc:bbbbbbbbbbbbbbbbbbbbbbbb"

    @Test("Restoring the working account does not complete the expired account's sign-in")
    func sourceRecoveryDoesNotCompleteTarget() {
        #expect(!LoginAuthenticationCompletionPolicy.accepts(
            .authenticated(userDID: sourceDID), reauthenticationDID: targetDID
        ))
    }

    @Test("Only the intended account completes reauthentication in a recovery sequence")
    func recoveryThenTargetCompletion() {
        let events: [AuthState] = [
            .authenticated(userDID: sourceDID),
            .authenticating(progress: .exchangingTokens),
            .authenticated(userDID: targetDID),
            .authenticated(userDID: sourceDID)
        ]
        let completions = events.filter {
            LoginAuthenticationCompletionPolicy.accepts($0, reauthenticationDID: targetDID)
        }
        #expect(completions == [.authenticated(userDID: targetDID)])
    }

    @Test("An ordinary login or signup can complete without a preselected account")
    func freshLoginDoesNotRequireKnownDID() {
        #expect(LoginAuthenticationCompletionPolicy.accepts(
            .authenticated(userDID: sourceDID), reauthenticationDID: nil
        ))
        #expect(LoginAuthenticationCompletionPolicy.accepts(
            .authenticated(userDID: targetDID), reauthenticationDID: nil
        ))
    }

    @Test("Failure, cancellation state and progress never count as authenticated success")
    func incompleteStatesNeverComplete() {
        let events: [AuthState] = [
            .initializing, .unauthenticated,
            .authenticating(progress: .waitingForCallback),
            .error(message: "Synthetic sign-in failure")
        ]
        for state in events {
            #expect(!LoginAuthenticationCompletionPolicy.accepts(state, reauthenticationDID: targetDID))
            #expect(!LoginAuthenticationCompletionPolicy.accepts(state, reauthenticationDID: nil))
        }
    }
}
