import Testing
@testable import Catbird

@Suite("Scene-root reauthentication feedback")
@MainActor
struct AccountReauthenticationFeedbackTests {
  @Test("A wrong-account callback uses the scene-root alert instead of the replaced account's toast")
  func wrongAccountOffersRetry() {
    let result = AccountReauthentication.Result.signedInToDifferentAccount
    #expect(result.feedback == .alert(
      title: "Couldn’t Sign In",
      message: "Sign-in finished for a different account. Try again."
    ))
  }

  @Test("A sign-in failure preserves its existing explanation")
  func failureExplanationIsPreserved() {
    let message = "Signing in took too long. Try again."
    #expect(AccountReauthentication.Result.failed(message).feedback == .toast(message: message))
  }

  @Test("Signing in to the requested account does not show a failure")
  func successfulTargetHasNoFailureFeedback() {
    let result = AccountReauthentication.Result.signedIn(did: "did:plc:bbbbbbbbbbbbbbbbbbbbbbbb")
    #expect(result.feedback == .none)
  }

  @Test("Cancelling after a wrong-account attempt does not repeat its error")
  func cancellationDoesNotCarryPreviousFailure() {
    let results: [AccountReauthentication.Result] = [.signedInToDifferentAccount, .cancelled]
    let feedback = results.map(\.feedback)
    #expect(feedback == [
      .alert(
        title: "Couldn’t Sign In",
        message: "Sign-in finished for a different account. Try again."
      ),
      .none
    ])
  }
}
