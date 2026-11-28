import SwiftUI

// MARK: - Block model

/// Splits an Ask Catbird answer into Markdown blocks. Inline syntax (bold,
/// italics, code, links) is rendered per block by `CopilotReferencePresentation`.
enum AskCatbirdMarkdown {
  enum Block: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(indent: Int, text: String)
    case numbered(indent: Int, number: String, text: String)
    case quote(String)
    case code(String)
    case divider
  }

  private final class BlocksBox {
    let value: [Block]
    init(_ value: [Block]) { self.value = value }
  }
  private nonisolated(unsafe) static let cache = NSCache<NSString, BlocksBox>()

  static func blocks(_ text: String) -> [Block] {
    let key = text as NSString
    if let cached = cache.object(forKey: key) { return cached.value }
    let result = parse(text)
    cache.setObject(BlocksBox(result), forKey: key)
    return result
  }

  static func parse(_ text: String) -> [Block] {
    var parser = Parser()
    for line in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
      parser.consume(String(line))
    }
    return parser.finish()
  }

  /// Line-by-line block parser; each line either extends the open block or starts a new one.
  private struct Parser {
    var blocks: [Block] = []
    var paragraph: [String] = []
    var quote: [String] = []
    var code: [String]?

    mutating func consume(_ line: String) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if code != nil {
        consumeCode(line, trimmed: trimmed)
        return
      }
      if trimmed.hasPrefix("```") {
        flushParagraph(); flushQuote()
        code = []
      } else if trimmed.isEmpty {
        flushParagraph(); flushQuote()
      } else if trimmed.hasPrefix(">") {
        flushParagraph()
        quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
      } else {
        flushQuote()
        consumeText(line, trimmed: trimmed)
      }
    }

    mutating func finish() -> [Block] {
      if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
      code = nil
      flushParagraph(); flushQuote()
      return blocks
    }

    private mutating func consumeCode(_ line: String, trimmed: String) {
      guard trimmed.hasPrefix("```") else {
        code?.append(line)
        return
      }
      blocks.append(.code((code ?? []).joined(separator: "\n")))
      code = nil
    }

    private mutating func consumeText(_ line: String, trimmed: String) {
      if let block = AskCatbirdMarkdown.heading(trimmed) ?? (AskCatbirdMarkdown.isDivider(trimmed) ? .divider : nil)
        ?? AskCatbirdMarkdown.listItem(line) {
        flushParagraph()
        blocks.append(block)
      } else if paragraph.isEmpty, line.first == " " || line.first == "\t", let last = blocks.last,
                let continued = AskCatbirdMarkdown.continuing(last, with: trimmed) {
        // An indented line directly under a list item continues that item.
        blocks[blocks.count - 1] = continued
      } else {
        paragraph.append(trimmed)
      }
    }

    private mutating func flushParagraph() {
      guard !paragraph.isEmpty else { return }
      blocks.append(.paragraph(paragraph.joined(separator: "\n")))
      paragraph = []
    }

    private mutating func flushQuote() {
      guard !quote.isEmpty else { return }
      blocks.append(.quote(quote.joined(separator: "\n")))
      quote = []
    }
  }

  private static func heading(_ line: String) -> Block? {
    let hashes = line.prefix { $0 == "#" }.count
    guard (1...6).contains(hashes) else { return nil }
    let rest = line.dropFirst(hashes)
    guard rest.first == " " else { return nil }
    let text = rest.trimmingCharacters(in: .whitespaces)
      .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
      .trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? nil : .heading(level: hashes, text: text)
  }

  private static func isDivider(_ line: String) -> Bool {
    let compact = line.replacingOccurrences(of: " ", with: "")
    guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
    return compact.allSatisfy { $0 == first }
  }

  private static func listItem(_ line: String) -> Block? {
    let leading = line.prefix { $0 == " " || $0 == "\t" }
    let indent = min(leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2, 3)
    let body = line.dropFirst(leading.count)
    if let marker = body.first, "-*+•".contains(marker), body.dropFirst().first == " " {
      let text = body.dropFirst(2).trimmingCharacters(in: .whitespaces)
      return text.isEmpty ? nil : .bullet(indent: indent, text: text)
    }
    let digits = body.prefix { $0.isASCII && $0.isNumber }
    guard (1...3).contains(digits.count) else { return nil }
    let afterDigits = body.dropFirst(digits.count)
    guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")",
          afterDigits.dropFirst().first == " " else { return nil }
    let text = afterDigits.dropFirst(2).trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? nil : .numbered(indent: indent, number: String(digits), text: text)
  }

  private static func continuing(_ block: Block, with line: String) -> Block? {
    switch block {
    case .bullet(let indent, let text): return .bullet(indent: indent, text: text + "\n" + line)
    case .numbered(let indent, let number, let text): return .numbered(indent: indent, number: number, text: text + "\n" + line)
    default: return nil
    }
  }

  /// Inline Markdown (bold, italics, strikethrough, code, links) with bare web
  /// links detected. Unparseable input falls back to plain text.
  static func inline(_ text: String) -> AttributedString {
    guard !text.isEmpty else { return AttributedString() }
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace,
      failurePolicy: .returnPartiallyParsedIfPossible
    )
    guard var attributed = try? AttributedString(markdown: text, options: options) else {
      return ChatTextRenderer.attributedString(for: text)
    }
    // Only web links are followed from answers; other schemes stay plain text.
    for run in attributed.runs {
      if let url = run.link, !["http", "https"].contains(url.scheme?.lowercased() ?? "") {
        attributed[run.range].link = nil
      }
    }
    let plain = String(attributed.characters)
    guard let detector = linkDetector else { return attributed }
    for match in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
      guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            let range = Range(match.range, in: plain),
            let lower = AttributedString.Index(range.lowerBound, within: attributed),
            let upper = AttributedString.Index(range.upperBound, within: attributed),
            attributed[lower..<upper].runs.allSatisfy({ $0.link == nil }) else { continue }
      attributed[lower..<upper].link = url
    }
    return attributed
  }

  private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

  /// The answer as plain text, for accessibility and history titles.
  static func plainText(_ text: String) -> String {
    blocks(text).map { block -> String in
      switch block {
      case .heading(_, let text), .paragraph(let text), .quote(let text):
        return String(inline(text).characters)
      case .bullet(_, let text): return "• " + String(inline(text).characters)
      case .numbered(_, let number, let text): return number + ". " + String(inline(text).characters)
      case .code(let text): return text
      case .divider: return ""
      }
    }.filter { !$0.isEmpty }.joined(separator: "\n")
  }
}

