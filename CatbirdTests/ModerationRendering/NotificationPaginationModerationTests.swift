import Foundation
import Petrel
import Testing

@testable import Catbird

// The notifications list paginates the groups the viewer sees. Groups the
// moderation policy filters are not in that list, so they can neither push the
// load-more trigger out of reach nor leave the list waiting on a page whose
// groups were all filtered (the official app's notification query keeps
// paginating until it has the items it wanted).

@Suite("Moderation rendering: notification pagination")
struct NotificationPaginationModerationTests {
  private typealias F = RenderingFixtures
  private typealias Notification = AppBskyNotificationListNotifications.Notification
  private typealias Output = AppBskyNotificationListNotifications.Output

  private static let adultOff = F.policy(adult: false)

  /// Counts the pages a view model requested, by cursor.
  private actor RequestLog {
    var cursors: [String?] = []
    func record(_ cursor: String?) { cursors.append(cursor) }
  }

  private struct Fixture {
    let viewModel: NotificationsViewModel
    let requests: RequestLog
  }

  /// A view model whose pages come from `pages`, keyed by the cursor that
  /// requests them (`nil` for the first page).
  private func fixture(pages: [String?: Output], policy: ModerationPolicy = adultOff) -> Fixture {
    let requests = RequestLog()
    let viewModel = NotificationsViewModel(
      client: nil, moderationPolicy: policy,
      pageLoader: { _, cursor in
        await requests.record(cursor)
        return (200, pages[cursor])
      })
    return Fixture(viewModel: viewModel, requests: requests)
  }

  /// A mention from `did:web:<name>.test`; `filtered` authors carry a porn
  /// account label, which adult-off filters from lists unless followed.
  private func mention(_ name: String, filtered: Bool, at offset: TimeInterval) throws -> Notification {
    let did = "did:web:\(name).test"
    let labels = filtered ? [try F.accountLabel("porn", did: did)] : nil
    let author = AppBskyActorDefs.ProfileView(
      did: try DID(didString: did), handle: try Handle(handleString: "\(name).test"), displayName: name, labels: labels)
    let uri = "at://\(did)/app.bsky.feed.post/mention"
    return Notification(
      uri: try ATProtocolURI(uriString: uri), cid: CID.fromDAGCBOR(Data(uri.utf8)), author: author, reason: "mention",
      record: .object([:]), isRead: false,
      indexedAt: ATProtocolDate(date: Date(timeIntervalSince1970: 1_700_000_000 - offset)))
  }

  /// `visible` plain mentions followed by `filtered` ones, each its own group.
  private func page(_ tag: String, visible: Int, filtered: Int, cursor: String?) throws -> Output {
    var notifications: [Notification] = []
    for index in 0..<visible {
      notifications.append(try mention("\(tag)-plain-\(index)", filtered: false, at: Double(index)))
    }
    for index in 0..<filtered {
      notifications.append(try mention("\(tag)-adult-\(index)", filtered: true, at: Double(visible + index)))
    }
    return Output(cursor: cursor, notifications: notifications)
  }

  @Test("Rows near the end of the visible list request the next page, however many filtered groups were loaded")
  func visibleRowsTriggerLoadMore() async throws {
    let fixture = try fixture(pages: [
      nil: try page("one", visible: 6, filtered: 6, cursor: "two"),
      "two": try page("two", visible: 3, filtered: 0, cursor: nil)
    ])
    let viewModel = fixture.viewModel
    await viewModel.loadNotifications()

    #expect(viewModel.groupedNotifications.count == 6, "the six filtered groups are not part of the list")
    #expect(viewModel.hasMoreNotifications)
    #expect(await fixture.requests.cursors == [nil], "six visible groups fill the screen; no extra page yet")

    let lastVisible = viewModel.groupedNotifications.count - 1
    #expect(viewModel.shouldLoadMore(afterShowingIndex: lastVisible), "the last visible row requests the next page")
    #expect(viewModel.shouldLoadMore(afterShowingIndex: lastVisible - NotificationsViewModel.pageLookahead + 1))
    #expect(!viewModel.shouldLoadMore(afterShowingIndex: 0))

    await viewModel.loadMoreNotifications()
    #expect(viewModel.groupedNotifications.count == 9)
    #expect(!viewModel.hasMoreNotifications)
    #expect(await fixture.requests.cursors == [nil, "two"])

    // A looser policy brings the loaded groups back without a request.
    viewModel.moderationPolicy = F.policy(labels: ["porn": "warn"])
    #expect(viewModel.groupedNotifications.count == 15)
    #expect(await fixture.requests.cursors == [nil, "two"])
  }

