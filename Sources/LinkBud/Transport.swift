import Foundation

struct APIResponse: Sendable {
    let status: Int
    let data: Data
    var retryAfter: TimeInterval = 0
}
protocol Transport: Sendable {
    func post(origin: URL, path: String, body: [String: String]) async throws -> APIResponse
}
final class HTTPTransport: NSObject, Transport, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func post(origin: URL, path: String, body: [String: String]) async throws -> APIResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: origin.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONEncoder().encode(body)
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw LinkBudError.invalidPayload }
        if response.statusCode != 200 {
            return APIResponse(status: response.statusCode, data: Data(), retryAfter: Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 0)
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 16384 else { throw LinkBudError.invalidPayload }
            data.append(byte)
        }
        return APIResponse(status: response.statusCode, data: data)
    }
}
