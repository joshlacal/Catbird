import SwiftUI

struct PostPositionData: Equatable {
  let id: String
  let frame: CGRect
}

struct PostPositionPreferenceKey: PreferenceKey {
  static var defaultValue: [PostPositionData] = []

  static func reduce(value: inout [PostPositionData], nextValue: () -> [PostPositionData]) {
    value.append(contentsOf: nextValue())
  }
}

extension View {
  func trackPostPosition(id: String) -> some View {
    self.background(
      GeometryReader { geometry in
        Color.clear.preference(
          key: PostPositionPreferenceKey.self,
          value: [PostPositionData(id: id, frame: geometry.frame(in: .global))]
        )
      })
  }
}
