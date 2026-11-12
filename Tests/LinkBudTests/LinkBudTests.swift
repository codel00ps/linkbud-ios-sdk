import Foundation
import XCTest
@testable import LinkBud

final class MemoryStorage: StateStorage, @unchecked Sendable {
    var data: Data?
    var fails = false
    func read() throws -> Data? { data }
    func write(_ data: Data) throws {
        if fails { throw CocoaError(.fileWriteUnknown) }
        self.data = data
    }
}
final class Clock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}
final class MockTransport: Transport, @unchecked Sendable {
    var status = 200
    var retryAfter: TimeInterval = 0
    var offline = false
    var json: [String: Any] = [:]
    var bodies: [[String: String]] = []
    var paths: [String] = []
    var onResponse: (() -> Void)?
    func post(origin: URL, path: String, body: [String: String]) async throws -> APIResponse {
        bodies.append(body); paths.append(path)
        onResponse?()
        if offline { throw URLError(.notConnectedToInternet) }
        return APIResponse(status: status, data: try JSONSerialization.data(withJSONObject: json), retryAfter: retryAfter)
    }
}

actor HeldTransport: Transport {
    private var response: CheckedContinuation<APIResponse, Never>?
    private var start: CheckedContinuation<Void, Never>?
    func post(origin: URL, path: String, body: [String: String]) async throws -> APIResponse {
        await withCheckedContinuation { continuation in
            response = continuation
            start?.resume(); start = nil
        }
    }
    func waitUntilStarted() async {
        if response != nil { return }
        await withCheckedContinuation { start = $0 }
    }
    func release(_ data: Data) { response?.resume(returning: APIResponse(status: 200, data: data)); response = nil }
}

