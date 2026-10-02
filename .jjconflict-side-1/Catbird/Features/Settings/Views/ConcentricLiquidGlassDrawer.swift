//
//  ConcentricLiquidGlassDrawer.swift
//  Catbird
//

import SwiftUI

#if os(iOS)
struct ConcentricDrawerLayoutMetrics: Equatable, Sendable {
  var panelInset: CGFloat

  static let sideDrawer = ConcentricDrawerLayoutMetrics(
    panelInset: 10
  )

  func panelFrame(in container: CGRect, drawerWidth: CGFloat) -> CGRect {
    let maxPanelMaxX = max(container.minX, container.maxX - panelInset)
    let panelMaxX = min(container.minX + drawerWidth, maxPanelMaxX)
    let panelMinX = container.minX + panelInset
    let panelWidth = max(0, panelMaxX - panelMinX)
    let panelHeight = max(0, container.height - (panelInset * 2))

    return CGRect(
      x: panelMinX,
      y: container.minY + panelInset,
      width: panelWidth,
      height: panelHeight
    )
  }

  func contentFrame(in panelFrame: CGRect) -> CGRect {
    panelFrame
  }
}

struct ConcentricDrawerSectionLayoutMetrics: Equatable, Sendable {
  var panelInset: CGFloat
  var panelGap: CGFloat
  var headerHeight: CGFloat

  static func sideDrawer(headerHeight: CGFloat) -> ConcentricDrawerSectionLayoutMetrics {
    ConcentricDrawerSectionLayoutMetrics(
      panelInset: 10,
      panelGap: 10,
      headerHeight: headerHeight
    )
  }

  func sectionFrames(in container: CGRect) -> (header: CGRect, feeds: CGRect) {
    let panelMinX = container.minX + panelInset
    let panelWidth = max(0, container.width - (panelInset * 2))
    let headerY = container.minY + panelInset
    let clampedHeaderHeight = min(max(0, headerHeight), max(0, container.height - (panelInset * 2)))
    let feedsY = headerY + clampedHeaderHeight + panelGap
    let feedsHeight = max(0, container.maxY - panelInset - feedsY)

    return (
      header: CGRect(
        x: panelMinX,
        y: headerY,
        width: panelWidth,
        height: clampedHeaderHeight
      ),
      feeds: CGRect(
        x: panelMinX,
        y: feedsY,
        width: panelWidth,
        height: feedsHeight
      )
    )
  }
}

struct ConcentricDrawerReadabilityMetrics: Equatable, Sendable {
  var veilOpacity: CGFloat = 0
  var textShadowOpacity: CGFloat = 0
  var textShadowRadius: CGFloat = 2
  var textShadowYOffset: CGFloat = 1
}

enum ConcentricLiquidGlassDrawerSurfaceStyle: Equatable, Sendable {
  case panel
  case clear
}

struct ConcentricLiquidGlassDrawer<Content: View>: View {
  private let metrics: ConcentricDrawerLayoutMetrics
  private let readabilityMetrics: ConcentricDrawerReadabilityMetrics
  private let outlineWidth: CGFloat
  private let surfaceStyle: ConcentricLiquidGlassDrawerSurfaceStyle
  private let content: Content

  init(
    metrics: ConcentricDrawerLayoutMetrics = .sideDrawer,
    readabilityMetrics: ConcentricDrawerReadabilityMetrics = ConcentricDrawerReadabilityMetrics(),
    outlineWidth: CGFloat = 1,
    surfaceStyle: ConcentricLiquidGlassDrawerSurfaceStyle = .panel,
    @ViewBuilder content: () -> Content
  ) {
    self.metrics = metrics
    self.readabilityMetrics = readabilityMetrics
    self.outlineWidth = outlineWidth
    self.surfaceStyle = surfaceStyle
    self.content = content()
  }

  var body: some View {
    GeometryReader { geometry in
      let container = CGRect(origin: .zero, size: geometry.size)
      let panelFrame = metrics.panelFrame(in: container, drawerWidth: geometry.size.width)

      drawerContent(panelFrame: panelFrame, geometrySize: geometry.size)
    }
  }

