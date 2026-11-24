import Foundation
import Testing
@testable import Catbird

struct WebFetchURLPolicyTests {
  @Test(arguments: [
    "https://example.com/article",
    "http://news.example.org/a?b=c",
    "https://93.184.216.34/",
    "https://[2606:2800:220:1:248:1893:25c8:1946]/",
    "https://example.com:443/path"
  ])
  func publicWebAddressesAreAccepted(_ link: String) throws {
    _ = try WebFetchURLPolicy.validate(link)
  }

  @Test(arguments: [
    ("ftp://example.com/file", WebFetchURLPolicy.Rejection.unsupportedScheme),
    ("file:///etc/passwd", .unsupportedScheme),
    ("javascript:alert(1)", .unsupportedScheme),
    ("https://user:secret@example.com/", .embeddedCredentials),
    ("https://example.com:8443/", .nonDefaultPort),
    ("http://localhost/", .blockedHost),
    ("http://printer.local/", .blockedHost),
    ("http://router/", .blockedHost),
    ("http://metadata.internal/", .blockedHost),
    ("http://127.0.0.1/", .blockedHost),
    ("http://127.1/", .blockedHost),
    ("http://0x7f.1/", .blockedHost),
    ("http://2130706433/", .blockedHost),
    ("http://10.0.0.5/", .blockedHost),
    ("http://172.16.4.2/", .blockedHost),
    ("http://192.168.1.1/", .blockedHost),
    ("http://169.254.169.254/latest/meta-data", .blockedHost),
    ("http://100.64.0.1/", .blockedHost),
    ("http://0.0.0.0/", .blockedHost),
    ("http://[::1]/", .blockedHost),
    ("http://[fd00::1]/", .blockedHost),
    ("http://[fe80::1]/", .blockedHost),
    ("http://[::ffff:192.168.0.1]/", .blockedHost),
    ("http://[64:ff9b::a00:1]/", .blockedHost),
    ("http://[2002:c0a8:0101::1]/", .blockedHost)
  ])
  func localAndPrivateAddressesAreRejected(_ link: String, _ expected: WebFetchURLPolicy.Rejection) {
    #expect(throws: expected) { try WebFetchURLPolicy.validate(link) }
  }

  @Test func malformedOrOversizedLinksAreRejected() {
    #expect(throws: WebFetchURLPolicy.Rejection.invalidURL) { try WebFetchURLPolicy.validate("") }
    let long = "https://example.com/" + String(repeating: "a", count: 3_000)
    #expect(throws: WebFetchURLPolicy.Rejection.invalidURL) { try WebFetchURLPolicy.validate(long) }
  }

  @Test func resolvedPrivateAddressesAreRejected() async {
    // "localhost" resolves to loopback even when it would pass a name check.
    await #expect(throws: WebFetchURLPolicy.Rejection.blockedHost) {
      try await WebFetchURLPolicy.validateResolvedAddresses(of: URL(string: "http://localhost/")!)
    }
  }
}

struct AskCatbirdLinkRegistryTests {
  @Test func onlyLinksAlreadySeenCanBeOpened() async {
    let registry = AskCatbirdLinkRegistry(seedText: ["Read https://Example.com/story/ and www.news.org/item"])
    #expect(await registry.contains(URL(string: "https://example.com/story")!))
    #expect(await registry.contains(URL(string: "https://example.com/story#section")!))
    #expect(await registry.contains(URL(string: "http://www.news.org/item")!))
    #expect(await !registry.contains(URL(string: "https://example.com/story?leak=secret")!))
    #expect(await !registry.contains(URL(string: "https://attacker.example/")!))
  }

  @Test func toolResultsAddLinksForLaterReads() async {
    let registry = AskCatbirdLinkRegistry()
    #expect(await registry.isEmpty)
    await registry.ingest(#"{"posts":[{"media":[{"uri":"https://blog.example.com/post"}]}]}"#)
    #expect(await registry.contains(URL(string: "https://blog.example.com/post")!))
  }

  @Test func nonWebLinksAreIgnored() {
    #expect(AskCatbirdLinkRegistry.links(in: "mailto:a@example.com at://did:plc:x/app.bsky.feed.post/1").isEmpty)
  }
}

struct WebMarkdownConverterTests {
  private let base = URL(string: "https://example.com/news/story")!

