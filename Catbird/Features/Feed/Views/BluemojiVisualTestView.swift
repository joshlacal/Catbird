#if DEBUG
  import BluemojiKit
  import Petrel
  import SwiftUI

  /// Launch-arg-gated (`--bluemoji-visual-test`) screen that renders a synthetic
  /// post containing a `blue.moji.richtext.facet` through the real
  /// ``BluemojiRenderer``, to visually confirm inline Bluemoji rendering.
  struct BluemojiVisualTestView: View {
    @State private var rendered = AttributedString("Loading Bluemoji…")
    @State private var status = "resolving…"
    private let renderer = BluemojiRenderer()

    private static let text = "hello :test1: world"

    private static func facet() -> AppBskyRichtextFacet {
      // ":test1:" occupies UTF-8 bytes 6..13 of "hello :test1: world".
      AppBskyRichtextFacet(
        index: AppBskyRichtextFacet.ByteSlice(byteStart: 6, byteEnd: 13),
        features: [.unexpected(.object([
          "$type": .string("blue.moji.richtext.facet"),
          "did": .string("did:plc:w5pfavrjij2ax3ur34tvbkg2"),
          "name": .string(":test1:")
        ]))])
    }

    var body: some View {
      ZStack {
        Color(.systemBackground).ignoresSafeArea()
        VStack(spacing: 28) {
          Text("Bluemoji Visual Test").font(.headline)
          Text(rendered).font(.system(size: 40))
          Text(status).font(.footnote).foregroundStyle(.secondary)
            .accessibilityIdentifier("bluemoji-status")
        }
        .padding()
      }
      .task {
        let base = AttributedString(Self.text)
        let out = await renderer.enrich(
          base, text: Self.text, facets: [Self.facet()], allowAdult: true)
        rendered = out
        status = String(out.characters).contains("\u{FFFC}")
          ? "✅ glyph spliced into text"
          : "⚠️ fell back to alias text"
      }
    }
  }
#endif
