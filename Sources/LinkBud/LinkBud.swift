import Foundation

/// Keep one instance per configuration in the host app. Call resume after login and before routing.
public actor LinkBud {
    private let config: LinkBudConfiguration
    private let storage: any StateStorage
    private let transport: any Transport
    private let now: @Sendable () -> Date
    private var state: StoredState
    private var busy = false
    private var reporting = false
    private var storageFailed = false

    public init(configuration: LinkBudConfiguration) throws {
        try self.init(configuration: configuration, storage: FileStorage(context: configuration.context), transport: HTTPTransport(), now: { Date() })
    }
    init(configuration: LinkBudConfiguration, storage: any StateStorage, transport: any Transport, now: @escaping @Sendable () -> Date) throws {
        self.config = configuration
        self.storage = storage
        self.transport = transport
        self.now = now
        if let data = try storage.read() {
            guard data.count <= 65536 else { throw LinkBudError.invalidState }
            state = try JSONDecoder().decode(StoredState.self, from: data)
            guard state.context == configuration.context, state.installationID.matches("[a-f0-9]{64}"),
                  state.acknowledged.count <= 64 else { throw LinkBudError.invalidState }
        } else { state = StoredState(context: configuration.context) }
        try storage.write(JSONEncoder().encode(state))
    }

    public func handle(url: URL) async -> LinkBudResult {
        guard let reference = try? config.reference(url) else { return .rejected(reason: "invalid_link") }
        return await enqueue(kind: reference.kind, value: reference.value)
    }
    /// Explicitly reopen a previously acknowledged URL as a fresh, revalidated journey.
    /// Hosts must not call this for duplicate callbacks while navigation is still presented.
    public func reopen(url: URL) async -> LinkBudResult {
        guard let reference = try? config.reference(url) else { return .rejected(reason: "invalid_link") }
        return await enqueue(kind: reference.kind, value: reference.value, reopening: true)
    }
    /// Only call after explicit user entry/paste. This SDK never reads the clipboard.
    public func recover(code: String) async -> LinkBudResult {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-", with: "").uppercased()
        guard normalized.matches("[A-F0-9]{24}") else { return .rejected(reason: "invalid_recovery_code") }
        return await enqueue(kind: "code", value: normalized)
    }
    public func pending() -> LinkBudResult {
        guard !storageFailed else { return .rejected(reason: "local_state_failure") }
        guard !busy else { return .retryable(retryAt: now().addingTimeInterval(2)) }
        do {
            try expire()
            return state.pending.map { .pending($0) } ?? .empty
        } catch { return failStorage() }
    }
    public func acknowledge(id: String) -> Bool {
        guard !busy, !storageFailed, let pending = state.pending, pending.id == id, pending.expiresAt > now() else { return false }
        queueReport(outcome: "opened", reason: nil)
        state.acknowledged = Array((state.acknowledged + [id]).suffix(64))
        state.pending = nil
        state.request = nil
        do {
            try save()
            Task { await self.flushReports() }
            return true
        } catch { storageFailed = true; return false }
    }
    private func enqueue(kind: String, value: String, reopening: Bool = false) async -> LinkBudResult {
        guard !storageFailed else { return .rejected(reason: "local_state_failure") }
        guard !busy else { return .rejected(reason: "operation_in_progress_retry_input") }
        do {
            try expire()
            var id = digest("\(config.sdkID):\(kind):\(value)")
            if state.acknowledged.contains(id) {
                guard reopening else { return .alreadyAcknowledged }
                guard state.request == nil else { return .rejected(reason: "pending_destination_exists") }
                id = digest(UUID().uuidString)
            }
            if let request = state.request, request.id != id { return .rejected(reason: "pending_destination_exists") }
            if state.request == nil {
                state.request = StoredRequest(id: id, kind: kind, value: value, deadline: now().addingTimeInterval(kind == "code" ? 1800 : 86400))
                try save()
            }
        } catch { return failStorage() }
        return await resume()
    }
    public func resume() async -> LinkBudResult {
        Task { await self.flushReports() }
        guard !storageFailed else { return .rejected(reason: "local_state_failure") }
        guard !busy else { return .retryable(retryAt: now().addingTimeInterval(2)) }
        guard var request = state.request else { return .empty }
        guard request.deadline > now(), state.pending == nil || state.pending!.expiresAt > now() else { return reject("request_expired") }
        if let retryAt = request.retryAt, retryAt > now() { return .retryable(retryAt: retryAt) }
        busy = true
        defer { busy = false }
        if request.startedAt == nil {
            request.startedAt = now(); state.request = request
            do { try save() } catch { return failStorage() }
        }
        var body = config.body
        body["analytics_version"] = "2"
        let recovery = request.kind == "code"
        if request.kind == "short" {
            guard let prefix = config.routePrefix else { return reject("missing_route_prefix") }
            body["route_prefix"] = prefix
            body["code"] = request.value
        } else { body[recovery ? "code" : "slug"] = request.value }
        if recovery { body["apple_app_id"] = config.appleAppID; body["installation_id"] = state.installationID }
        do {
            if !recovery {
                if request.eventID == nil {
                    request.eventID = digest(UUID().uuidString)
                    state.request = request
                    do { try save() } catch { return failStorage() }
                }
                body["event_id"] = request.eventID
                body["platform"] = "ios"
            }
            let response = try await transport.post(origin: config.origin, path: recovery ? "/api/v1/ios/recovery" : "/api/v1/resolve", body: body)
            if response.status == 429 || (500...599).contains(response.status) { return retry(&request, after: response.retryAfter) }
            guard response.status == 200 else { return reject("http_\(response.status)") }
            guard response.data.count <= 16384, let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else { return reject("invalid_payload") }
            let (destination, expiry) = try validate(json, config: config, slug: request.kind == "slug" ? request.value : nil, recovery: recovery, now: now(), shortCode: request.kind == "short" ? request.value : nil)
            let deadline = min(request.deadline, expiry ?? request.deadline)
            guard deadline > now() else { return reject("request_expired") }
            let pending = PendingDestination(id: request.id, destination: destination, expiresAt: deadline)
            state.pending = pending
            if let analytics = json["analytics"] as? [String: Any], let token = analytics["receipt"] as? String,
               token.utf8.count <= 4096, !token.isEmpty, let expiry = try? timestamp(analytics["expires_at"]), expiry > now() {
                request.receipt = NavigationReceipt(token: token, expiresAt: expiry)
            }
            request.retryAt = nil
            state.request = request
            do { try save() } catch { return failStorage() }
            return .pending(pending)
        } catch is URLError { return retry(&request, after: 0) }
        catch is CancellationError { return retry(&request, after: 0) }
        catch { return reject("invalid_payload") }
    }
    /// Call only when the host has abandoned navigation. Uses a fixed, non-sensitive reason.
    public func destinationFailed(id: String, reason: String) -> Bool {
        guard ["navigation", "authentication", "permission", "unavailable", "unsupported"].contains(reason),
              !busy, !storageFailed, let pending = state.pending, pending.id == id, pending.expiresAt > now() else { return false }
        queueReport(outcome: "failed", reason: reason)
        state.acknowledged = Array((state.acknowledged + [id]).suffix(64))
        state.pending = nil; state.request = nil
        do { try save(); Task { await self.flushReports() }; return true }
        catch { storageFailed = true; return false }
    }

    private func queueReport(outcome: String, reason: String?) {
        guard let request = state.request, let receipt = request.receipt, receipt.expiresAt > now() else { return }
        let duration = Int(max(0, min(86400000, now().timeIntervalSince(request.startedAt ?? now()) * 1000)))
        var reports = state.reports ?? []
        reports = Array(reports.suffix(15))
        reports.append(NavigationReport(receipt: receipt, outcome: outcome, duration: duration, reason: reason))
        state.reports = reports
    }

    /// Retry pending analytics on lifecycle resume, without changing navigation results.
    public func flushReports() async {
        guard !reporting, !storageFailed else { return }
        reporting = true
        defer { reporting = false }
        let previousCount = state.reports?.count ?? 0
        state.reports = (state.reports ?? []).filter { $0.receipt.expiresAt > now() }
        if state.reports?.count != previousCount { try? save() }
        guard let report = state.reports?.first, report.retryAt == nil || report.retryAt! <= now() else { return }
        var body = ["receipt": report.receipt.token, "outcome": report.outcome, "duration_ms": String(report.duration)]
        if let reason = report.reason { body["reason"] = reason }
        do {
            let response = try await transport.post(origin: config.origin, path: "/api/v1/journeys/outcome", body: body)
            if response.status == 429 || response.status >= 500 {
                deferReport(report, delay: max(30, min(response.retryAfter, 86400)))
            } else {
                state.reports?.removeAll { $0.receipt.token == report.receipt.token }
            }
        } catch { deferReport(report, delay: 30) }
        // Analytics storage failure must not invalidate an already completed navigation.
        try? save()
    }

    private func deferReport(_ report: NavigationReport, delay: TimeInterval) {
        if let index = state.reports?.firstIndex(where: { $0.receipt.token == report.receipt.token }) {
            state.reports?[index].retryAt = now().addingTimeInterval(delay)
        }
    }

    private func expire() throws {
        if let request = state.request, request.deadline <= now() || (state.pending != nil && state.pending!.expiresAt <= now()) {
            state.request = nil; state.pending = nil; try save()
        }
    }
    private func retry(_ request: inout StoredRequest, after: TimeInterval) -> LinkBudResult {
        guard request.deadline > now() else { return reject("request_expired") }
        request.attempts = min(request.attempts + 1, 9)
        let delay = max(min(pow(2, Double(request.attempts)), 300), min(max(after.isFinite ? after : 0, 0), 86400))
        let retryAt = min(now().addingTimeInterval(delay), request.deadline)
        request.retryAt = retryAt
        state.request = request
        do { try save(); return .retryable(retryAt: retryAt) } catch { return failStorage() }
    }
    private func reject(_ reason: String) -> LinkBudResult {
        state.pending = nil; state.request = nil
        do { try save(); return .rejected(reason: reason) } catch { return failStorage() }
    }
    private func save() throws { try storage.write(JSONEncoder().encode(state)) }
    private func failStorage() -> LinkBudResult { storageFailed = true; return .rejected(reason: "local_state_failure") }
}