  @Test func articleBodyBecomesMarkdownWithoutPageChrome() {
    let html = """
    <html><head><title>Big &amp; Bold</title>
    <meta name="description" content="A summary.">
    <meta property="og:site_name" content="Example News">
    <meta name="author" content="Ada">
    <script>alert('x')</script><style>p{}</style></head>
    <body><nav><a href="/">Home</a></nav><header>Site header</header>
    <article><h1>Headline</h1><p>First <strong>bold</strong> and <em>soft</em> words with a
    <a href="/related">related story</a>.</p>
    <ul><li>One</li><li>Two<ul><li>Nested</li></ul></li></ul>
    <ol start="3"><li>Third</li><li>Fourth</li></ol>
    <blockquote><p>Quoted line</p></blockquote>
    <pre><code>let x = 1
    let y = 2</code></pre>
    <img src="a.png" alt="A chart"><p>Price &lt; 5 &mdash; really &#8220;cheap&#x201D;</p>
    <p>Padding text so the article is clearly the main content of this page for selection purposes.</p>
    <p>More padding text so the article is clearly the main content of this page for selection.</p>
    </article><aside>Sidebar ad</aside><footer>Footer links</footer>
    <div hidden>Hidden text</div></body></html>
    """
    let page = WebMarkdownConverter.convert(html: html, baseURL: base)
    #expect(page.title == "Big & Bold")
    #expect(page.description == "A summary.")
    #expect(page.siteName == "Example News")
    #expect(page.author == "Ada")
    let md = page.markdown
    #expect(md.contains("# Headline"))
    #expect(md.contains("**bold**"))
    #expect(md.contains("*soft*"))
    #expect(md.contains("[related story](https://example.com/related)"))
    #expect(md.contains("- One"))
    #expect(md.contains("  - Nested"))
    #expect(md.contains("3. Third"))
    #expect(md.contains("4. Fourth"))
    #expect(md.contains("> Quoted line"))
    #expect(md.contains("```\nlet x = 1"))
    #expect(md.contains("[Image: A chart]"))
    #expect(md.contains("Price < 5 — really “cheap”"))
    for chrome in ["alert", "Home", "Site header", "Sidebar ad", "Footer links", "p{}"] {
      #expect(!md.contains(chrome), "Page chrome leaked: \(chrome)")
    }
  }

  @Test func tablesBecomeMarkdownTables() {
    let html = "<body><table><tr><th>Name</th><th>Score</th></tr><tr><td>Ada</td><td>9</td></tr></table></body>"
    let md = WebMarkdownConverter.convert(html: html, baseURL: base).markdown
    #expect(md.contains("| Name | Score |"))
    #expect(md.contains("| --- | --- |"))
    #expect(md.contains("| Ada | 9 |"))
  }

  @Test func unsafeLinkSchemesAreNotRendered() {
    let html = ##"<body><p><a href="javascript:steal()">click</a> <a href="#top">top</a></p></body>"##
    let md = WebMarkdownConverter.convert(html: html, baseURL: base).markdown
    #expect(!md.contains("javascript"))
    #expect(md.contains("click"))
    #expect(!md.contains("](#top)"))
  }

  @Test func quotedAttributeValuesMayContainAngleBrackets() {
    let html = ##"<body><p data-mw='{"parts":[{"template":"<ref>x</ref>"}]}' title="a > b">Visible text</p><svg data-x="1>2"></body>"##
    let md = WebMarkdownConverter.convert(html: html, baseURL: base).markdown
    #expect(md == "Visible text")
  }

