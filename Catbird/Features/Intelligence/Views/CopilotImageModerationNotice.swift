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
          .appFont(AppTextRole.caption).foregroundStyle(.secondary)
          .padding(.horizontal, Space.lg)
      } else if snapshot.imageUI.blur || snapshot.imageUI.noOverride {
        VStack(alignment: .leading, spacing: Space.sm) {
          Label(ModerationPresentation.title(for: snapshot.imageUI), systemImage: "eye.slash")
            .appFont(AppTextRole.subheadline)
          Text(ModerationGateText.explanation(for: snapshot.imageUI))
            .appFont(AppTextRole.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          if snapshot.imageUI.noOverride {
            Text(ModerationGateText.lockedLabel(for: snapshot.imageUI))
              .appFont(AppTextRole.caption).foregroundStyle(.secondary)
          } else {
            Button(snapshot.allows(reveal) ? "Hide image options" : "Show image options",
              action: snapshot.allows(reveal) ? onHide : onReveal)
              .buttonStyle(.catbird(.tonal, size: .sm))
              .tint(CatbirdNoticeTone.warning.color)
          }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .catbirdCard(.notice(.warning), radius: .lg)
        .padding(.horizontal, Space.lg)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("askcatbird.imageModeration")
      }
    } else {
      Text("Image inspection is unavailable until this post’s current moderation can be checked.")
        .appFont(AppTextRole.caption).foregroundStyle(.secondary)
        .padding(.horizontal, Space.lg)
    }
  }
}
