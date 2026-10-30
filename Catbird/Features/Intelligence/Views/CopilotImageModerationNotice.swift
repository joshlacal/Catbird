import SwiftUI

/// The same cause-key reveal and noOverride rules as the post's body/media
/// gates, applied to AskCatbird's optional pixel input. No media is rendered.
struct CopilotImageModerationNotice: View {
  let snapshot: CopilotImageModerationSnapshot?
  let reveal: ModerationRevealState
  let onReveal: () -> Void
  let onHide: () -> Void

  var body: some View {
    if let snapshot {
      if !snapshot.rowVisible {
        Text("Show the post before choosing an image for inspection.")
          .font(.caption).foregroundStyle(.secondary)
          .padding(.horizontal)
      } else if snapshot.imageUI.blur || snapshot.imageUI.noOverride {
        VStack(alignment: .leading, spacing: 6) {
          Label(ModerationPresentation.title(for: snapshot.imageUI), systemImage: "eye.slash")
            .font(.subheadline)
          Text(ModerationGateText.explanation(for: snapshot.imageUI))
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          if snapshot.imageUI.noOverride {
            Text(ModerationGateText.lockedLabel(for: snapshot.imageUI))
              .font(.caption).foregroundStyle(.secondary)
          } else {
            Button(snapshot.allows(reveal) ? "Hide image options" : "Show image options",
              action: snapshot.allows(reveal) ? onHide : onReveal)
              .buttonStyle(.borderless)
              .frame(minHeight: 44)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("askcatbird.imageModeration")
      }
    } else {
      Text("Image inspection is unavailable until this post’s current moderation can be checked.")
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal)
    }
  }
}