  @Test func repeatedImageMarkersCollapse() {
    let html = #"<body><p>Lead</p><picture><img alt="Skyline"><img alt="Skyline"></picture><img alt="Harbor"></body>"#
    let md = WebMarkdownConverter.convert(html: html, baseURL: base).markdown
    #expect(md.components(separatedBy: "[Image: Skyline]").count == 2)
    #expect(md.contains("[Image: Harbor]"))
  }

  @Test func plainTextIsNormalized() {
    let page = WebMarkdownConverter.convert(plainText: "Line one\r\n\r\n\r\n\r\nLine two  ")
    #expect(page.markdown == "Line one\n\nLine two")
  }

  @Test func charsetDeclarationsAreHonored() {
    let latin1 = Data([0x63, 0x61, 0x66, 0xE9])  // "café" in ISO-8859-1
    #expect(AskCatbirdWebReader.decode(latin1, declaredEncoding: "iso-8859-1") == "café")
    let meta = Data(#"<meta charset="windows-1252"><p>caf"#.utf8) + Data([0xE9])
    #expect(AskCatbirdWebReader.decode(meta, declaredEncoding: nil).hasSuffix("café"))
    #expect(AskCatbirdWebReader.decode(Data("naïve".utf8), declaredEncoding: nil) == "naïve")
  }
}

struct CopilotRoutePreferenceTests {
  @Test func routeIsStoredPerAccountAndDefaultsToOnDevice() throws {
    let suite = "blue.catbird.tests.AskCatbirdRoutePreference"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preference = CopilotRoutePreference(defaults: defaults)
    #expect(preference.route(for: "did:plc:a") == .onDevice)
    preference.setRoute(.privateCloudCompute, for: "did:plc:a")
    #expect(preference.route(for: "did:plc:a") == .privateCloudCompute)
    #expect(preference.route(for: "did:plc:b") == .onDevice)
    preference.setRoute(.onDevice, for: "did:plc:a")
    #expect(preference.route(for: "did:plc:a") == .onDevice)
    preference.setRoute(.privateCloudCompute, for: "")
    #expect(preference.route(for: "") == .onDevice)
  }
}

struct AskCatbirdInstructionsTests {
  @Test func everyRouteKeepsTheTrustBoundaryAndResearchMethod() {
    for route in [CopilotModelRoute.onDevice, .privateCloudCompute] {
      let text = AskCatbirdInstructions.text(skill: .general, route: route, hasTools: true)
      #expect(text.contains(CopilotPrompt.sourceBoundary))
      #expect(text.contains("research, then explain"))
      #expect(text.contains("propose_action"))
    }
  }

  @Test func onDeviceInstructionsAreShorterForTheSmallContextWindow() {
    let device = AskCatbirdInstructions.text(skill: .factCheck, route: .onDevice, hasTools: true)
    let cloud = AskCatbirdInstructions.text(skill: .factCheck, route: .privateCloudCompute, hasTools: true)
    #expect(device.count < cloud.count)
  }

  @Test func skillsAddTheirTaskApproach() {
    for skill in CopilotTurnPlan.Skill.allCases where skill != .general {
      let text = AskCatbirdInstructions.text(skill: skill, route: .onDevice, hasTools: true)
      #expect(text.contains("Task approach"), "Missing approach for \(skill)")
    }
    let toolless = AskCatbirdInstructions.text(skill: .general, route: .onDevice, hasTools: false)
    #expect(!toolless.contains("Gather:"))
  }

  @Test func cloudErrorsExplainHowToContinue() {
    let errors: [CopilotCloudTurnError] = [
      .deviceNotEligible, .systemNotReady, .quotaReached(resetDate: nil),
      .quotaReached(resetDate: Date(timeIntervalSince1970: 2_000_000_000)),
      .networkFailure, .serviceUnavailable, .unsupportedLanguage
    ]
    for error in errors {
      #expect(error.errorDescription?.isEmpty == false)
    }
    #expect(CopilotCloudTurnError.quotaReached(resetDate: nil).isQuota)
    #expect(!CopilotCloudTurnError.networkFailure.isQuota)
  }
}
