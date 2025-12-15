import SwiftUI

/// View that displays read receipt indicators for MLS messages
struct MLSReadReceiptView: View {
  /// Whether this is a sent message (vs received)
  let isSent: Bool

  /// Whether the message has been read
  let isRead: Bool

  /// Number of users who have read the message
  let readByCount: Int?

  var body: some View {
    HStack(spacing: 2) {
      if isSent {
        if isRead || (readByCount ?? 0) > 0 {
          // Double checkmark or read indicator for read messages
          Image(systemName: "checkmark.circle.fill")
            .font(.caption2)
            .foregroundColor(.blue)

          if let count = readByCount, count > 0 {
            Text("Read by \(count)")
              .font(.caption2)
              .foregroundColor(.secondary)
          }
        } else {
          // Single checkmark for sent but not read
          Image(systemName: "checkmark")
            .font(.caption2)
            .foregroundColor(.secondary)
        }
      }
    }
  }
}

#Preview("Sent - Not Read") {
  MLSReadReceiptView(
    isSent: true,
    isRead: false,
    readByCount: nil
  )
  .padding()
}

#Preview("Sent - Read by 1") {
  MLSReadReceiptView(
    isSent: true,
    isRead: true,
    readByCount: 1
  )
  .padding()
}

#Preview("Sent - Read by Multiple") {
  MLSReadReceiptView(
    isSent: true,
    isRead: true,
    readByCount: 3
  )
  .padding()
}

#Preview("Received") {
  MLSReadReceiptView(
    isSent: false,
    isRead: false,
    readByCount: nil
  )
  .padding()
}
