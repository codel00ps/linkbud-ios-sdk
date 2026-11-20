import CryptoKit
import Foundation

public struct LinkBudConfiguration: Sendable, Equatable {
    public let origin: URL
    public let applicationID: String
    public let environment: String
    public let sdkID: String
    public let appleAppID: String
    public let additionalLinkHosts: Set<String>

    public init(origin: URL, applicationID: String, environment: String, sdkID: String, appleAppID: String,
                additionalLinkHosts: Set<String> = []) throws {
        guard let parts = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host?.isEmpty == false, parts.user == nil, parts.password == nil,
              parts.port == nil, parts.query == nil, parts.fragment == nil, ["", "/"].contains(parts.path),
              applicationID.matches("[a-z0-9]{26}"), sdkID.matches("[a-z0-9]{26}"),
              environment == "default",
              appleAppID.matches("[A-Z0-9]{10}\\.[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+") else {
            throw LinkBudError.invalidConfiguration
        }
        self.origin = URL(string: "https://\(parts.host!)")!
        self.applicationID = applicationID
        self.environment = environment
        self.sdkID = sdkID
        self.appleAppID = appleAppID
        self.additionalLinkHosts = try Set(additionalLinkHosts.map(canonicalLinkHost))
    }

    /// Checks URL ownership without resolving a destination or changing stored state.
    public func canHandle(url: URL) -> Bool { (try? reference(url)) != nil }

    func reference(_ url: URL) throws -> (kind: String, value: String) {
        guard url.absoluteString.utf8.count <= 2048,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", let host = parts.host,
              host == origin.host || acceptsAdditionalHost(url), parts.port == nil,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath.matches("/[A-Za-z0-9]{6}") else { throw LinkBudError.invalidLink }
        return ("short", String(parts.percentEncodedPath.dropFirst()))
    }

    private func acceptsAdditionalHost(_ url: URL) -> Bool {
        // URLComponents decodes punycode; compare URL.host's ASCII identity without encoded aliases.
        guard let host = url.host,
              let authority = url.absoluteString.split(separator: "/", omittingEmptySubsequences: false).dropFirst(2).first,
              !authority.contains("%") else { return false }
        return additionalLinkHosts.contains(host.lowercased())
    }

    var body: [String: String] { ["sdk_id": sdkID, "application_id": applicationID, "environment": environment] }
    var context: String { digest("\(origin.absoluteString)|\(applicationID)|\(environment)|\(sdkID)|\(appleAppID)") }
}

private func canonicalLinkHost(_ host: String) throws -> String {
    guard host.utf8.count <= 253, host.utf8.allSatisfy({ $0 < 128 }) else { throw LinkBudError.invalidConfiguration }
    let canonical = host.lowercased()
    let labels = canonical.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2,
          labels.allSatisfy({ String($0).matches("[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?") }),
          labels.last!.contains(where: { $0 >= "a" && $0 <= "z" }) else { throw LinkBudError.invalidConfiguration }
    return canonical
}

public enum LinkBudError: Error { case invalidConfiguration, invalidLink, invalidPayload, invalidState }
public struct PendingDestination: Codable, Equatable, Sendable {
    public let id: String
    public let destination: String
    public let expiresAt: Date
}
public enum LinkBudResult: Equatable, Sendable {
    case pending(PendingDestination)
    case empty
    case alreadyAcknowledged
    case retryable(retryAt: Date)
    case rejected(reason: String)
}

func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}
extension String {
    func matches(_ pattern: String) -> Bool { range(of: "\\A(?:\(pattern))\\z", options: .regularExpression) != nil }
}
func timestamp(_ value: Any?) throws -> Date {
    guard let value = value as? String else { throw LinkBudError.invalidPayload }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: value) else { throw LinkBudError.invalidPayload }
    return date
}

func validate(_ json: [String: Any], config: LinkBudConfiguration, recovery: Bool, now: Date, shortCode: String? = nil) throws -> (String, Date?) {
    guard let version = json["version"] as? NSNumber, String(cString: version.objCType) != "c", version == 1,
          json["sdk_id"] as? String == config.sdkID, json["application_id"] as? String == config.applicationID,
          json["environment"] as? String == config.environment,
          let returnedSlug = json["slug"] as? String, returnedSlug.matches("[A-Za-z0-9]{16}"),
          let path = json["destination"] as? String, path.utf8.count <= 2048,
          let decoded = path.removingPercentEncoding, decoded.hasPrefix("/"), !decoded.hasPrefix("//"),
          !decoded.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 || $0.value == 92 }),
          json.keys.contains("expires_at") else { throw LinkBudError.invalidPayload }
    guard json["link_host"] as? String == config.origin.host,
          let returnedCode = json["short_code"] as? String, returnedCode.matches("[A-Za-z0-9]{6}"),
          shortCode == nil || shortCode == returnedCode else { throw LinkBudError.invalidPayload }
    _ = try timestamp(json["resolved_at"])
    var expiry: Date?
    if !(json["expires_at"] is NSNull) { expiry = try timestamp(json["expires_at"]) }
    if recovery {
        let recoveryExpiry = try timestamp(json["recovery_expires_at"])
        expiry = min(expiry ?? recoveryExpiry, recoveryExpiry)
    }
    guard expiry == nil || expiry! > now else { throw LinkBudError.invalidPayload }
    return (path, expiry)
}
