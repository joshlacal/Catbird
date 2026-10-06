import SwiftUI
import Petrel

extension PostComposerViewUIKit {
  /// Only the verified switch callback may close the source editor.
  /// Cancel, same-account selection and failed authentication leave it open.
  func handleAccountSwitchComplete(
    _ outcome: AccountSwitchOutcome,
    vm: PostComposerViewModel,
    snapshot: ComposerEditingSnapshot?
  ) {
    guard case let .switched(accountDID, reopenID) = outcome,
          let snapshot, reopenID != nil,
          accountDID != snapshot.claim.accountDID,
          snapshot.claim == vm.editingClaim else { return }
    _ = vm.detachEditingDraftForTransfer(snapshot)
    autoSaveTask?.cancel()
    suppressAutoSaveOnDismiss = true
    dismiss()
  }
}
