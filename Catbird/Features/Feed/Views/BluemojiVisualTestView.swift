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

    /// The facet JSON exactly as the AppView returns it, decoded through
    /// Petrel — the same path production posts take. An unregistered `$type`
    /// decodes as `.unexpected(.unknownType(_, .object(...)))`; hand-built
    /// `.unexpected(.object(...))` fixtures previously masked that shape.
    private static let facetJSON = Data("""
      {
        "features": [
          {
            "$type": "blue.moji.richtext.facet",
            "alt": "test emoji",
            "did": "did:plc:kmzpsik7s5y5fwu7nnkngfx4",
            "formats": {
              "$type": "blue.moji.richtext.facet#formats_v1",
              "png_128": "bafkreid2gz6qqan76e5ixrw2tgrwof5aqhulxj2gqptryn7j7s4og5vepm",
              "webp_128": "bafkreifei453knthohtbiwxllld676kpmanh6fny2wvdctkj5f745swpra"
            },
            "name": ":test1:"
          }
        ],
        "index": {
          "byteEnd": 17,
          "byteStart": 10
        }
      }
      """.utf8)

    var body: some View {
      ZStack {
        Color(.systemBackground).ignoresSafeArea()
        VStack(spacing: 28) {
          Text("Bluemoji Visual Test").font(.headline)
          Text("real post 3mqchxbzgqh2k").font(.caption2).foregroundStyle(.secondary)
          Text("SwiftUI Text").font(.caption).foregroundStyle(.tertiary)
          Text(rendered).font(.system(size: 40))
          Text("UIKit SelectableSelfSizingTextView").font(.caption).foregroundStyle(.tertiary)
          HarnessSelectableText(attributedString: rendered)
            .fixedSize(horizontal: false, vertical: true)
          Text(status).font(.footnote).foregroundStyle(.secondary)
            .accessibilityIdentifier("bluemoji-status")
        }
        .padding()
      }
      .task {
        let facet: AppBskyRichtextFacet
        do {
          facet = try JSONDecoder().decode(AppBskyRichtextFacet.self, from: Self.facetJSON)
        } catch {
          status = "⚠️ facet failed to decode: \(error)"
          return
        }
        let base = AttributedString(Self.text)
        let out = await renderer.enrich(
          base, text: Self.text, facets: [facet], allowAdult: true)
        rendered = out
        status = String(out.characters).contains("\u{FFFC}")
          ? "✅ glyph spliced into text"
          : "⚠️ fell back to alias text"
      }
    }
  }

  /// Minimal wrapper around the production `SelectableSelfSizingTextView` so the
  /// harness exercises the same UIKit text view posts use — TextKit 2 mode,
  /// `supportsAdaptiveImageGlyph`, and the custom sizing overrides — without
  /// `SelectableTextView`'s AppState environment requirements.
  private struct HarnessSelectableText: UIViewRepresentable {
    let attributedString: AttributedString

    func makeUIView(context: Context) -> SelectableSelfSizingTextView {
      let view = SelectableSelfSizingTextView()
      view.isEditable = false
      view.isSelectable = true
      view.isScrollEnabled = false
      view.supportsAdaptiveImageGlyph = true
      view.backgroundColor = .clear
      view.textContainer.lineFragmentPadding = 0
      view.textContainerInset = .zero
      return view
    }

    func updateUIView(_ view: SelectableSelfSizingTextView, context: Context) {
      let text = NSMutableAttributedString(attributedString)
      text.addAttribute(
        .font, value: UIFont.systemFont(ofSize: 40),
        range: NSRange(location: 0, length: text.length))
      view.attributedText = text
      view.textColor = .label
      view.invalidateIntrinsicContentSize()
    }
  }
#endif
