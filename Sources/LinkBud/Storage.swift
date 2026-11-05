import Foundation

protocol StateStorage: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
}
struct FileStorage: StateStorage {
    let url: URL
    init(context: String) throws {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var directory = root.appendingPathComponent("LinkBud", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        url = directory.appendingPathComponent("\(context).json")
    }
    func read() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }
    func write(_ data: Data) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        var file = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try file.setResourceValues(values)
    }
}
struct StoredState: Codable {
    var context: String
    var installationID: String = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
    var request: StoredRequest?
    var pending: PendingDestination?
    var acknowledged: [String] = []
    var reports: [NavigationReport]?
}
struct StoredRequest: Codable {
    let id: String
    let kind: String
    let value: String
    let deadline: Date
    var attempts = 0
    var retryAt: Date?
    var eventID: String?
    var startedAt: Date?
    var receipt: NavigationReceipt?
}

struct NavigationReceipt: Codable {
    let token: String
    let expiresAt: Date
}
struct NavigationReport: Codable {
    let receipt: NavigationReceipt
    let outcome: String
    let duration: Int
    let reason: String?
    var retryAt: Date?
}