  @Test("A page whose groups are all filtered is followed by the next page in the same load")
  func filteredPageDoesNotStall() async throws {
    let fixture = try fixture(pages: [
      nil: try page("one", visible: 6, filtered: 0, cursor: "two"),
      "two": try page("two", visible: 0, filtered: 10, cursor: "three"),
      "three": try page("three", visible: 4, filtered: 0, cursor: nil)
    ])
    let viewModel = fixture.viewModel
    await viewModel.loadNotifications()
    #expect(viewModel.groupedNotifications.count == 6)

    await viewModel.loadMoreNotifications()
    #expect(viewModel.groupedNotifications.count == 10, "the filtered page is followed by the one after it")
    #expect(!viewModel.hasMoreNotifications)
    #expect(!viewModel.isLoadingMore)
    #expect(await fixture.requests.cursors == [nil, "two", "three"])
  }

  @Test("A run of filtered pages stops at the page limit and keeps the next cursor")
  func filteredRunStopsAtLimit() async throws {
    var pages: [String?: Output] = [nil: try page("one", visible: 6, filtered: 0, cursor: "p1")]
    for index in 1...12 {
      pages["p\(index)"] = try page("p\(index)", visible: 0, filtered: 5, cursor: "p\(index + 1)")
    }
    let fixture = try fixture(pages: pages)
    let viewModel = fixture.viewModel
    await viewModel.loadNotifications()

    await viewModel.loadMoreNotifications()
    #expect(viewModel.groupedNotifications.count == 6)
    #expect(viewModel.hasMoreNotifications, "the viewer can ask for more; the cursor chain is intact")
    #expect(await fixture.requests.cursors.count == 1 + NotificationsViewModel.autoPaginationPageLimit)
  }

  @Test("When every loaded group is filtered the list is empty while more pages remain, so the empty state offers Load More")
  func allFilteredLeavesEmptyListWithMore() async throws {
    var pages: [String?: Output] = [nil: try page("one", visible: 0, filtered: 10, cursor: "p1")]
    for index in 1...6 {
      pages["p\(index)"] = try page("p\(index)", visible: 0, filtered: 10, cursor: "p\(index + 1)")
    }
    let fixture = try fixture(pages: pages)
    let viewModel = fixture.viewModel
    await viewModel.loadNotifications()

    #expect(viewModel.groupedNotifications.isEmpty)
    #expect(viewModel.hasMoreNotifications)
    #expect(!viewModel.isLoading && !viewModel.isLoadingMore)
    #expect(await fixture.requests.cursors == [nil, "p1", "p2", "p3"], "the first load follows three more pages, then stops")
  }

  @Test("A first page short of five visible groups is topped up from the next page")
  func firstLoadFillsTheScreen() async throws {
    let fixture = try fixture(pages: [
      nil: try page("one", visible: 2, filtered: 8, cursor: "two"),
      "two": try page("two", visible: 5, filtered: 0, cursor: "three"),
      "three": try page("three", visible: 5, filtered: 0, cursor: nil)
    ])
    let viewModel = fixture.viewModel
    await viewModel.loadNotifications()
    #expect(viewModel.groupedNotifications.count == 7)
    #expect(viewModel.hasMoreNotifications)
    #expect(await fixture.requests.cursors == [nil, "two"])
  }
}