// MARK: - View

/// Renders an Ask Catbird answer as Markdown blocks, linking post, profile and
/// web references through `CopilotReferencePresentation`.
struct AskCatbirdMarkdownText: View {
  let text: String
  let sources: [CopilotSource]

  var body: some View {
    VStack(alignment: .leading, spacing: Space.md) {
      ForEach(Array(AskCatbirdMarkdown.blocks(text).enumerated()), id: \.offset) { _, block in
        blockView(block)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func inline(_ text: String) -> AttributedString {
    CopilotReferencePresentation.render(text, sources: sources)
  }

  @ViewBuilder
  private func blockView(_ block: AskCatbirdMarkdown.Block) -> some View {
    switch block {
    case .heading(let level, let text):
      Text(inline(text))
        .appFont(level <= 2 ? AppTextRole.headline : AppTextRole.subheadline)
        .fontWeight(.semibold)
        .padding(.top, Space.xs)
        .accessibilityAddTraits(.isHeader)
        .modifier(AnswerTextModifier())
    case .paragraph(let text):
      Text(inline(text))
        .appFont(AppTextRole.body)
        .lineSpacing(Space.xs)
        .modifier(AnswerTextModifier())
    case .bullet(let indent, let text):
      listRow(marker: indent == 0 ? "•" : "◦", indent: indent, text: text)
    case .numbered(let indent, let number, let text):
      listRow(marker: number + ".", indent: indent, text: text)
    case .quote(let text):
      HStack(alignment: .top, spacing: Space.sm) {
        Capsule()
          .fill(Color.secondary.opacity(0.4))
          .frame(width: 3)
          .accessibilityHidden(true)
        Text(inline(text))
          .appFont(AppTextRole.body)
          .foregroundStyle(.secondary)
          .modifier(AnswerTextModifier())
      }
      .fixedSize(horizontal: false, vertical: true)
    case .code(let text):
      ScrollView(.horizontal, showsIndicators: false) {
        Text(verbatim: text)
          .font(.system(.callout, design: .monospaced))
          .textSelection(.enabled)
          .padding(Space.md)
      }
      .background(Color.secondary.opacity(0.1), in: Radius.sm.shape)
    case .divider:
      Divider().accessibilityHidden(true)
    }
  }

  private func listRow(marker: String, indent: Int, text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
      Text(verbatim: marker)
        .appFont(AppTextRole.body)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(inline(text))
        .appFont(AppTextRole.body)
        .lineSpacing(Space.xs)
        .modifier(AnswerTextModifier())
    }
    .padding(.leading, CGFloat(indent) * Space.lg)
  }
}

private struct AnswerTextModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}
