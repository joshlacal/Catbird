import XCTest
@testable import Catbird
import Petrel

final class LiveEventServiceTests: XCTestCase {

    // MARK: - Mock URLProtocol

    final class MockURLProtocol: URLProtocol {
        static var stubbedData: Data?
        static var stubbedResponse: HTTPURLResponse?
        static var stubbedError: Error?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            if let error = Self.stubbedError {
                client?.urlProtocol(self, didFailWithError: error)
            } else {
                if let response = Self.stubbedResponse {
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                }
                if let data = Self.stubbedData {
                    client?.urlProtocol(self, didLoad: data)
                }
                client?.urlProtocolDidFinishLoading(self)
            }
        }

        override func stopLoading() {}
    }

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        MockURLProtocol.stubbedData = nil
        MockURLProtocol.stubbedResponse = nil
        MockURLProtocol.stubbedError = nil
        session = nil
        super.tearDown()
    }

    // MARK: - Active Events Filtering

    @MainActor
    func testActiveEventsFiltering() async throws {
        let jsonString = """
        {
            "feeds": [
                {
                    "id": "feed-1",
                    "preview": false,
                    "title": "Super Bowl Live",
                    "url": "https://bsky.app/profile/did:plc:1/feed/superbowl",
                    "layouts": {
                        "wide": {
                            "title": "Super Bowl 2026",
                            "image": "https://example.com/banner.jpg"
                        }
                    }
                },
                {
                    "id": "feed-2",
                    "preview": true,
                    "title": "Internal Preview Event",
                    "url": "https://bsky.app/profile/did:plc:1/feed/preview"
                },
                {
                    "id": "feed-3",
                    "preview": false,
                    "title": "Tech Conference Live",
                    "url": "https://bsky.app/profile/did:plc:1/feed/tech"
                }
            ]
        }
        """

        MockURLProtocol.stubbedData = jsonString.data(using: .utf8)
        MockURLProtocol.stubbedResponse = HTTPURLResponse(
            url: URL(string: "https://live-events.workers.bsky.app/config")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )

        let service = LiveEventService(urlSession: session)
        await service.fetchLiveEvents(force: true)

        // Raw feeds has 3 items
        XCTAssertEqual(service.rawFeeds.count, 3)

        // Active events filters out preview feed (feed-2), so only 2 items remain
        XCTAssertEqual(service.activeEvents.count, 2)
        XCTAssertEqual(service.activeEvents.map(\.id), ["feed-1", "feed-3"])
    }

    @MainActor
    func testHideEventAndHideAll() async throws {
        let feed1 = LiveEventFeed(id: "feed-1", preview: false, title: "Event 1", url: "https://bsky.app/feed/1")
        let feed2 = LiveEventFeed(id: "feed-2", preview: false, title: "Event 2", url: "https://bsky.app/feed/2")

        let service = LiveEventService(urlSession: session)
        MockURLProtocol.stubbedData = try JSONEncoder().encode(LiveEventsWorkerResponse(feeds: [feed1, feed2]))
        MockURLProtocol.stubbedResponse = HTTPURLResponse(
            url: URL(string: "https://live-events.workers.bsky.app/config")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )

        await service.fetchLiveEvents(force: true)
        XCTAssertEqual(service.activeEvents.count, 2)

        // Hide feed-1 locally
        try? await service.hideEvent(id: "feed-1")
        XCTAssertEqual(service.activeEvents.count, 1)
        XCTAssertEqual(service.activeEvents.first?.id, "feed-2")

        // Undo
        try? await service.undoLastHide()
        XCTAssertEqual(service.activeEvents.count, 2)

        // Hide all
        try? await service.hideAllEvents()
        XCTAssertTrue(service.activeEvents.isEmpty)
    }

    @MainActor
    func testFiveMinuteThrottling() async {
        let service = LiveEventService(urlSession: session)
        MockURLProtocol.stubbedData = "{\"feeds\": []}".data(using: .utf8)
        MockURLProtocol.stubbedResponse = HTTPURLResponse(
            url: URL(string: "https://live-events.workers.bsky.app/config")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )

        await service.fetchLiveEvents(force: true)
        let firstFetchDate = service.lastFetchDate
        XCTAssertNotNil(firstFetchDate)

        // Calling fetch again without force within 5 minutes should skip fetch
        await service.fetchLiveEvents(force: false)
        XCTAssertEqual(service.lastFetchDate, firstFetchDate)
    }
}
