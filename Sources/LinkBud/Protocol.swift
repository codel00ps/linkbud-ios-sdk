import CryptoKit
import Foundation

public struct LinkBudConfiguration: Sendable {
    public let origin: URL
    public let applicationID: String
    public let environment: String
    public let sdkID: String
    public let appleAppID: String
    public let routePrefix: String?

    public init(origin: URL, applicationID: String, environment: String, sdkID: String, appleAppID: String, routePrefix: String? = nil) throws {
        guard let parts = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host?.isEmpty == false, parts.user == nil, parts.password == nil,
              parts.port == nil, parts.query == nil, parts.fragment == nil, ["", "/"].contains(parts.path),
              applicationID.matches("[a-z0-9]{26}"), sdkID.matches("[a-z0-9]{26}"),
              ["testing", "live", "development", "production"].contains(environment),
              routePrefix == nil || routePrefix!.matches("[A-Za-z0-9]{3}"),
              appleAppID.matches("[A-Z0-9]{10}\\.[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+") else {
            throw LinkBudError.invalidConfiguration
        }
        self.origin = URL(string: "https://\(parts.host!)")!
        self.applicationID = applicationID
        self.environment = environment
        self.sdkID = sdkID
        self.appleAppID = appleAppID
        self.routePrefix = routePrefix
    }

    func slug(_ url: URL) throws -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == origin.host, parts.port == nil,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw LinkBudError.invalidLink
        }
        let canonical = environment == "development" ? "testing" : (environment == "production" ? "live" : environment)
        let alias = canonical == "testing" ? "development" : "production"
        let prefixes = ["/l/\(applicationID)/\(canonical)/", "/l/\(applicationID)/\(alias)/"]
        guard let prefix = prefixes.first(where: { parts.percentEncodedPath.hasPrefix($0) }) else { throw LinkBudError.invalidLink }
        let slug = String(parts.percentEncodedPath.dropFirst(prefix.count))
        guard slug.matches("[A-Za-z0-9]{16}") else { throw LinkBudError.invalidLink }
        return slug
    }

    func reference(_ url: URL) throws -> (kind: String, value: String) {
        guard url.absoluteString.utf8.count <= 2048 else { throw LinkBudError.invalidLink }
        if let prefix = routePrefix, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
           parts.percentEncodedPath.hasPrefix("/\(prefix)/") {
            guard parts.scheme == "https", parts.host == origin.host, parts.port == nil, parts.user == nil,
                  parts.password == nil, parts.query == nil, parts.fragment == nil else { throw LinkBudError.invalidLink }
            let code = String(parts.percentEncodedPath.dropFirst(prefix.count + 2))
            guard code.matches("[A-Za-z0-9]{6}") else { throw LinkBudError.invalidLink }
            return ("short", code)
        }
        return ("slug", try slug(url))
    }

    var body: [String: String] { ["sdk_id": sdkID, "application_id": applicationID, "environment": environment] }
    var context: String { digest("\(origin.absoluteString)|\(applicationID)|\(environment)|\(sdkID)|\(appleAppID)") }
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

func validate(_ json: [String: Any], config: LinkBudConfiguration, slug: String?, recovery: Bool, now: Date, shortCode: String? = nil) throws -> (String, Date?) {
    guard let version = json["version"] as? NSNumber, String(cString: version.objCType) != "c", version == 1,
          json["sdk_id"] as? String == config.sdkID, json["application_id"] as? String == config.applicationID,
          json["environment"] as? String == config.environment,
          let returnedSlug = json["slug"] as? String, returnedSlug.matches("[A-Za-z0-9]{16}"),
          slug == nil || slug == returnedSlug,
          let path = json["destination"] as? String, path.utf8.count <= 2048,
          let decoded = path.removingPercentEncoding, decoded.hasPrefix("/"), !decoded.hasPrefix("//"),
          !decoded.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 || $0.value == 92 }),
          json.keys.contains("expires_at") else { throw LinkBudError.invalidPayload }
    if shortCode != nil || (recovery && config.routePrefix != nil) {
        guard let prefix = config.routePrefix, json["route_prefix"] as? String == prefix,
              let returnedCode = json["short_code"] as? String, returnedCode.matches("[A-Za-z0-9]{6}"),
              shortCode == nil || shortCode == returnedCode else { throw LinkBudError.invalidPayload }
    }
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
