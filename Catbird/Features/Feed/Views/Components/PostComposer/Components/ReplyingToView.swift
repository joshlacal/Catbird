//
//  ReplyingToView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 12/18/23.
//

import SwiftUI
import Petrel

struct ReplyingToView: View {
  let parentPost: AppBskyFeedDefs.PostView

  var body: some View {
    HStack {
      Text(
        "Replying to \(Text(verbatim: "@\(parentPost.author.handle)").fontWeight(.semibold).foregroundColor(.primary))",
        comment: "Header above post composer indicating which user handle is being replied to"
      )
      .foregroundColor(.secondary)
      Spacer()
    }
    .appFont(AppTextRole.subheadline)
    .padding(.vertical, 8)
    .padding(.horizontal, 12)
  }
}
#Preview("Replying To") {
  AsyncPreviewDataContent { appState in
    await PreviewData.firstPostView(from: appState)
  } content: { _, post in
    ReplyingToView(parentPost: post)
  }
}
