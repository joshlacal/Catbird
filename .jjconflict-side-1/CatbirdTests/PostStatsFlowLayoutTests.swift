import CoreGraphics
import Testing

@testable import Catbird

@Suite("Post stats flow layout")
struct PostStatsFlowLayoutTests {
  @Test("A finite parent width is preserved during measurement")
  func finiteParentWidthIsPreserved() {
    let metrics = FlowLayoutMetrics.calculate(
      sizes: [
        CGSize(width: 60, height: 20),
        CGSize(width: 45, height: 20),
        CGSize(width: 65, height: 20),
      ],
      availableWidth: 378,
      horizontalSpacing: 12,
      verticalSpacing: 12
    )

    #expect(metrics.size == CGSize(width: 378, height: 20))
    #expect(metrics.lines.map(\.range) == [0..<3])
  }

  @Test("A constrained parent width reports the wrapped row height")
  func constrainedParentWidthReportsWrappedHeight() {
    let metrics = FlowLayoutMetrics.calculate(
      sizes: [
        CGSize(width: 60, height: 20),
        CGSize(width: 45, height: 20),
        CGSize(width: 65, height: 20),
      ],
      availableWidth: 125,
      horizontalSpacing: 12,
      verticalSpacing: 12
    )

    #expect(metrics.size == CGSize(width: 125, height: 52))
    #expect(metrics.lines.map(\.range) == [0..<2, 2..<3])
  }
}
