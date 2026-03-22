import SwiftUI

/// Inline pill indicating the user's MLS history boundary.
/// Appears where earlier messages aren't decryptable (new member join or device rejoin).
@available(iOS 16.0, *)
struct HistoryBoundaryView: View {
  let text: String

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "lock.fill")
        .font(.caption2)
      Text(text)
        .font(.footnote)
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(.fill.tertiary, in: Capsule())
    .frame(maxWidth: .infinity)
    .padding(.vertical, 8)
  }
}
