import Foundation

/// Converts an HTML document into compact Markdown for the language model.
///
/// The converter keeps the readable body of a page (headings, paragraphs,
/// lists, links, quotes, code, tables and image descriptions) and drops
/// scripts, styles, navigation, forms and page chrome. It never executes
/// anything and never fetches subresources.
enum WebMarkdownConverter {
  struct Page: Equatable, Sendable {
    var title: String?
    var siteName: String?
    var description: String?
    var publishedTime: String?
    var author: String?
    var markdown: String
  }

  static func convert(html: String, baseURL: URL?) -> Page {
    let head = metadata(in: html)
    let cleaned = removingNonContent(from: html)
    let body = mainContent(of: cleaned)
    var writer = MarkdownWriter(baseURL: baseURL)
    writer.render(body)
    return Page(
      title: head.title, siteName: head.siteName, description: head.description,
      publishedTime: head.publishedTime, author: head.author,
      markdown: writer.finish()
    )
  }

  /// Plain text documents only need whitespace normalization.
  static func convert(plainText: String) -> Page {
    let normalized = plainText
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return Page(markdown: normalized)
  }

  // MARK: - Metadata

  private struct Metadata {
    var title: String?
    var siteName: String?
    var description: String?
    var publishedTime: String?
    var author: String?
  }

  private static func metadata(in html: String) -> Metadata {
    var result = Metadata()
    let headEnd = html.range(of: "</head", options: .caseInsensitive)?.lowerBound ?? html.endIndex
    let head = String(html[..<headEnd])

    if let title = firstCapture(#"<title[^>]*>([\s\S]*?)</title\s*>"#, in: head) {
      result.title = cleanInline(title)
    }
    for tag in matches(#"<meta\b[^>]*>"#, in: head) {
      let attributes = parseAttributes(tag)
      let key = (attributes["property"] ?? attributes["name"] ?? attributes["itemprop"] ?? "").lowercased()
      guard let content = attributes["content"].map(cleanInline), !content.isEmpty else { continue }
      switch key {
      case "og:title", "twitter:title":
        if result.title == nil || result.title?.isEmpty == true { result.title = content }
      case "og:site_name", "application-name":
        result.siteName = result.siteName ?? content
      case "description", "og:description", "twitter:description":
        result.description = result.description ?? content
      case "article:published_time", "datepublished", "date", "dc.date", "pubdate":
        result.publishedTime = result.publishedTime ?? content
      case "author", "article:author", "dc.creator":
        result.author = result.author ?? content
      default:
        break
      }
    }
    return result
  }

  // MARK: - Content selection

  private static let droppedElements = [
    "script", "style", "noscript", "template", "svg", "math", "iframe", "object", "embed",
    "canvas", "form", "button", "select", "textarea", "nav", "header", "footer", "aside",
    "dialog", "menu", "head"
  ]

  /// The inside of an opening tag, where a quoted attribute value may contain `>`.
  private static let tagBody = #"(?:[^>"']|"[^"]*"|'[^']*')*"#

