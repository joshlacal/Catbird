#if DEBUG
  import BluemojiKit
  import Petrel
  import SwiftUI

  /// Launch-arg-gated (`--bluemoji-visual-test`) screen that renders a **real,
  /// in-the-wild** post containing a `blue.moji.richtext.facet` through the real
  /// ``BluemojiRenderer``, to visually confirm inline Bluemoji rendering.
  ///
  /// Source post: `at://did:plc:kmzpsik7s5y5fwu7nnkngfx4/app.bsky.feed.post/3mqchxbzgqh2k`
  struct BluemojiVisualTestView: View {
    @State private var rendered = AttributedString("Loading Bluemoji…")
    @State private var status = "resolving…"
    private let renderer = BluemojiRenderer()

    // Verbatim text + facet of the organic post 3mqchxbzgqh2k.
    private static let text = "test test :test1: yay"

    private static func facet() -> AppBskyRichtextFacet {
      // ":test1:" occupies UTF-8 bytes 10..17 of "test test :test1: yay".
      AppBskyRichtextFacet(
        index: AppBskyRichtextFacet.ByteSlice(byteStart: 10, byteEnd: 17),
        features: [.unexpected(.object([
          "$type": .string("blue.moji.richtext.facet"),
          "did": .string("did:plc:kmzpsik7s5y5fwu7nnkngfx4"),
          "name": .string(":test1:")
        ]))])
    }

    var body: some View {
      ZStack {
        Color(.systemBackground).ignoresSafeArea()
        VStack(spacing: 28) {
          Text("Bluemoji Visual Test").font(.headline)
          Text("real post 3mqchxbzgqh2k").font(.caption2).foregroundStyle(.secondary)
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