final class LinkBudTests: XCTestCase {
    func testURLOwnershipMatchesSharedPlatformVectors() throws {
        struct Vector: Decodable { let url: String; let accepted: Bool }
        let path = try XCTUnwrap(Bundle.module.url(forResource: "link-url-vectors", withExtension: "json", subdirectory: "Fixtures"))
        let vectors = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: path))
        let configuration = try shortConfig()
        for vector in vectors {
            let url = try XCTUnwrap(URL(string: vector.url))
            XCTAssertEqual(configuration.canHandle(url: url), vector.accepted, vector.url)
        }
        XCTAssertFalse(try config().canHandle(url: URL(string: "https://links.example.com/Ab1/Cd34Ef")!))
    }

    func testReopenedJourneySurvivesRestartAndKeepsDuplicateProtection() async throws {
        let (sdk, storage, transport, clock) = try setup()
        guard case .pending(let original) = await sdk.handle(url: link()) else { return XCTFail() }
        let firstSaved = await sdk.acknowledge(id: original.id)
        XCTAssertTrue(firstSaved)
        transport.offline = true
        guard case .retryable(let retryAt) = await sdk.reopen(url: link()) else { return XCTFail() }
        let eventID = transport.bodies.last?["event_id"]
        XCTAssertNotEqual(transport.bodies.first?["event_id"], eventID)
        let restarted = try LinkBud(configuration: config(), storage: storage, transport: transport, now: { clock.date })
        transport.offline = false
        let early = await restarted.resume()
        XCTAssertEqual(early, .retryable(retryAt: retryAt))
        XCTAssertEqual(transport.bodies.count, 2)
        clock.date = retryAt
        guard case .pending(let reopened) = await restarted.resume() else { return XCTFail() }
        XCTAssertNotEqual(original.id, reopened.id)
        XCTAssertEqual(transport.bodies.last?["event_id"], eventID)
        let collision = await restarted.reopen(url: link())
        XCTAssertEqual(collision, .rejected(reason: "pending_destination_exists"))
        let duplicate = await restarted.handle(url: link())
        XCTAssertEqual(duplicate, .alreadyAcknowledged)
        let saved = await restarted.acknowledge(id: reopened.id)
        XCTAssertTrue(saved)
        transport.status = 410
        let unavailable = await restarted.reopen(url: link())
        XCTAssertEqual(unavailable, .rejected(reason: "http_410"))
        let pending = await restarted.pending()
        XCTAssertEqual(pending, .empty)
        let invalid = await restarted.reopen(url: URL(string: link().absoluteString + "?extra=value")!)
        XCTAssertEqual(invalid, .rejected(reason: "invalid_link"))
    }

    func testDefaultIsTheOnlySupportedEnvironment() throws {
        let configuration = try config()
        XCTAssertEqual(try configuration.slug(link()), slug)
        for retired in ["testing", "live", "development", "production", "staging"] {
            XCTAssertThrowsError(try LinkBudConfiguration(origin: configuration.origin, applicationID: app, environment: retired, sdkID: sdk, appleAppID: configuration.appleAppID))
            XCTAssertThrowsError(try configuration.slug(URL(string: "https://links.example.com/l/\(app)/\(retired)/\(slug)")!))
        }
    }

    let app = String(repeating: "a", count: 26)
    let sdk = String(repeating: "b", count: 26)
    let slug = "AbCdEf0123456789"
    let code = String(repeating: "A", count: 24)
    func config(_ origin: String = "https://links.example.com") throws -> LinkBudConfiguration {
        try LinkBudConfiguration(origin: URL(string: origin)!, applicationID: app, environment: "default", sdkID: sdk, appleAppID: "A1B2C3D4E5.dev.linkbud.test")
    }
    func link() -> URL { URL(string: "https://links.example.com/l/\(app)/default/\(slug)")! }
    func payload(_ clock: Clock) -> [String: Any] {
        ["version": 1, "sdk_id": sdk, "application_id": app, "environment": "default", "slug": slug,
         "destination": "/welcome?source=share", "expires_at": NSNull(), "resolved_at": ISO8601DateFormatter().string(from: clock.date),
         "recovery_expires_at": ISO8601DateFormatter().string(from: clock.date.addingTimeInterval(1800))]
    }
    func setup() throws -> (LinkBud, MemoryStorage, MockTransport, Clock) {
        let storage = MemoryStorage(), transport = MockTransport(), clock = Clock()
        transport.json = payload(clock)
        let sdk = try LinkBud(configuration: config(), storage: storage, transport: transport, now: { clock.date })
        return (sdk, storage, transport, clock)
    }
    func testAnalyticsIDPersistsAcrossLostResponseRestartAndRevalidation() async throws {
        let (sdk, storage, transport, clock) = try setup()
        transport.offline = true
        guard case .retryable(let retryAt) = await sdk.handle(url: link()) else { return XCTFail() }
        let id = transport.bodies.first?["event_id"]
        XCTAssertEqual(id?.count, 64)
        XCTAssertEqual(transport.bodies.first?["platform"], "ios")
        XCTAssertNil(transport.bodies.first?["installation_id"])
        clock.date = retryAt; transport.offline = false
        let restarted = try LinkBud(configuration: config(), storage: storage, transport: transport, now: { clock.date })
        guard case .pending = await restarted.resume() else { return XCTFail() }
        guard case .pending = await restarted.resume() else { return XCTFail() }
        XCTAssertEqual(transport.bodies.count, 3)
        XCTAssertTrue(transport.bodies.allSatisfy { $0["event_id"] == id })
    }
    func testStoredJourneyFromBeforeAnalyticsRemainsReadable() async throws {
        let (sdk, storage, transport, clock) = try setup()
        _ = await sdk.handle(url: link())
        var json = try JSONSerialization.jsonObject(with: storage.data!) as! [String: Any]
        var request = json["request"] as! [String: Any]
        request.removeValue(forKey: "eventID"); json["request"] = request
        storage.data = try JSONSerialization.data(withJSONObject: json)
        let restarted = try LinkBud(configuration: config(), storage: storage, transport: transport, now: { clock.date })
        guard case .pending = await restarted.resume() else { return XCTFail() }
        XCTAssertEqual(transport.bodies.last?["event_id"]?.count, 64)
    }
    func testOriginAndURLBoundaries() throws {
        for origin in ["http://links.example.com", "https://u:p@links.example.com", "https://links.example.com:443", "https://links.example.com/path", "https://links.example.com?x=1"] {
            XCTAssertThrowsError(try config(origin))
        }
        let config = try config()
        XCTAssertEqual(try config.slug(link()), slug)
        for url in ["https://other.example/l/\(app)/default/\(slug)",
                    "https://links.example.com/l/\(app)/production/\(slug)",
                    link().absoluteString + "?x=1", link().absoluteString + "/", link().absoluteString + "#fragment",
                    "https://links.example.com/l/\(app)/default/%41bCdEf0123456789"] {
            XCTAssertThrowsError(try config.slug(URL(string: url)!))
        }
    }
    func testColdWarmResolutionAndAcknowledgment() async throws {
        let (sdk, _, transport, _) = try setup()
        let result = await sdk.handle(url: link())
        guard case .pending(let pending) = result else { return XCTFail("Expected pending") }
        XCTAssertEqual(pending.destination, "/welcome?source=share")
        let cached = await sdk.pending(); XCTAssertEqual(cached, result)
        let resumed = await sdk.resume(); XCTAssertEqual(resumed, result)
        let acknowledged = await sdk.acknowledge(id: pending.id); XCTAssertTrue(acknowledged)
        let duplicate = await sdk.handle(url: link()); XCTAssertEqual(duplicate, .alreadyAcknowledged)
        let empty = await sdk.resume(); XCTAssertEqual(empty, .empty)
        XCTAssertEqual(transport.paths, ["/api/v1/resolve", "/api/v1/resolve"])
    }
    func testExplicitReopenRevalidatesAndCreatesDistinctJourneyWithoutChangingDefaultDeduplication() async throws {
        let (sdk, _, transport, _) = try setup()
        guard case .pending(let first) = await sdk.handle(url: link()) else { return XCTFail("Expected first journey") }
        let acknowledged = await sdk.acknowledge(id: first.id)
        XCTAssertTrue(acknowledged)
        let duplicate = await sdk.handle(url: link())
        XCTAssertEqual(duplicate, .alreadyAcknowledged)
        guard case .pending(let reopened) = await sdk.reopen(url: link()) else { return XCTFail("Expected reopened journey") }
        XCTAssertNotEqual(first.id, reopened.id)
        XCTAssertEqual(first.destination, reopened.destination)
        XCTAssertNotEqual(transport.bodies[0]["event_id"], transport.bodies.last?["event_id"])
        let busy = await sdk.reopen(url: link())
        XCTAssertEqual(busy, .rejected(reason: "pending_destination_exists"))
    }

    func testExplicitReopenCannotBypassLinkAvailability() async throws {
        let (sdk, _, transport, _) = try setup()
        guard case .pending(let first) = await sdk.handle(url: link()) else { return XCTFail("Expected first journey") }
        _ = await sdk.acknowledge(id: first.id)
        transport.status = 410
        let unavailable = await sdk.reopen(url: link())
        XCTAssertEqual(unavailable, .rejected(reason: "http_410"))
        let pending = await sdk.pending()
        XCTAssertEqual(pending, .empty)
    }

    func testRestartLoginAndAcknowledgmentPersistence() async throws {
        let (sdk, storage, transport, clock) = try setup()
        let result = await sdk.handle(url: link())
        let restarted = try LinkBud(configuration: config(), storage: storage, transport: transport, now: { clock.date })
        let cached = await restarted.pending(); XCTAssertEqual(cached, result)
        let revalidated = await restarted.resume(); XCTAssertEqual(revalidated, result)
        guard case .pending(let pending) = revalidated else { return XCTFail() }
        let saved = await restarted.acknowledge(id: pending.id); XCTAssertTrue(saved)
        let third = try LinkBud(configuration: config(), storage: storage, transport: transport, now: { clock.date })
        let repeated = await third.handle(url: link()); XCTAssertEqual(repeated, .alreadyAcknowledged)
    }
    func testManualCodeNormalizationAndLostResponseRetryUsesStableInstallation() async throws {
        let (sdk, storage, transport, clock) = try setup()
        transport.offline = true
        let result = await sdk.recover(code: "aaaa-aaaa-aaaa-aaaa-aaaa-aaaa")
        guard case .retryable(let retryAt) = result else { return XCTFail() }
        XCTAssertEqual(transport.bodies.first?["code"], code)
        let installation = transport.bodies.first?["installation_id"]
        XCTAssertEqual(installation?.count, 64)
        let restarted = try LinkBud(configuration: config(), storage: storage, transport: transport, now: { clock.date })
        let early = await restarted.resume(); XCTAssertEqual(early, result)
        XCTAssertEqual(transport.bodies.count, 1)
        clock.date = retryAt; transport.offline = false
        guard case .pending = await restarted.resume() else { return XCTFail() }
        XCTAssertEqual(transport.bodies.last?["installation_id"], installation)
        XCTAssertEqual(transport.paths.last, "/api/v1/ios/recovery")
    }
    func testMalformedCodesNeverMakeNetworkRequests() async throws {
        let (sdk, _, transport, _) = try setup()
        for code in ["", "hello", String(repeating: "G", count: 24), "https://evil.example"] {
            let result = await sdk.recover(code: code); XCTAssertEqual(result, .rejected(reason: "invalid_recovery_code"))
        }
        XCTAssertTrue(transport.bodies.isEmpty)
    }
    func testNewJourneyCannotReplacePending() async throws {
        let (sdk, _, _, _) = try setup()
        let original = await sdk.handle(url: link())
        let result = await sdk.recover(code: code)
        XCTAssertEqual(result, .rejected(reason: "pending_destination_exists"))
        let cached = await sdk.pending(); XCTAssertEqual(cached, original)
    }
    func testDisabledRevalidationClearsPending() async throws {
        let (sdk, _, transport, _) = try setup()
        _ = await sdk.handle(url: link())
        transport.status = 410
        let result = await sdk.resume(); XCTAssertEqual(result, .rejected(reason: "http_410"))
        let cached = await sdk.pending(); XCTAssertEqual(cached, .empty)
    }
    func testRetryAfterBackoffSurvivesRestartAndStopsAtExpiry() async throws {
        let (sdk, storage, transport, clock) = try setup()
        transport.status = 429; transport.retryAfter = 60
        let result = await sdk.recover(code: code)
        guard case .retryable(let retryAt) = result else { return XCTFail() }
        XCTAssertEqual(retryAt.timeIntervalSince(clock.date), 60)
        let restarted = try LinkBud(configuration: config(), storage: storage, transport: transport, now: { clock.date })
        let early = await restarted.resume(); XCTAssertEqual(early, result)
        clock.date.addTimeInterval(1800)
        let expired = await restarted.resume(); XCTAssertEqual(expired, .rejected(reason: "request_expired"))
        XCTAssertEqual(transport.bodies.count, 1)
    }
    func testExponentialBackoffAndServerFailures() async throws {
        let (sdk, _, transport, clock) = try setup()
        transport.status = 503
        guard case .retryable(let first) = await sdk.handle(url: link()) else { return XCTFail() }
        XCTAssertEqual(first.timeIntervalSince(clock.date), 2)
        clock.date = first
        guard case .retryable(let second) = await sdk.resume() else { return XCTFail() }
        XCTAssertEqual(second.timeIntervalSince(clock.date), 4)
    }
    func testTerminalErrorsDoNotRouteOrRetry() async throws {
        for status in [301, 401, 404, 409, 410, 422] {
            let (sdk, _, transport, _) = try setup(); transport.status = status
            let result = await sdk.recover(code: code); XCTAssertEqual(result, .rejected(reason: "http_\(status)"))
            let resumed = await sdk.resume(); XCTAssertEqual(resumed, .empty)
        }
    }
    func testPayloadBoundariesAndUnsafePaths() async throws {
        for change: [String: Any] in [["version": true], ["sdk_id": app], ["application_id": sdk], ["environment": "staging"], ["version": 2],
                                     ["slug": "bad"], ["destination": "https://evil.example"], ["destination": "//evil"],
                                     ["destination": "/%2fexample"], ["destination": "/%5cpath"], ["destination": "/bad%20path"],
                                     ["destination": "/bad%00"], ["destination": String(repeating: "x", count: 2049)], ["resolved_at": "bad"]] {
            let (sdk, _, transport, _) = try setup()
            transport.json.merge(change) { _, new in new }
            guard case .rejected = await sdk.handle(url: link()) else { return XCTFail("Accepted invalid payload") }
        }
    }
    func testMissingExpiryAndMismatchedSlugRejected() async throws {
        for key in ["expires_at", "recovery_expires_at"] {
            let (sdk, _, transport, _) = try setup(); transport.json.removeValue(forKey: key)
            guard case .rejected = await sdk.recover(code: code) else { return XCTFail() }
        }
        let (sdk, _, transport, _) = try setup(); transport.json["slug"] = "0000000000000000"
        guard case .rejected = await sdk.handle(url: link()) else { return XCTFail() }
    }
    func testExpiryDuringResponseNeverBecomesPending() async throws {
        let (sdk, _, transport, clock) = try setup()
        transport.onResponse = { clock.date.addTimeInterval(1800) }
        guard case .rejected = await sdk.recover(code: code) else { return XCTFail() }
        let cached = await sdk.pending(); XCTAssertEqual(cached, .empty)
    }
    func testExpiredPendingCanBeReplacedAndCannotBeAcknowledged() async throws {
        let (sdk, _, transport, clock) = try setup()
        transport.json["expires_at"] = ISO8601DateFormatter().string(from: clock.date.addingTimeInterval(1))
        guard case .pending(let pending) = await sdk.handle(url: link()) else { return XCTFail() }
        clock.date.addTimeInterval(1)
        let saved = await sdk.acknowledge(id: pending.id); XCTAssertFalse(saved)
        transport.json = payload(clock)
        guard case .pending = await sdk.recover(code: code) else { return XCTFail() }
    }
    func testStorageFailureNeverRoutesAndCorruptStateFailsClosed() async throws {
        let (sdk, storage, transport, _) = try setup(); storage.fails = true
        let result = await sdk.handle(url: link()); XCTAssertEqual(result, .rejected(reason: "local_state_failure"))
        XCTAssertTrue(transport.bodies.isEmpty)
        let cached = await sdk.pending(); XCTAssertEqual(cached, result)
        storage.fails = false; storage.data = Data("corrupt".utf8)
        XCTAssertThrowsError(try LinkBud(configuration: config(), storage: storage, transport: transport, now: { Date() }))
    }
    func testAcknowledgmentHistoryIsBounded() async throws {
        let (sdk, storage, transport, _) = try setup()
        for index in 0..<65 {
            let slug = String(format: "%016d", index)
            transport.json["slug"] = slug
            let url = URL(string: "https://links.example.com/l/\(app)/default/\(slug)")!
            guard case .pending(let pending) = await sdk.handle(url: url) else { return XCTFail() }
            let saved = await sdk.acknowledge(id: pending.id); XCTAssertTrue(saved)
        }
        let state = try JSONDecoder().decode(StoredState.self, from: XCTUnwrap(storage.data))
        XCTAssertEqual(state.acknowledged.count, 64)
        XCTAssertNil(state.pending)
        XCTAssertNil(state.request)
    }
    func testFailureToPersistResponsePreventsNavigation() async throws {
        let (sdk, storage, transport, _) = try setup()
        transport.onResponse = { storage.fails = true }
        let result = await sdk.handle(url: link())
        XCTAssertEqual(result, .rejected(reason: "local_state_failure"))
        let cached = await sdk.pending(); XCTAssertEqual(cached, result)
    }
    func testConcurrentInputDoesNotOverwriteInFlightJourney() async throws {
        let storage = MemoryStorage(), transport = HeldTransport(), clock = Clock()
        let sdk = try LinkBud(configuration: config(), storage: storage, transport: transport, now: { clock.date })
        let url = link()
        let first = Task { await sdk.handle(url: url) }
        await transport.waitUntilStarted()
        let collision = await sdk.recover(code: code)
        XCTAssertEqual(collision, .rejected(reason: "operation_in_progress_retry_input"))
        let saved = await sdk.acknowledge(id: "unknown"); XCTAssertFalse(saved)
        await transport.release(try JSONSerialization.data(withJSONObject: payload(clock)))
        guard case .pending = await first.value else { return XCTFail() }
        let second = await sdk.recover(code: code)
        XCTAssertEqual(second, .rejected(reason: "pending_destination_exists"))
    }
    func testContextIsolation() throws {
        let (_, storage, transport, _) = try setup()
        let other = try LinkBudConfiguration(origin: URL(string: "https://other.example")!, applicationID: app, environment: "default", sdkID: sdk, appleAppID: "A1B2C3D4E5.dev.linkbud.test")
        XCTAssertThrowsError(try LinkBud(configuration: other, storage: storage, transport: transport, now: { Date() }))
    }
    func testNavigationReportsPersistOfflineAndRetryWithoutPrivateAppData() async throws {
        let (sdk, storage, transport, clock) = try setup()
        transport.json["analytics"] = ["receipt": "synthetic-receipt", "expires_at": ISO8601DateFormatter().string(from: clock.date.addingTimeInterval(3600))]
        guard case .pending(let pending) = await sdk.handle(url: link()) else { return XCTFail() }
        clock.date = clock.date.addingTimeInterval(2)
        transport.offline = true
        let saved = await sdk.acknowledge(id: pending.id)
        XCTAssertTrue(saved)
        for _ in 0..<1000 {
            let state = try JSONDecoder().decode(StoredState.self, from: XCTUnwrap(storage.data))
            if state.reports?.first?.retryAt != nil { break }
            await Task.yield()
        }
        let stored = try JSONDecoder().decode(StoredState.self, from: XCTUnwrap(storage.data))
        XCTAssertEqual(stored.reports?.count, 1)
        XCTAssertNil(stored.request)
        XCTAssertNil(stored.pending)
        clock.date = clock.date.addingTimeInterval(31)
        transport.offline = false; transport.status = 202
        let restarted = try LinkBud(configuration: config(), storage: storage, transport: transport, now: { clock.date })
        await restarted.flushReports()
        let body = try XCTUnwrap(transport.bodies.last)
        XCTAssertEqual(body["outcome"], "opened")
        XCTAssertEqual(body["duration_ms"], "2000")
        XCTAssertNil(body["installation_id"])
        XCTAssertNil(body["destination"])
        let finished = try JSONDecoder().decode(StoredState.self, from: XCTUnwrap(storage.data))
        XCTAssertEqual(finished.reports?.count, 0)
    }

    func testFailedDestinationUsesAllowlistedReasonAndDoesNotNavigate() async throws {
        let (sdk, storage, transport, clock) = try setup()
        transport.json["analytics"] = ["receipt": "synthetic-receipt", "expires_at": ISO8601DateFormatter().string(from: clock.date.addingTimeInterval(3600))]
        guard case .pending(let pending) = await sdk.handle(url: link()) else { return XCTFail() }
        let invalid = await sdk.destinationFailed(id: pending.id, reason: "private business data")
        XCTAssertFalse(invalid)
        let accepted = await sdk.destinationFailed(id: pending.id, reason: "permission")
        XCTAssertTrue(accepted)
        let stored = try JSONDecoder().decode(StoredState.self, from: XCTUnwrap(storage.data))
        XCTAssertNil(stored.pending)
        let outcome = await sdk.pending()
        XCTAssertEqual(outcome, .empty)
    }

    func shortConfig() throws -> LinkBudConfiguration {
        try LinkBudConfiguration(origin: URL(string: "https://links.example.com")!, applicationID: app,
            environment: "default", sdkID: sdk, appleAppID: "A1B2C3D4E5.dev.linkbud.test", routePrefix: "Ab1")
    }

    func testShortURLRevalidationAndReopeningUseScopedCodeAndFreshJourneys() async throws {
        let configuration = try shortConfig()
        let store = MemoryStorage()
        let transport = MockTransport()
        let clock = Clock()
        transport.json = payload(clock)
        transport.json["route_prefix"] = "Ab1"
        transport.json["short_code"] = "Cd34Ef"
        let sdk = try LinkBud(configuration: configuration, storage: store, transport: transport, now: { clock.date })
        let url = URL(string: "https://links.example.com/Ab1/Cd34Ef")!
        guard case .pending(let first) = await sdk.handle(url: url) else { return XCTFail("Expected short pending") }
        XCTAssertEqual(transport.bodies.first?["route_prefix"], "Ab1")
        XCTAssertEqual(transport.bodies.first?["code"], "Cd34Ef")
        XCTAssertNil(transport.bodies.first?["slug"])
        XCTAssertNil(transport.bodies.first?["installation_id"])
        let acknowledged = await sdk.acknowledge(id: first.id)
        XCTAssertTrue(acknowledged)
        guard case .pending(let second) = await sdk.reopen(url: url) else { return XCTFail("Expected reopened short link") }
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(transport.bodies[0]["event_id"], transport.bodies[1]["event_id"])
    }

    func testShortURLValidationRejectsOtherContextsAndUntrustedSuffixes() throws {
        let configuration = try shortConfig()
        XCTAssertEqual(try configuration.reference(URL(string: "https://links.example.com/Ab1/Cd34Ef")!).value, "Cd34Ef")
        for url in ["https://evil.test/Ab1/Cd34Ef", "https://links.example.com/ab1/Cd34Ef", "https://links.example.com/Ab1/12345678",
                    "https://links.example.com/Ab1/Cd34Ef?x=1", "https://links.example.com/Ab1/Cd34Ef#x", "https://links.example.com/%41b1/Cd34Ef"] {
            XCTAssertThrowsError(try configuration.reference(URL(string: url)!))
        }
        XCTAssertThrowsError(try config().reference(URL(string: "https://links.example.com/Ab1/Cd34Ef")!))
    }

    func testShortResponseMustMatchPrefixAndCode() async throws {
        for (prefix, code) in [("ab1", "Cd34Ef"), ("Ab1", "cd34ef"), ("Ab1", "12345678")] {
            let transport = MockTransport()
            let clock = Clock()
            transport.json = payload(clock)
            transport.json["route_prefix"] = prefix
            transport.json["short_code"] = code
            let sdk = try LinkBud(configuration: shortConfig(), storage: MemoryStorage(), transport: transport, now: { clock.date })
            let result = await sdk.handle(url: URL(string: "https://links.example.com/Ab1/Cd34Ef")!)
            XCTAssertEqual(result, .rejected(reason: "invalid_payload"))
        }
    }

    func testAddingPrefixKeepsStoredRecoveryInstallationIdentityAcrossUpgrade() async throws {
        let store = MemoryStorage()
        let transport = MockTransport()
        let clock = Clock()
        transport.offline = true
        let old = try LinkBud(configuration: config(), storage: store, transport: transport, now: { clock.date })
        guard case .retryable(let retryAt) = await old.recover(code: code) else { return XCTFail("Expected retry") }
        clock.date = retryAt
        transport.offline = false
        transport.json = payload(clock)
        transport.json["route_prefix"] = "Ab1"
        transport.json["short_code"] = "Cd34Ef"
        transport.json["recovery_expires_at"] = ISO8601DateFormatter().string(from: clock.date.addingTimeInterval(600))
        let upgraded = try LinkBud(configuration: shortConfig(), storage: store, transport: transport, now: { clock.date })
        guard case .pending = await upgraded.resume() else { return XCTFail("Recovery did not survive") }
        XCTAssertEqual(transport.bodies[0]["installation_id"], transport.bodies[1]["installation_id"])
    }

    func testShortModeRecoveryRejectsAbsentContextAndUnavailableLinks() async throws {
        let transport = MockTransport()
        let clock = Clock()
        transport.json = payload(clock)
        transport.json["recovery_expires_at"] = ISO8601DateFormatter().string(from: clock.date.addingTimeInterval(600))
        let sdk = try LinkBud(configuration: shortConfig(), storage: MemoryStorage(), transport: transport, now: { clock.date })
        let result = await sdk.recover(code: code)
        XCTAssertEqual(result, .rejected(reason: "invalid_payload"))
        transport.status = 410
        let unavailable = await sdk.handle(url: URL(string: "https://links.example.com/Ab1/Cd34Ef")!)
        XCTAssertEqual(unavailable, .rejected(reason: "http_410"))
    }

}
