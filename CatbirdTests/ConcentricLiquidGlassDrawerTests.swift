//
//  ConcentricLiquidGlassDrawerTests.swift
//  CatbirdTests
//

import CoreGraphics
import Testing
@testable import Catbird

#if os(iOS)
@Suite("Concentric Liquid Glass Drawer")
struct ConcentricLiquidGlassDrawerTests {
  @Test("panel frame keeps every outlined edge inside the display")
  func panelFrameKeepsOutlineInsideDisplay() {
    let metrics = ConcentricDrawerLayoutMetrics(panelInset: 10)
    let container = CGRect(x: 0, y: 0, width: 402, height: 874)

    let frame = metrics.panelFrame(in: container, drawerWidth: 320)

    #expect(frame == CGRect(x: 10, y: 10, width: 310, height: 854))
  }

  @Test("hosted content fills the outlined glass panel")
  func contentFrameFillsPanel() {
    let metrics = ConcentricDrawerLayoutMetrics(panelInset: 10)
    let panel = CGRect(x: 10, y: 10, width: 310, height: 854)

    let frame = metrics.contentFrame(in: panel)

    #expect(frame == panel)
  }

  @Test("panel width never grows past the available display width")
  func panelWidthCapsToContainer() {
    let metrics = ConcentricDrawerLayoutMetrics(panelInset: 12)
    let container = CGRect(x: 0, y: 0, width: 300, height: 700)

    let frame = metrics.panelFrame(in: container, drawerWidth: 360)

    #expect(frame == CGRect(x: 12, y: 12, width: 276, height: 676))
  }

  @Test("section layout creates separate header and feeds panels")
  func sectionLayoutCreatesSeparateHeaderAndFeedsPanels() {
    let metrics = ConcentricDrawerSectionLayoutMetrics(
      panelInset: 10,
      panelGap: 10,
      headerHeight: 150
    )
    let container = CGRect(x: 0, y: 0, width: 320, height: 720)

    let frames = metrics.sectionFrames(in: container)

    #expect(frames.header == CGRect(x: 10, y: 10, width: 300, height: 150))
    #expect(frames.feeds == CGRect(x: 10, y: 170, width: 300, height: 540))
  }

  @Test("backdrop tuning uses material blur without blurring root content")
  func backdropTuningUsesMaterialBlurWithoutBlurringRootContent() {
    let metrics = ConcentricDrawerBackdropMetrics()

    #expect(metrics.materialOpacity(for: 1) == 0.62)
    #expect(metrics.scrimOpacity(for: 1) == 0)
    #expect(metrics.blurRadius(for: 1) == 0)
  }

  @Test("readability tuning lets system glass carry the surface")
  func readabilityTuningLetsSystemGlassCarrySurface() {
    let metrics = ConcentricDrawerReadabilityMetrics()

    #expect(metrics.veilOpacity == 0)
    #expect(metrics.textShadowOpacity == 0)
    #expect(metrics.textShadowRadius == 2)
    #expect(metrics.textShadowYOffset == 1)
  }
}
#endif
