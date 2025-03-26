//import SwiftUI
//
///// A ScrollView that maintains stable scroll position during content updates
//struct StableScrollView<Content: View>: View {
//  let content: Content
//  @Binding var contentOffset: CGPoint
//  @Binding var visibleID: String?
//
//  init(
//    visibleID: Binding<String?>,
//    contentOffset: Binding<CGPoint>,
//    @ViewBuilder content: () -> Content
//  ) {
//    self.content = content()
//    self._visibleID = visibleID
//    self._contentOffset = contentOffset
//  }
//
//  var body: some View {
//    ScrollView {
//      content
//        .scrollPosition(id: $visibleID)
//    }
//    .background(
//      GeometryReader { geo in
//        Color.clear.preference(
//          key: ScrollOffsetPreferenceKey.self,
//          value: geo.frame(in: .named("scrollView")).origin
//        )
//      }
//    )
//    .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
//      contentOffset = value
//    }
//    .coordinateSpace(name: "scrollView")
//  }
//}
