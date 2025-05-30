// import SwiftUI
// import MCEmojiPicker
//
// extension View {
//    func emojiPicker(
//        isPresented: Binding<Bool>,
//        selectedEmoji: Binding<String>,
//        arrowDirection: MCPickerArrowDirection = .up,
//        customHeight: CGFloat? = nil,
//        horizontalInset: CGFloat = 0,
//        isDismissAfterChoosing: Bool = true,
//        selectedEmojiCategoryTintColor: UIColor = .systemBlue,
//        feedBackGeneratorStyle: UIImpactFeedbackGenerator.FeedbackStyle? = .light
//    ) -> some View {
//        self.modifier(
//            EmojiPickerViewModifier(
//                isPresented: isPresented,
//                selectedEmoji: selectedEmoji,
//                arrowDirection: arrowDirection,
//                customHeight: customHeight,
//                horizontalInset: horizontalInset,
//                isDismissAfterChoosing: isDismissAfterChoosing,
//                selectedEmojiCategoryTintColor: selectedEmojiCategoryTintColor,
//                feedBackGeneratorStyle: feedBackGeneratorStyle
//            )
//        )
//    }
// }
//
// struct EmojiPickerViewModifier: ViewModifier {
//    @Binding var isPresented: Bool
//    @Binding var selectedEmoji: String
//    let arrowDirection: MCPickerArrowDirection
//    let customHeight: CGFloat?
//    let horizontalInset: CGFloat
//    let isDismissAfterChoosing: Bool
//    let selectedEmojiCategoryTintColor: UIColor
//    let feedBackGeneratorStyle: UIImpactFeedbackGenerator.FeedbackStyle?
//    
//    func body(content: Content) -> some View {
//        content
//            .background(
//                EmptyView()
//                    .background(Color.clear)
//                    .fullScreenCover(isPresented: $isPresented) {
//                        EmojiPickerView(
//                            selectedEmoji: $selectedEmoji,
//                            isPresented: $isPresented,
//                            arrowDirection: arrowDirection,
//                            customHeight: customHeight,
//                            horizontalInset: horizontalInset,
//                            isDismissAfterChoosing: isDismissAfterChoosing,
//                            selectedEmojiCategoryTintColor: selectedEmojiCategoryTintColor,
//                            feedBackGeneratorStyle: feedBackGeneratorStyle
//                        )
//                        .edgesIgnoringSafeArea(.all)
//                    }
//            )
//    }
// }
//
// struct EmojiPickerView: UIViewControllerRepresentable {
//    @Binding var selectedEmoji: String
//    @Binding var isPresented: Bool
//    let arrowDirection: MCPickerArrowDirection
//    let customHeight: CGFloat?
//    let horizontalInset: CGFloat
//    let isDismissAfterChoosing: Bool
//    let selectedEmojiCategoryTintColor: UIColor
//    let feedBackGeneratorStyle: UIImpactFeedbackGenerator.FeedbackStyle?
//    
//    func makeUIViewController(context: Context) -> UIViewController {
//        let hostingController = UIHostingController(rootView: Color.clear)
//        hostingController.view.backgroundColor = .clear
//        DispatchQueue.main.async {
//            let emojiPicker = MCEmojiPickerViewController()
//            emojiPicker.delegate = context.coordinator
//            emojiPicker.sourceView = hostingController.view
//            emojiPicker.arrowDirection = arrowDirection
//            emojiPicker.customHeight = customHeight
//            emojiPicker.horizontalInset = horizontalInset
//            emojiPicker.isDismissAfterChoosing = isDismissAfterChoosing
//            emojiPicker.selectedEmojiCategoryTintColor = selectedEmojiCategoryTintColor
//            emojiPicker.feedBackGeneratorStyle = feedBackGeneratorStyle
//            hostingController.present(emojiPicker, animated: true)
//        }
//        return hostingController
//    }
//    
//    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
//    
//    func makeCoordinator() -> Coordinator {
//        Coordinator(parent: self)
//    }
//    
//    class Coordinator: NSObject, MCEmojiPickerDelegate {
//        var parent: EmojiPickerView
//        init(parent: EmojiPickerView) { self.parent = parent }
//        func didGetEmoji(emoji: String) {
//            parent.selectedEmoji = emoji
//            if parent.isDismissAfterChoosing {
//                parent.isPresented = false
//            }
//        }
//    }
// }
