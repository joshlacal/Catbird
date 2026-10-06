import Foundation
import Petrel
import Testing
@testable import Catbird

@Suite("Profile labels and Germ")
struct ProfileLabelAndGermTests {
  private let owner = "did:plc:profileowner123456789"
  private let viewer = "did:plc:viewer123456789012"
  private let issuer = "did:plc:labeler123456789012"

  private func action(
    policy: String = "everyone", url: String = "https://landing.ger.mx/newUser?token=public",
    followedBy: Bool = false, blocked: Bool = false, loadedFor: String? = nil,
    profileDID: String? = nil, viewerDID: String? = nil
  ) -> GermProfileAction? {
    GermProfileAction.make(
      metadata: .init(messageMeUrl: URI(uriString: url), showButtonTo: policy),
      profileDID: profileDID ?? owner, viewerDID: viewerDID ?? viewer,
      loadedForViewerDID: loadedFor ?? viewer,
      profileFollowsViewer: followedBy, isBlocked: blocked
    )
  }

  @Test("Germ preserves path/query and puts recipient then viewer in the fragment")
  func germLink() {
    #expect(action()?.url.absoluteString == "https://landing.ger.mx/newUser/iOS?token=public#\(owner)+\(viewer)")
    #expect(action(url: "https://landing.ger.mx/newUser/")?.url.path == "/newUser/iOS")
    #expect(action(url: "https://custom.example/invitation")?.url.host() == "custom.example")
  }

  @Test("Germ preserves escaped path octets and the original query")
  func germEscapedPath() {
    let result = action(url: "https://custom.example/invite%2Ftoken/a%3Fb/%25?key=x%2Fy&percent=%25")
    #expect(result?.url.absoluteString == "https://custom.example/invite%2Ftoken/a%3Fb/%25/iOS?key=x%2Fy&percent=%25#\(owner)+\(viewer)")
  }

  @Test("Restricted Germ action depends on profile owner following viewer")
  func germFollowDirection() {
    #expect(action(policy: "usersIFollow", followedBy: false) == nil)
    #expect(action(policy: "usersIFollow", followedBy: true) != nil)
    #expect(action(policy: "everyone", followedBy: false) != nil)
  }

