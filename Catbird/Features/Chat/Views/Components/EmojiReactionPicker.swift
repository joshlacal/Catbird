import SwiftUI

struct EmojiReactionPicker: View {
  @Binding var isPresented: Bool
  let onEmojiSelected: (String) -> Void
  
  private let commonEmojis = ["👍", "❤️", "😂", "😮", "😢", "😡", "🎉", "🔥"]
  private let emojiCategories: [EmojiCategory] = [
    .init(name: "Smileys", emojis: ["😀", "😃", "😄", "😁", "😊", "😍", "🥰", "😘", "😗", "☺️", "😚", "😙", "🥲", "😋", "😛", "😜", "🤪", "😝", "🤑", "🤗", "🤭", "🤫", "🤔", "🤐", "🤨", "😐", "😑", "😶", "😏", "😒", "🙄", "😬", "🤥", "😔", "😪", "🤤", "😴", "😷", "🤒", "🤕", "🤢", "🤮", "🤧", "🥵", "🥶"]),
    .init(name: "Hearts", emojis: ["❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "🤎", "💔", "❣️", "💕", "💞", "💓", "💗", "💖", "💘", "💝"]),
    .init(name: "Gestures", emojis: ["👍", "👎", "👌", "✌️", "🤞", "🤟", "🤘", "🤙", "👈", "👉", "👆", "🖕", "👇", "☝️", "👋", "🤚", "🖐", "✋", "🖖", "👏", "🙌", "🤲", "🤝", "🙏"]),
    .init(name: "Objects", emojis: ["🎉", "🎊", "🔥", "💯", "⚡", "💥", "💨", "💫", "⭐", "🌟", "✨", "💎", "🏆", "🥇", "🥈", "🥉"])
  ]
  
  @State private var selectedCategory = 0
  
  var body: some View {
    VStack(spacing: 0) {
      // Quick reactions bar - responsive layout
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 12) {
          ForEach(commonEmojis, id: \.self) { emoji in
            Button(action: {
              onEmojiSelected(emoji)
              isPresented = false
            }) {
              Text(emoji)
                .font(.title2)
                .frame(width: 44, height: 44)
                .background(Color.gray.opacity(0.1))
                .clipShape(Circle())
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 16)
      }
      .padding(.vertical, 12)
      
      Divider()
      
      // Category picker
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 20) {
          ForEach(Array(emojiCategories.enumerated()), id: \.offset) { index, category in
            Button(action: {
              selectedCategory = index
            }) {
              Text(category.name)
                .font(.caption)
                .fontWeight(selectedCategory == index ? .semibold : .regular)
                .foregroundColor(selectedCategory == index ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 16)
      }
      .padding(.vertical, 8)
      
      // Emoji grid - responsive columns based on available width
      GeometryReader { geometry in
        ScrollView {
          LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: max(6, min(10, Int(geometry.size.width / 45)))), spacing: 4) {
            ForEach(emojiCategories[selectedCategory].emojis, id: \.self) { emoji in
              Button(action: {
                onEmojiSelected(emoji)
                isPresented = false
              }) {
                Text(emoji)
                  .font(.title3)
                  .frame(width: 36, height: 36)
              }
              .buttonStyle(.plain)
            }
          }
          .padding(.horizontal, 16)
        }
      }
      .frame(height: 200)
    }
    .background(Color(.systemBackground))
    .clipShape(RoundedRectangle(cornerRadius: 16))
    .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)
  }
}

struct EmojiReactionPicker_Previews: PreviewProvider {
  static var previews: some View {
    EmojiReactionPicker(isPresented: .constant(true)) { emoji in
      print("Selected: \(emoji)")
    }
    .padding()
  }
}
