import CatbirdMLSCore
import Foundation

#if os(iOS)

    // MARK: - Recovery State

    /// State tracking for key package desync recovery
    enum RecoveryState: Equatable {
        case none
        case needed
        case inProgress
        case success
        case failed(String)
    }

    struct RejoinStatusPresentation: Equatable {
        let title: String
        let detail: String
        let iconName: String
        let showsProgress: Bool
        let showsRetry: Bool
        var showsReset: Bool = false
    }

    func rejoinStatusPresentation(for recoveryState: RecoveryState) -> RejoinStatusPresentation? {
        switch recoveryState {
        case .inProgress:
            return RejoinStatusPresentation(
                title: "Updating secure session",
                detail: "Rejoining to keep forward secrecy up to date.",
                iconName: "arrow.triangle.2.circlepath.circle.fill",
                showsProgress: true,
                showsRetry: false
            )
        case .success:
            return RejoinStatusPresentation(
                title: "Secure session restored",
                detail: "You're rejoined and can continue chatting.",
                iconName: "checkmark.shield.fill",
                showsProgress: false,
                showsRetry: false
            )
        case .failed:
            return RejoinStatusPresentation(
                title: "Secure rejoin not completed",
                detail: "Your messages remain protected. Try rejoining again.",
                iconName: "exclamationmark.shield.fill",
                showsProgress: false,
                showsRetry: true
            )
        case .none, .needed:
            return nil
        }
    }

    // MARK: - Message Error Info

    /// Information about message processing errors
    struct MessageErrorInfo: Equatable {
        let processingError: String?
        let processingAttempts: Int
        let validationFailureReason: String?
    }

    // MARK: - MLS Conversation Detail View

    /// Chat interface for an end-to-end encrypted MLS conversation with E2EE badge
    /// Tracks which MLS conversations are currently visible in the foreground.
    /// Used by NotificationManager to suppress banners for the active chat.
    final class MLSActiveConversationTracker: @unchecked Sendable {
        static let shared = MLSActiveConversationTracker()
        private let lock = NSLock()
        private var activeIDs: Set<String> = []

        func setActive(_ conversationID: String) {
            lock.lock()
            activeIDs.insert(conversationID)
            lock.unlock()
        }

        func setInactive(_ conversationID: String) {
            lock.lock()
            activeIDs.remove(conversationID)
            lock.unlock()
        }

        func isActive(_ conversationID: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return activeIDs.contains(conversationID)
        }
    }

    struct MLSMessageEditSession {
        private(set) var message: MLSMessageAdapter?
        private(set) var draftText: String?

        internal init() {}

        mutating func begin(_ message: MLSMessageAdapter) {
            self.message = message
            draftText = message.text
        }

        mutating func prepareSubmission(draftText: String) -> MLSMessageAdapter? {
            guard let message else { return nil }
            self.draftText = draftText
            return message
        }

        mutating func finish(succeeded: Bool) {
            guard succeeded else { return }
            message = nil
            draftText = nil
        }

        mutating func cancel() {
            message = nil
            draftText = nil
        }
    }

#endif