  @Test("No action for absent metadata, disabled/unknown visibility, own profile, blocking, or stale viewer")
  func germEligibility() {
    #expect(action(policy: "none") == nil)
    #expect(action(policy: "future-policy", followedBy: true) == nil)
    #expect(action(blocked: true) == nil)
    #expect(action(profileDID: viewer) == nil)
    #expect(action(loadedFor: "did:plc:otheraccount123456789") == nil)
    #expect(action(viewerDID: "") == nil)
    #expect(GermProfileAction.make(metadata: nil, profileDID: owner, viewerDID: viewer,
      loadedForViewerDID: viewer, profileFollowsViewer: true, isBlocked: false) == nil)
  }

  @Test("Malformed or unsafe links and preexisting fragments are omitted", arguments: [
    "https://landing.ger.mx/invite#old", "https://landing.ger.mx/invite#", "http://landing.ger.mx/invite",
    "javascript:alert(1)", "germ://invite", "https://user:secret@landing.ger.mx/invite", "/relative", "not a url"
  ])
  func germMalformedLink(_ url: String) { #expect(action(url: url) == nil) }

  @Test("DID delimiters are encoded without losing identity")
  func germDIDEncoding() {
    let did = "did:web:host.example:user%2Bname"
    let result = action(profileDID: did)
    #expect(result?.url.absoluteString.contains("user%252Bname+\(viewer)") == true)
  }

  private func strings(_ language: String, _ name: String) -> ComAtprotoLabelDefs.LabelValueDefinitionStrings {
    .init(lang: LanguageCodeContainer(lang: Locale.Language(identifier: language)), name: name, description: "Description for \(name)")
  }

  @Test("Label locale resolution selects exact, base, English, then available locale")
  func localizedLabel() {
    let locales = [strings("en", "Joined May 23"), strings("fr", "Inscrit le 23 mai")]
    #expect(AccountLabelPresentation.localizedStrings(locales, preferredLanguages: ["fr-CA"])?.name == "Inscrit le 23 mai")
    #expect(AccountLabelPresentation.localizedStrings(locales, preferredLanguages: ["de"])?.name == "Joined May 23")
    #expect(AccountLabelPresentation.localizedStrings([strings("fr", "Inscrit")], preferredLanguages: ["de"])?.name == "Inscrit")
    #expect(AccountLabelPresentation.localizedStrings([], preferredLanguages: ["en"]) == nil)
  }

  @Test("Informational custom labels show the labeler's published name and issuer")
  func informationalLabel() throws {
    let label = try makeLabel(subject: owner)
    let labeler = try makeLabeler()
    let display = AccountLabelPresentation(label: label, labeler: labeler, preferredLanguages: ["en-US"])
    #expect(display.name == "Joined May 23")
    #expect(display.description == "Account join date")
    #expect(display.issuer == "Date Labeler (@dates.example)")
    #expect(display.severity == .information)
  }

  @Test("Account count excludes other subjects, expired labels, unsubscribed issuers, and duplicates")
  func accountLabelCount() throws {
    let label = try makeLabel(subject: owner)
    let expired = try makeLabel(subject: owner, value: "expired", expiration: Date(timeIntervalSince1970: 1))
    let other = try makeLabel(subject: viewer)
    let values = [label, label, expired, other]
    #expect(AccountLabelPresentation.accountLabels(values, subjectDID: owner, subscribedIssuers: [issuer]).count == 1)
    #expect(AccountLabelPresentation.accountLabels(values, subjectDID: owner, subscribedIssuers: []).isEmpty)
    #expect(ReportingService.canAppeal(label, viewerDID: viewer) == false)
    #expect(ReportingService.canAppeal(label, viewerDID: owner))
  }

  @Test("Profile record labels and self labels are counted, unrelated posts are excluded")
  func profileRecordLabels() throws {
    let profileURI = "at://\(owner)/app.bsky.actor.profile/self"
    let cid = try CID.parse("bafyreihyrnm3tmsrqwuk74vffv4s6gq52l7q3b2uyd4zfv3i6v6a5z3z4u")
    let profileLabel = ComAtprotoLabelDefs.Label(src: try DID(didString: issuer), uri: URI(uriString: profileURI), cid: cid,
      val: "joined-may-23", cts: ATProtocolDate(date: Date()))
    let selfLabel = ComAtprotoLabelDefs.Label(src: try DID(didString: owner), uri: URI(uriString: profileURI),
      val: "bot", cts: ATProtocolDate(date: Date()))
    let postLabel = try makeLabel(subject: "at://\(owner)/app.bsky.feed.post/3k6wuby6vls2u")
    let labels = AccountLabelPresentation.accountLabels([profileLabel, selfLabel, postLabel], subjectDID: owner, subscribedIssuers: [issuer])
    #expect(labels.count == 2)
    #expect(ReportingService.canAppeal(profileLabel, viewerDID: owner))
    #expect(!ReportingService.canAppeal(profileLabel, viewerDID: viewer))
    #expect(!ReportingService.canAppeal(selfLabel, viewerDID: owner))
    #expect(ReportingService.subjectOwnerDID(selfLabel) == owner)
    #expect(AccountLabelPresentation.accountLabels([profileLabel], subjectDID: viewer, subscribedIssuers: [issuer]).isEmpty)
  }

  private func makeLabel(subject: String, value: String = "joined-may-23", expiration: Date? = nil) throws -> ComAtprotoLabelDefs.Label {
    .init(src: try DID(didString: issuer), uri: URI(uriString: subject), val: value,
      cts: ATProtocolDate(date: Date()), exp: expiration.map(ATProtocolDate.init(date:)))
  }

  private func makeLabeler() throws -> AppBskyLabelerDefs.LabelerViewDetailed {
    .init(
      uri: try ATProtocolURI(uriString: "at://\(issuer)/app.bsky.labeler.service/self"),
      cid: try CID.parse("bafyreihyrnm3tmsrqwuk74vffv4s6gq52l7q3b2uyd4zfv3i6v6a5z3z4u"),
      creator: .init(did: try DID(didString: issuer), handle: try Handle(handleString: "dates.example"), displayName: "Date Labeler"),
      policies: .init(labelValues: [.init(rawValue: "joined-may-23")], labelValueDefinitions: [
        .init(identifier: "joined-may-23", severity: "inform", blurs: "none", locales: [
          .init(lang: LanguageCodeContainer(lang: Locale.Language(identifier: "en")), name: "Joined May 23", description: "Account join date")
        ])
      ]), indexedAt: ATProtocolDate(date: Date())
    )
  }
}

@Suite("Profile label header refresh")
struct ProfileLabelRefreshTests {
  @Test("Only the applied-header event from this account's preferences owner triggers refresh")
  func accountScopedRefresh() {
    let preferences = NSObject()
    let otherPreferences = NSObject()
    let viewer = "did:plc:viewer123456789012"
    let applied = Notification(name: ProfileLabelRefresh.notificationName, object: preferences,
      userInfo: ["accountDID": viewer, "labelerDIDs": ["did:plc:labeler123456789012"]])
    #expect(ProfileLabelRefresh.matches(applied, preferencesManager: preferences, viewerDID: viewer, isActiveViewer: true))
    #expect(!ProfileLabelRefresh.matches(applied, preferencesManager: otherPreferences, viewerDID: viewer, isActiveViewer: true))
    #expect(!ProfileLabelRefresh.matches(applied, preferencesManager: preferences, viewerDID: "did:plc:other123456789012", isActiveViewer: true))
    #expect(!ProfileLabelRefresh.matches(applied, preferencesManager: preferences, viewerDID: viewer, isActiveViewer: false))
  }

  @Test("Incomplete or unrelated notifications cannot trigger an early profile fetch")
  func requiresAppliedHeaderPayload() {
    let preferences = NSObject()
    let viewer = "did:plc:viewer123456789012"
    let early = Notification(name: ProfileLabelRefresh.notificationName, object: preferences, userInfo: ["accountDID": viewer])
    let unrelated = Notification(name: Notification.Name("PreferencesDidChange"), object: preferences,
      userInfo: ["accountDID": viewer, "labelerDIDs": [] as [String]])
    #expect(!ProfileLabelRefresh.matches(early, preferencesManager: preferences, viewerDID: viewer, isActiveViewer: true))
    #expect(!ProfileLabelRefresh.matches(unrelated, preferencesManager: preferences, viewerDID: viewer, isActiveViewer: true))
  }
}