  @ViewBuilder
  private func drawerContent(panelFrame: CGRect, geometrySize: CGSize) -> some View {
    switch surfaceStyle {
    case .panel:
      ConcentricLiquidGlassPanel(
        readabilityMetrics: readabilityMetrics,
        outlineWidth: outlineWidth
      ) {
        content
          .modifier(DrawerReadabilityShadow(metrics: readabilityMetrics))
      }
      .frame(width: panelFrame.width, height: panelFrame.height)
      .position(x: panelFrame.midX, y: panelFrame.midY)
      .frame(width: geometrySize.width, height: geometrySize.height, alignment: .topLeading)

    case .clear:
      content
        .frame(width: geometrySize.width, height: geometrySize.height, alignment: .topLeading)
    }
  }
}

private struct DrawerReadabilityShadow: ViewModifier {
  let metrics: ConcentricDrawerReadabilityMetrics

  @ViewBuilder
  func body(content: Content) -> some View {
    if metrics.textShadowOpacity > 0 {
      content
        .shadow(
          color: .black.opacity(metrics.textShadowOpacity),
          radius: metrics.textShadowRadius,
          x: 0,
          y: metrics.textShadowYOffset
        )
    } else {
      content
    }
  }
}

struct ConcentricLiquidGlassPanel<Content: View>: View {
  let readabilityMetrics: ConcentricDrawerReadabilityMetrics
  let outlineWidth: CGFloat
  let content: Content

  init(
    readabilityMetrics: ConcentricDrawerReadabilityMetrics = ConcentricDrawerReadabilityMetrics(),
    outlineWidth: CGFloat = 1,
    @ViewBuilder content: () -> Content
  ) {
    self.readabilityMetrics = readabilityMetrics
    self.outlineWidth = outlineWidth
    self.content = content()
  }

  var body: some View {
    if #available(iOS 26.0, *) {
      ConcentricLiquidGlassDrawerPanelIOS26(
        readabilityMetrics: readabilityMetrics,
        outlineWidth: outlineWidth
      ) {
        content
      }
    } else {
      ZStack {
        RoundedRectangle(cornerRadius: 34, style: .continuous)
          .fill(.ultraThinMaterial)

        content
      }
        .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 34, style: .continuous)
            .stroke(.white.opacity(0.38), lineWidth: outlineWidth)
        }
        .shadow(color: .black.opacity(0.14), radius: 20, x: 0, y: 8)
    }
  }
}

@available(iOS 26.0, *)
private struct ConcentricLiquidGlassDrawerPanelIOS26<Content: View>: View {
  let readabilityMetrics: ConcentricDrawerReadabilityMetrics
  let outlineWidth: CGFloat
  let content: Content

  init(
    readabilityMetrics: ConcentricDrawerReadabilityMetrics,
    outlineWidth: CGFloat,
    @ViewBuilder content: () -> Content
  ) {
    self.readabilityMetrics = readabilityMetrics
    self.outlineWidth = outlineWidth
    self.content = content()
  }

  private var shape: ConcentricRectangle {
    ConcentricRectangle(corners: .concentric(minimum: .fixed(28)), isUniform: true)
  }

  // The system glass draws its own rim highlight and depth; layering manual
  // strokes, tints, or shadows on top reads as a second scrim + outline.
  //
  // The glass must be applied as a modifier ON the content (making the content
  // the glass foreground) — never as a clear-shape ZStack sibling underneath
  // it. Inside a GlassEffectContainer the glass is hoisted into a shared
  // rendering pass, and non-glass sibling content overlapping the shape gets
  // sampled into the backdrop, compositing the glass OVER the panel content.
  var body: some View {
    ZStack {
      if readabilityMetrics.veilOpacity > 0 {
        shape
          .fill(.black.opacity(readabilityMetrics.veilOpacity))
          .blendMode(.multiply)
      }

      content
    }
      .glassEffect(.regular, in: shape)
      .clipShape(shape)
      .contentShape(shape)
  }
}
#endif
