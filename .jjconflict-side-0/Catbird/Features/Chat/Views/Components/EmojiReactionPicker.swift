//import SwiftUI
//import MCEmojiPicker
//
///// A reaction picker that combines quick reaction buttons with the MCEmojiPicker library
///// for full emoji selection with macOS-style popover UI.
//struct EmojiReactionPicker: View {
//  @Binding var isPresented: Bool
//  let onEmojiSelected: (String) -> Void
//  
//  /// Common quick-access reaction emojis
//  private let commonEmojis = ["👍", "❤️", "😂", "😮", "😢", "😡", "🎉", "🔥"]
//  
//  /// State for the full emoji picker
//  @State private var showFullPicker = false
//  @State private var selectedEmoji = ""
//  
//  var body: some View {
//    VStack(spacing: 0) {
//      // Quick reactions bar
//      ScrollView(.horizontal, showsIndicators: false) {
//        HStack(spacing: 12) {
//          ForEach(commonEmojis, id: \.self) { emoji in
//            Button(action: {
//              onEmojiSelected(emoji)
//              isPresented = false
//            }) {
//              Text(emoji)
//                .font(.title2)
//                .frame(width: 44, height: 44)
//                .background(Color.gray.opacity(0.1))
//                .clipShape(Circle())
//            }
//            .buttonStyle(.plain)
//          }
//          
//          // "More" button to open full MCEmojiPicker
//          Button(action: {
//            showFullPicker = true
//          }) {
//            Image(systemName: "face.smiling")
//              .font(.title2)
//              .frame(width: 44, height: 44)
//              .background(Color.accentColor.opacity(0.15))
//              .foregroundColor(.accentColor)
//              .clipShape(Circle())
//          }
//          .buttonStyle(.plain)
//          // Use MCEmojiPicker's SwiftUI modifier
//          .emojiPicker(
//            isPresented: $showFullPicker,
//            selectedEmoji: $selectedEmoji,
//            arrowDirection: .up,
//            isDismissAfterChoosing: true,
//            selectedEmojiCategoryTintColor: .systemBlue
//          )
//        }
//        .padding(.horizontal, 16)
//      }
//      .padding(.vertical, 12)
//    }
//    .background(Color.systemBackground)
//    .clipShape(RoundedRectangle(cornerRadius: 16))
//    .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)
//    .onChange(of: selectedEmoji) { _, newEmoji in
//      if !newEmoji.isEmpty {
//        onEmojiSelected(newEmoji)
//        isPresented = false
//        // Reset for next use
//        selectedEmoji = ""
//      }
//    }
//  }
//}
//
//#Preview {
//  EmojiReactionPicker(isPresented: .constant(true)) { emoji in
//    _ = emoji
//  }
//  .padding()
//}
