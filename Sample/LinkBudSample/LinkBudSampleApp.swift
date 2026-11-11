import SwiftUI
import LinkBud

@MainActor
final class SampleModel: ObservableObject {
    @Published var status = "Configure your environment in Sample.xcconfig before testing."
    @Published var code = ""
    @Published var signedIn = false
    @Published var working = false
    private var sdk: LinkBud?
    private var queuedURL: URL?

    init() {
        do {
            let info = Bundle.main.infoDictionary ?? [:]
            let config = try LinkBudConfiguration(
                origin: URL(string: info["LinkBudOrigin"] as? String ?? "") ?? URL(fileURLWithPath: "/"),
                applicationID: info["LinkBudApplication"] as? String ?? "",
                environment: info["LinkBudEnvironment"] as? String ?? "",
                sdkID: info["LinkBudSDKID"] as? String ?? "",
                appleAppID: info["LinkBudAppleAppID"] as? String ?? "",
                routePrefix: (info["LinkBudRoutePrefix"] as? String).flatMap { $0.isEmpty ? nil : $0 })
            sdk = try LinkBud(configuration: config)
            status = "Ready. Open a configured Universal Link or enter a recovery code."
        } catch { status = "Configuration or local storage is unavailable. Check the sample setup guide." }
    }
    func run(url: URL? = nil, recovery: Bool = false) async {
        guard let sdk else { return }
        if working {
            if let url, queuedURL == nil { queuedURL = url }
            return
        }
        working = true
        defer {
            working = false
            if let next = queuedURL {
                queuedURL = nil
                Task { await run(url: next) }
            }
        }
        let result: LinkBudResult
        if let url { result = await sdk.handle(url: url) }
        else if recovery { result = await sdk.recover(code: code); code = "" }
        else { result = await sdk.resume() }
        switch result {
        case .pending(let pending):
            guard signedIn else { status = "A destination is waiting. Use simulated login to continue."; return }
            guard pending.destination.components(separatedBy: "?").first == "/welcome" else {
                status = "This sample only allows /welcome. The host must authorize its own routes."; return
            }
            status = "Welcome! The sample opened its allowed destination."
            if !(await sdk.acknowledge(id: pending.id)) { status = "Navigation shown, but acknowledgment failed. Retry safely." }
        case .empty: status = "No pending destination. Reopen the original link or enter a new code."
        case .alreadyAcknowledged: status = "This journey has already been handled."
        case .retryable(let retryAt): status = "Waiting for connectivity or retry time: \(retryAt.formatted()). Use Retry afterward."
        case .rejected(let reason): status = "Cannot continue (\(reason)). Reopen the original link or request a fresh code."
        }
    }
}

@main
struct LinkBudSampleApp: App {
    @StateObject private var model = SampleModel()
    var body: some Scene {
        WindowGroup {
            Form {
                Section("LinkBud iOS sample") {
                    Text("This sample uses simulated login. It does not authenticate or authorize real users.")
                    Text(model.status).accessibilityIdentifier("linkbud-status")
                }
                Section("Continue after installation") {
                    TextField("Recovery code", text: $model.code)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .accessibilityLabel("Recovery code")
                    Button("Use entered code") { Task { await model.run(recovery: true) } }
                        .disabled(model.code.isEmpty || model.working)
                    Text("Enter the code you explicitly requested on the continuation page. No automatic recovery or clipboard reading occurs.")
                }
                Section("Demo navigation") {
                    Button(model.signedIn ? "Revalidate pending destination" : "Simulate login and continue") {
                        model.signedIn = true
                        Task { await model.run() }
                    }.disabled(model.working)
                    Button("Retry") { Task { await model.run() } }.disabled(model.working)
                }
            }
            .task { await model.run() }
            .onOpenURL { url in Task { await model.run(url: url) } }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL { Task { await model.run(url: url) } }
            }
        }
    }
}
