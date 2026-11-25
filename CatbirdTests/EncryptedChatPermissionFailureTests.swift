import Foundation
import Testing
@testable import Catbird

@Suite("Encrypted chat permission failure wording")
struct EncryptedChatPermissionFailureTests {

  @Test("A gateway without the scopes is named as Catbird's problem, with the server's words kept")
  func gatewayNotConfigured() {
    let failure = EncryptedChatPermissionFailure(
      error: GatewayPermissionError.upgradeFailed("Requested scope exceeds configured maximum scopes")
    )
    #expect(failure.message.contains("Catbird’s side"))
    #expect(failure.detail == "Requested scope exceeds configured maximum scopes")

    let allowlist = EncryptedChatPermissionFailure(
      error: GatewayPermissionError.upgradeFailed("Requested additional scopes contain non-allowlisted entries")
    )
    #expect(allowlist.message == failure.message)
  }

  @Test("A refused authorization request says the account's server turned it down")
  func accountServerRefused() {
    let failure = EncryptedChatPermissionFailure(
      error: GatewayPermissionError.upgradeFailed("Authorization initiation failed")
    )
    #expect(failure.message.contains("turned down"))
    #expect(failure.detail == "Authorization initiation failed")
  }

  @Test("Expired, busy and offline cases each get their own sentence")
  func transientCases() {
    let expired = EncryptedChatPermissionFailure(
      error: GatewayPermissionError.upgradeFailed("Gateway session has expired. Please log in again.")
    )
    #expect(expired.message.contains("Sign in again"))

    let busy = EncryptedChatPermissionFailure(
      error: GatewayPermissionError.upgradeFailed("Gateway upgrade is temporarily unavailable. Please try again later.")
    )
    #expect(busy.message.contains("busy"))

    let offline = EncryptedChatPermissionFailure(
      error: GatewayPermissionError.upgradeFailed("Network error: The Internet connection appears to be offline.")
    )
    #expect(offline.message.contains("Check your connection"))
  }

  @Test("An unknown answer still shows the server's words under Details")
  func unknownAnswer() {
    let failure = EncryptedChatPermissionFailure(
      error: GatewayPermissionError.upgradeFailed("Something unexpected")
    )
    #expect(failure.detail == "Something unexpected")
    #expect(!failure.message.isEmpty)
  }

  @Test("Errors that already read plainly keep their own sentence and no details")
  func plainErrorsPassThrough() {
    let denied = EncryptedChatPermissionFailure(error: GatewayPermissionError.permissionDenied)
    #expect(denied.message == GatewayPermissionError.permissionDenied.errorDescription)
    #expect(denied.detail == nil)
  }

  @Test("A partial grant lists what is still missing under Details")
  func partialGrant() {
    let failure = EncryptedChatPermissionFailure.partialGrant(missing: ["blob:*/*", "repo:a.b.c"])
    #expect(failure.detail == "Still missing:\nblob:*/*\nrepo:a.b.c")
    #expect(!failure.message.contains("blob:"))
    #expect(EncryptedChatPermissionFailure.partialGrant(missing: []).detail == nil)
  }

  @Test("User-facing sentences never show scope strings or a generic try-again")
  func messagesStayPlain() {
    let inputs = [
      "Requested scope exceeds configured maximum scopes",
      "Authorization initiation failed",
      "Gateway session has expired. Please log in again.",
      "Gateway upgrade is temporarily unavailable. Please try again later.",
      "Network error: offline",
      "space:blue.catbird.labyrinth.mailbox?action=read",
    ]
    for input in inputs {
      let failure = EncryptedChatPermissionFailure(error: GatewayPermissionError.upgradeFailed(input))
      #expect(!failure.message.contains("space:"))
      #expect(failure.message != "Couldn’t get permission from your server. Please try again.")
    }
  }
}
