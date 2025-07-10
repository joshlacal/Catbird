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
      Text("Replying to")
        .foregroundColor(.secondary)
      Text("@\(parentPost.author.handle)")
        .fontWeight(.semibold)
        Spacer()
    }
    .appFont(AppTextRole.subheadline)
    .padding(.vertical, 8)
    .padding(.horizontal, 12)
  }
}