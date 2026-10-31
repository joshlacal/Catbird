import SwiftUI
import UIKit

@main
struct TypographyHarness: App {
  @State private var manager = FontManager()
  @State private var appState = AppState()
  @State private var result = "Measuring production text helpers…"

  private var mode: String {
    ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--sample=") }?
      .replacingOccurrences(of: "--sample=", with: "") ?? "default"
  }

  var body: some Scene {
    WindowGroup {
      ScrollView {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
          Text("Catbird typography fixture").font(.headline)
          Text("Production helpers · \(mode)").font(.caption).foregroundStyle(.secondary)
          Text("Support Catbird").designTitle2()
          Text("Leave an optional tip to support Catbird's development. Thanks for your support!")
            .designBody()
          Divider()
          VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("Maya Chen and the local community").designCallout()
            Text("A longer message preview should remain readable when the preferred text size changes.")
              .designFootnote()
            Text("Yesterday · Message preview").designCaption().foregroundStyle(.secondary)
          }
          Divider()
          Text("Unable to load support options").designHeadline()
          Text("Please try again when you're connected.").designBodyLarge()
          Button("Try Again") { result = runMeasurements() }
            .buttonStyle(.borderedProminent)
          Text(result).font(.caption).foregroundStyle(.secondary)
        }
        .padding(DesignTokens.Spacing.xl)
      }
      .background(Color(uiColor: .systemBackground))
      .fontManager(manager)
      .environment(appState)
      .task {
        manager.maxDynamicTypeSize = "accessibility5"
        if mode == "large-serif" {
          manager.fontSize = "extraLarge"
          manager.fontStyle = "serif"
          manager.lineSpacing = "relaxed"
          manager.letterSpacing = "loose"
          appState.appSettings.boldText = true
        }
        result = runMeasurements()
      }
    }
  }

  @MainActor private func runMeasurements() -> String {
    do {
      let receipt = try TypographyMeasurements.run()
      let directory = URL.documentsDirectory
      let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: directory.appendingPathComponent("typography-measurements.json"))
      return "Production text metrics saved. \(receipt["passed"] as? Int ?? 0) checks passed."
    } catch {
      let failure = ["failure": String(describing: error)]
      if let data = try? JSONSerialization.data(withJSONObject: failure, options: [.prettyPrinted]) {
        try? data.write(to: URL.documentsDirectory.appendingPathComponent("typography-measurements.json"))
      }
      return "Measurement failed: \(String(describing: error))"
    }
  }
}

@MainActor enum TypographyMeasurements {
  static let roles = ["title1", "title2", "headline", "body", "bodyLarge", "callout", "caption", "footnote"]

  struct Rendered {
    let width: CGFloat
    let height: CGFloat
    let pixels: Data
  }

  enum MeasurementError: Error { case noImage, failed(String) }

  @ViewBuilder static func styled(_ value: String, role: String) -> some View {
    switch role {
    case "title1": Text(value).designTitle1()
    case "title2": Text(value).designTitle2()
    case "headline": Text(value).designHeadline()
    case "body": Text(value).designBody()
    case "bodyLarge": Text(value).designBodyLarge()
    case "callout": Text(value).designCallout()
    case "caption": Text(value).designCaption()
    default: Text(value).designFootnote()
    }
  }

  static func render(role: String, manager: FontManager, state: AppState,
                     paragraph: Bool = false, dynamic: Bool = false) throws -> Rendered {
    manager.dynamicTypeEnabled = dynamic
    manager.maxDynamicTypeSize = "accessibility5"
    let sample = paragraph ? "One line of text\nAnother line of text\nA third line of text" : "Catbird readable text"
    let content = styled(sample, role: role)
      .fixedSize(horizontal: true, vertical: true)
      .padding(4)
      .foregroundStyle(.black)
      .background(.white)
      .fontManager(manager)
      .environment(state)
    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    guard let image = renderer.cgImage, let data = image.dataProvider?.data else {
      throw MeasurementError.noImage
    }
    return Rendered(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2, pixels: data as Data)
  }

  static func run() throws -> [String: Any] {
    var samples: [[String: Any]] = []
    var passed = 0
    for role in roles {
      let state = AppState()
      let manager = FontManager()
      let normal = try render(role: role, manager: manager, state: state)
      manager.fontSize = "extraLarge"
      let large = try render(role: role, manager: manager, state: state)
      guard large.height > normal.height && large.width > normal.width else {
        throw MeasurementError.failed("\(role) ignored app font size")
      }
      passed += 1
      manager.fontSize = "default"
      manager.fontStyle = "serif"
      let serif = try render(role: role, manager: manager, state: state)
      guard serif.pixels != normal.pixels else { throw MeasurementError.failed("\(role) ignored font family") }
      passed += 1
      manager.fontStyle = "system"
      manager.letterSpacing = "loose"
      let tracking = try render(role: role, manager: manager, state: state)
      guard tracking.width > normal.width else { throw MeasurementError.failed("\(role) ignored letter spacing") }
      passed += 1
      manager.letterSpacing = "normal"
      let normalParagraph = try render(role: role, manager: manager, state: state, paragraph: true)
      manager.lineSpacing = "relaxed"
      let relaxed = try render(role: role, manager: manager, state: state, paragraph: true)
      guard relaxed.height > normalParagraph.height else { throw MeasurementError.failed("\(role) ignored line spacing") }
      passed += 1
      manager.lineSpacing = "normal"
      state.appSettings.boldText = true
      let bold = try render(role: role, manager: manager, state: state)
      guard bold.pixels != normal.pixels else { throw MeasurementError.failed("\(role) ignored Bold Text") }
      passed += 1
      state.appSettings.boldText = false
      let dynamic = try render(role: role, manager: manager, state: state, dynamic: true)
      samples.append([
        "role": role, "normalWidth": normal.width, "normalHeight": normal.height,
        "appLargeWidth": large.width, "appLargeHeight": large.height,
        "dynamicWidth": dynamic.width, "dynamicHeight": dynamic.height,
        "normalParagraphHeight": normalParagraph.height, "relaxedParagraphHeight": relaxed.height
      ])
    }
    return ["passed": passed, "samples": samples,
            "preferredContentSizeCategory": UIApplication.shared.preferredContentSizeCategory.rawValue,
            "evidenceBoundary": "Production typography sources with fixture app state; no authenticated app or network behavior."]
  }
}
