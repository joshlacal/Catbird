import SwiftUI

/// Lane-local notice shell for Ask Catbird: same anatomy as `CatbirdNotice`
/// (tone icon, footnote message, `catbirdCard(.notice)` chrome) plus a trailing
/// accessory (dismiss) and an actions row, which `CatbirdNotice` does not offer.
struct AskCatbirdNoticeCard<Trailing: View, Actions: View>: View {
  let tone: CatbirdNoticeTone
  let systemImage: String
  let message: Text
  @ViewBuilder var trailing: () -> Trailing
  @ViewBuilder var actions: () -> Actions

  var body: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      HStack(alignment: .top, spacing: Space.md) {
        Image(systemName: systemImage)
          .appFont(AppTextRole.headline)
          .foregroundStyle(tone.color)
          .accessibilityHidden(true)
        message
          .appFont(AppTextRole.footnote)
          .foregroundStyle(Color.primary)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
        trailing()
      }
      actions()
    }
    .padding(Space.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .catbirdCard(.notice(tone), radius: .lg)
    .accessibilityElement(children: .contain)
  }
}
