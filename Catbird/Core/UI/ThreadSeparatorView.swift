import SwiftUI
import Petrel

/// A view that displays a "[...] View full thread" separator in collapsed thread mode
struct ThreadSeparatorView: View {
  
  // MARK: - Properties
  
  let hiddenPostCount: Int
  let onTap: () -> Void
  
  // MARK: - Layout Constants
  
  private static let baseUnit: CGFloat = 3
  private static let avatarContainerWidth: CGFloat = 54
  
  // MARK: - Body
  
  var body: some View {
    Button(action: onTap) {
      HStack(alignment: .center, spacing: 0) {
        threadContinuationLine
        .frame(width: Self.avatarContainerWidth)
        .padding(.horizontal, Self.baseUnit)
      
        threadContinuationContent
//      .padding(.horizontal, Self.baseUnit)
      
        Spacer()
      }
    }
    .buttonStyle(.plain)
    .contentShape(Rectangle())
    .padding(.bottom, Self.baseUnit)
  }
  
  // MARK: - Components
  
  /// The visual line connecting the thread parts
  private var threadContinuationLine: some View {
      VStack(alignment: .center, spacing: Self.baseUnit * 2) {
      Rectangle()
        .fill(Color.systemGray4)
        .frame(width: 2)
        .frame(maxHeight: .infinity)
      
      // Center dots indicator
      threeDots
      
      Rectangle()
        .fill(Color.systemGray4)
        .frame(width: 2)
        .frame(maxHeight: .infinity)

    }
  }
  
  /// Three dots indicating continuation
  private var threeDots: some View {
    VStack(spacing: Self.baseUnit) {
      ForEach(0..<3, id: \.self) { _ in
        Circle()
          .fill(Color.systemGray3)
          .frame(width: 4, height: 4)
      }
    }
  }
  
  /// The call-to-action content for viewing the full thread
  private var threadContinuationContent: some View {
    HStack {
      Text("View full thread")
        .appFont(AppTextRole.subheadline)
        .foregroundColor(.accentColor)
      Image(systemName: "chevron.right")
        .appFont(AppTextRole.subheadline)
        .foregroundColor(.accentColor)
    }
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }

      /*
       HStack(spacing: 0) {
//      Image(systemName: "bubble.left.and.bubble.right")
//        .appFont(AppTextRole.subheadline)
//        .foregroundColor(.accentColor)
      
      VStack(alignment: .leading, spacing: 0) {
          HStack {
              
              Text("View full thread")
                  .appFont(AppTextRole.subheadline)
                  .foregroundColor(.accentColor)
              Image(systemName: "chevron.right")
                  .appFont(AppTextRole.subheadline)
                  .foregroundColor(.accentColor)
          }
        if hiddenPostCount > 0 {
          Text("\(hiddenPostCount) more \(hiddenPostCount == 1 ? "reply" : "replies")")
            .appFont(AppTextRole.caption)
            .foregroundColor(.secondary)
        }
      }
      
//      Spacer()
//      
//      Image(systemName: "chevron.right")
//        .appFont(AppTextRole.caption)
//        .foregroundStyle(.tertiary)
    }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)

//    .padding(.horizontal, Self.baseUnit * 3)
//    .padding(.vertical, Self.baseUnit * 2)
//    .background(
//      RoundedRectangle(cornerRadius: 8)
//        .fill(Color.secondary.opacity(0.1))
//        .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
//    )
    .contentShape(Rectangle())
  }
    */
}

// MARK: - Preview

#Preview {
    @Previewable @Environment(AppState.self) var appState
  VStack(spacing: 20) {
    ThreadSeparatorView(hiddenPostCount: 5) {
      logger.debug("Tapped thread continuation")
    }
    
    ThreadSeparatorView(hiddenPostCount: 1) {
      logger.debug("Tapped thread continuation")
    }
    
    ThreadSeparatorView(hiddenPostCount: 0) {
      logger.debug("Tapped thread continuation")
    }
  }
  .padding()
}