  private static func removingNonContent(from html: String) -> String {
    var text = html.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
    text = text.replacingOccurrences(of: #"<!\[CDATA\[[\s\S]*?\]\]>"#, with: "", options: .regularExpression)
    let names = droppedElements.joined(separator: "|")
    text = text.replacingOccurrences(
      of: "<(\(names))\\b\(tagBody)>[\\s\\S]*?</\\1\\s*>", with: " ",
      options: [.regularExpression, .caseInsensitive]
    )
    // A stray tag without its partner would otherwise leak attributes as text.
    text = text.replacingOccurrences(
      of: "</?(?:\(names))\\b\(tagBody)>", with: " ", options: [.regularExpression, .caseInsensitive]
    )
    // Elements that are hidden or declare themselves as page chrome.
    text = text.replacingOccurrences(
      of: #"<(div|section|ul|p|span)\b\#(tagBody)(?:\shidden(?=[\s/>=])|aria-hidden\s*=\s*["']true["']|role\s*=\s*["'](?:navigation|banner|contentinfo|complementary|dialog)["'])\#(tagBody)>[\s\S]*?</\1\s*>"#,
      with: " ", options: [.regularExpression, .caseInsensitive]
    )
    return text
  }

  /// The longest `article`, else `main` or an element with the main role, else `body`.
  private static func mainContent(of html: String) -> String {
    let candidates: [(pattern: String, group: Int)] = [
      (#"<article\b[^>]*>([\s\S]*?)</article\s*>"#, 1),
      (#"<main\b[^>]*>([\s\S]*)</main\s*>"#, 1),
      (#"<(div|section)\b[^>]*role\s*=\s*["']main["'][^>]*>([\s\S]*)</\1\s*>"#, 2)
    ]
    for candidate in candidates {
      let blocks = captures(candidate.pattern, in: html, group: candidate.group)
      if let best = blocks.max(by: { visibleLength($0) < visibleLength($1) }), visibleLength(best) > 200 {
        return best
      }
    }
    if let body = firstCapture(#"<body\b[^>]*>([\s\S]*)</body\s*>"#, in: html) { return body }
    return html
  }

  private static func visibleLength(_ html: String) -> Int {
    html.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
      .filter { !$0.isWhitespace }.count
  }

  // MARK: - Rendering

  private struct MarkdownWriter {
    let baseURL: URL?
    private var output = ""
    private var pendingNewlines = 0
    private var listStack: [(ordered: Bool, index: Int)] = []
    private var quoteDepth = 0
    private var preDepth = 0
    private var linkStack: [(href: String?, start: Int)] = []
    private var tableRow: [String]?
    private var tableCell: String?
    private var tableRowIsHeader = false
    private var tableHeaderWritten = false
    private var skipDepth = 0

    init(baseURL: URL?) { self.baseURL = baseURL }

    mutating func render(_ html: String) {
      var index = html.startIndex
      while index < html.endIndex {
        guard let open = html[index...].firstIndex(of: "<") else {
          text(String(html[index...]))
          break
        }
        if open > index { text(String(html[index..<open])) }
        let next = html.index(after: open)
        guard next < html.endIndex, html[next].isLetter || "/!?".contains(html[next]) else {
          // A literal less-than sign in text, such as "a < b".
          text("<")
          index = next
          continue
        }
        guard let close = Self.tagEnd(in: html, from: next) else {
          text(String(html[open...]))
          break
        }
        tag(String(html[html.index(after: open)..<close]))
        index = html.index(after: close)
      }
    }

    /// The `>` that ends a tag, skipping any inside quoted attribute values
    /// (pages embed JSON and markup in attributes such as `data-mw`).
    static func tagEnd(in html: String, from start: String.Index) -> String.Index? {
      var quote: Character?
      var index = start
      while index < html.endIndex {
        let character = html[index]
        if let open = quote {
          if character == open { quote = nil }
        } else if character == "\"" || character == "'" {
          // Quotes only open a value right after `=` (allowing spaces).
          var back = index
          while back > start {
            back = html.index(before: back)
            if !html[back].isWhitespace { break }
          }
          if html[back] == "=" { quote = character }
        } else if character == ">" {
          return index
        }
        index = html.index(after: index)
      }
      return nil
    }

    mutating func finish() -> String {
      closeTableIfNeeded()
      return output
        .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Text

    private mutating func text(_ raw: String) {
      guard skipDepth == 0 else { return }
      let decoded = decodeEntities(raw)
      if preDepth > 0 {
        for (offset, line) in decoded.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
          if offset > 0 { newline(1) }
          append(String(line))
        }
        return
      }
      let collapsed = decoded.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      guard !collapsed.isEmpty else { return }
      if tableCell != nil {
        tableCell? += collapsed.replacingOccurrences(of: "|", with: "\\|")
        return
      }
      if collapsed == " " {
        if !output.isEmpty, pendingNewlines == 0, output.last?.isWhitespace == false { output += " " }
        return
      }
      append(collapsed)
    }

    private mutating func append(_ value: String) {
      var value = value
      if pendingNewlines > 0 {
        if !output.isEmpty {
          output += String(repeating: "\n", count: pendingNewlines)
        }
        output += linePrefix
        pendingNewlines = 0
        if preDepth == 0 { value = String(value.drop(while: { $0 == " " })) }
      } else if output.isEmpty {
        output += linePrefix
        value = String(value.drop(while: { $0 == " " }))
      }
      output += value
    }

    /// Starts the pending line now so a link's recorded start excludes the line break.
    private mutating func flushPendingLine() {
      guard pendingNewlines > 0, !output.isEmpty else { return }
      output += String(repeating: "\n", count: pendingNewlines) + linePrefix
      pendingNewlines = 0
    }

    private var linePrefix: String {
      String(repeating: "> ", count: quoteDepth)
    }

    private mutating func newline(_ count: Int) {
      guard !output.isEmpty else { return }
      pendingNewlines = max(pendingNewlines, count)
    }

    // MARK: Tags

    private mutating func tag(_ raw: String) {
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, !trimmed.hasPrefix("!"), !trimmed.hasPrefix("?") else { return }
      let isClosing = trimmed.hasPrefix("/")
      let body = isClosing ? String(trimmed.dropFirst()) : trimmed
      let name = String(body.prefix { $0.isLetter || $0.isNumber }).lowercased()
      guard !name.isEmpty else { return }

      if name == "video" || name == "audio" {
        // Fallback text inside media elements describes the player, not the page.
        if isClosing {
          skipDepth = max(0, skipDepth - 1)
        } else {
          let attributes = parseAttributes(body)
          if skipDepth == 0, let title = (attributes["title"] ?? attributes["aria-label"]).map(cleanInline),
             !title.isEmpty {
            appendInline("[\(name.capitalized): \(title)]")
          }
          skipDepth += 1
        }
        return
      }
      guard skipDepth == 0 else { return }

      switch name {
      case "h1", "h2", "h3", "h4", "h5", "h6":
        newline(2)
        if !isClosing, let level = Int(name.dropFirst()) {
          append(String(repeating: "#", count: level) + " ")
        }
      case "p", "div", "section", "figure", "address", "details", "summary", "dl", "center", "fieldset":
        newline(isClosing ? 2 : (name == "div" ? 1 : 2))
      case "br":
        newline(1)
      case "hr":
        newline(2)
        append("---")
        newline(2)
      case "figcaption", "dt", "caption":
        newline(1)
      case "dd":
        newline(1)
        if !isClosing { append(": ") }
      case "blockquote":
        newline(2)
        quoteDepth = max(0, quoteDepth + (isClosing ? -1 : 1))
      case "pre":
        newline(2)
        if isClosing {
          preDepth = max(0, preDepth - 1)
          if preDepth == 0 { newline(1); append("```"); newline(2) }
        } else {
          if preDepth == 0 { append("```"); newline(1) }
          preDepth += 1
        }
      case "code", "kbd", "samp":
        if preDepth == 0 { appendInline("`") }
      case "strong", "b":
        appendInline("**")
      case "em", "i", "cite":
        appendInline("*")
      case "s", "del", "strike":
        appendInline("~~")
      case "ul", "ol":
        newline(listStack.isEmpty ? 2 : 1)
        if isClosing {
          if !listStack.isEmpty { listStack.removeLast() }
          if listStack.isEmpty { newline(2) }
        } else {
          let attributes = parseAttributes(body)
          let start = attributes["start"].flatMap(Int.init) ?? 1
          listStack.append((ordered: name == "ol", index: start))
        }
      case "li":
        newline(1)
        if !isClosing {
          let indent = String(repeating: "  ", count: max(0, listStack.count - 1))
          // Start the line first so the nesting indent is not trimmed as leading space.
          flushPendingLine()
          if var current = listStack.last, current.ordered {
            append("\(indent)\(current.index). ")
            current.index += 1
            listStack[listStack.count - 1] = current
          } else {
            append("\(indent)- ")
          }
        }
      case "a":
        if isClosing {
          closeLink()
        } else {
          let href = parseAttributes(body)["href"].flatMap(resolvedLink)
          flushPendingLine()
          linkStack.append((href: href, start: output.utf8.count))
        }
      case "img":
        let attributes = parseAttributes(body)
        if let alt = attributes["alt"].map(cleanInline), !alt.isEmpty {
          // Responsive markup often repeats one image (picture fallbacks,
          // lazy-load copies); keep a single marker.
          let marker = "[Image: \(alt)]"
          let preceding = tableCell ?? output
          if !preceding.reversed().drop(while: \.isWhitespace).starts(with: marker.reversed()) {
            // The trailing space keeps a following caption from running into it.
            appendInline(marker + " ")
          }
        }
      case "table":
        if isClosing { closeTableIfNeeded() } else { newline(2); tableHeaderWritten = false }
      case "tr":
        if isClosing { finishRow() } else { finishRow(); tableRow = []; tableRowIsHeader = false }
      case "td", "th":
        if isClosing {
          if let cell = tableCell { tableRow?.append(cell.trimmingCharacters(in: .whitespaces)) }
          tableCell = nil
        } else {
          if tableRow == nil { tableRow = [] }
          if name == "th" { tableRowIsHeader = true }
          tableCell = ""
        }
      default:
        break
      }
    }

    private mutating func appendInline(_ marker: String) {
      if tableCell != nil { tableCell? += marker; return }
      append(marker)
    }

    private mutating func closeLink() {
      guard let link = linkStack.popLast(), let href = link.href, link.start <= output.utf8.count else { return }
      let start = output.utf8.index(output.utf8.startIndex, offsetBy: link.start)
      let label = String(output[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !label.isEmpty, !label.contains("\n") else { return }
      let leading = output[start...].prefix { $0 == " " }
      output.replaceSubrange(start..., with: "\(leading)[\(label)](\(href))")
    }

    private func resolvedLink(_ raw: String) -> String? {
      let trimmed = decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
      guard let url = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL,
            let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
      return url.absoluteString
        .replacingOccurrences(of: "(", with: "%28")
        .replacingOccurrences(of: ")", with: "%29")
        .replacingOccurrences(of: " ", with: "%20")
    }

    private mutating func finishRow() {
      guard let row = tableRow else { return }
      if let cell = tableCell { tableRow?.append(cell); tableCell = nil }
      let cells = (tableRow ?? row).map { $0.isEmpty ? " " : $0 }
      tableRow = nil
      guard cells.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return }
      newline(1)
      append("| " + cells.joined(separator: " | ") + " |")
      if tableRowIsHeader && !tableHeaderWritten {
        newline(1)
        append("|" + String(repeating: " --- |", count: cells.count))
      }
      tableHeaderWritten = true
    }

    private mutating func closeTableIfNeeded() {
      finishRow()
      newline(2)
    }
  }

  // MARK: - Helpers

  static func cleanInline(_ value: String) -> String {
    decodeEntities(value.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression))
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static let namedEntities: [String: String] = [
    "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ensp": " ", "emsp": " ",
    "thinsp": " ", "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "sbquo": "‚",
    "ldquo": "“", "rdquo": "”", "bdquo": "„", "laquo": "«", "raquo": "»", "copy": "©", "reg": "®",
    "trade": "™", "middot": "·", "bull": "•", "deg": "°", "times": "×", "divide": "÷", "euro": "€",
    "pound": "£", "yen": "¥", "cent": "¢", "sect": "§", "para": "¶", "shy": "", "zwj": "", "zwnj": "",
    "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "minus": "−", "plusmn": "±", "frac12": "½",
    "frac14": "¼", "frac34": "¾", "iexcl": "¡", "iquest": "¿", "eacute": "é", "egrave": "è", "aacute": "á",
    "agrave": "à", "oacute": "ó", "uacute": "ú", "iacute": "í", "ntilde": "ñ", "ccedil": "ç", "uuml": "ü",
    "ouml": "ö", "auml": "ä", "szlig": "ß", "prime": "′", "Prime": "″"
  ]

  static func decodeEntities(_ value: String) -> String {
    guard value.contains("&") else { return value }
    var result = ""
    result.reserveCapacity(value.count)
    var index = value.startIndex
    while index < value.endIndex {
      let character = value[index]
      guard character == "&",
            let semicolon = value[index...].prefix(12).firstIndex(of: ";") else {
        result.append(character)
        index = value.index(after: index)
        continue
      }
      let entity = value[value.index(after: index)..<semicolon]
      var replacement: String?
      if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
        replacement = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
      } else if entity.hasPrefix("#") {
        replacement = UInt32(entity.dropFirst(), radix: 10).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
      } else {
        replacement = namedEntities[String(entity)]
      }
      if let replacement {
        result += replacement
        index = value.index(after: semicolon)
      } else {
        result.append(character)
        index = value.index(after: index)
      }
    }
    return result
  }

  static func parseAttributes(_ tag: String) -> [String: String] {
    var attributes: [String: String] = [:]
    let pattern = #"([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return attributes }
    let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
    for match in regex.matches(in: tag, range: range) {
      guard let nameRange = Range(match.range(at: 1), in: tag) else { continue }
      let name = tag[nameRange].lowercased()
      guard attributes[name] == nil else { continue }
      for group in 2...4 {
        if let valueRange = Range(match.range(at: group), in: tag) {
          attributes[name] = decodeEntities(String(tag[valueRange]))
          break
        }
      }
    }
    // Boolean attributes such as `hidden` carry no value.
    return attributes
  }

  private static func matches(_ pattern: String, in text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
  }

  private static func captures(_ pattern: String, in text: String, group: Int) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, range: range).compactMap {
      Range($0.range(at: group), in: text).map { String(text[$0]) }
    }
  }

  private static func firstCapture(_ pattern: String, in text: String) -> String? {
    captures(pattern, in: text, group: 1).first
  }
}
