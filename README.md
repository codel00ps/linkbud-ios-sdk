# LinkBud iOS SDK · 0.4.0 preview

The Swift package supports Universal Link input and **explicit** recovery-code entry. iOS 15+ is supported; macOS 12+ is a Foundation test harness, not a macOS app-opening integration. The package uses Swift tools 5.9, Foundation and CryptoKit with no external dependencies. Signed-device and real installation/authentication acceptance remains pending, so treat 0.4.0 as a preview.

## Install with Swift Package Manager

In Xcode, choose **File → Add Package Dependencies**, enter the repository URL, select version `0.4.0`, and add the **LinkBud** product to your app target:

```text
https://github.com/codel00ps/linkbud-ios-sdk
```

The repository must be public for unauthenticated installs; otherwise, each developer and build machine needs GitHub access. The release is distributed from the Git tag through Swift Package Manager, not from CocoaPods or the App Store. See [Apple's Swift package instructions](https://developer.apple.com/documentation/xcode/publishing-a-swift-package-with-xcode).

## Configure one environment

Register the signed build's Apple team and bundle IDs in its LinkBud environment. Serve `LINK_URL` directly over public HTTPS with valid TLS, and enable Associated Domains in the app's provisioning profile and entitlements (`applinks:YOUR_LINK_HOST`). Check the generated AASA document for the exact application/environment path. Different environments require distinct registered identities.

```swift
import LinkBud

let configuration = try LinkBudConfiguration(
    origin: URL(string: "https://links.example.com")!,
    applicationID: "YOUR_APPLICATION_PUBLIC_ID",
    environment: "testing",
    sdkID: "YOUR_ENVIRONMENT_PUBLIC_SDK_ID",
    appleAppID: "A1B2C3D4E5.com.example.app.dev",
    routePrefix: "Ab1" // Copy the three-character SDK route prefix from Settings.
)
let linkbud = try LinkBud(configuration: configuration)
```

Replace the illustrative IDs with the generated lowercase 26-character public IDs. Initialize **one** long-lived instance per configuration in your host's app model. Initialization throws for invalid configuration or corrupt/unavailable storage; show a recoverable error rather than navigating. No management secret belongs in a mobile binary. The SDK requires a root HTTPS origin with no credentials, custom port, query or fragment.

Forward URLs from cold and warm entry points. For SwiftUI, use `.onOpenURL` and `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)` with `activity.webpageURL`. For UIKit scenes, handle `connectionOptions.userActivities` in `scene(_:willConnectTo:options:)` and `scene(_:continue:)`; for an app without scenes, handle `application(_:continue:restorationHandler:)`. Forward only the browsing-web activity to `await linkbud.handle(url:)`. The SDK verifies the exact HTTPS host, application, environment and six-character code under its configured three-character route prefix. Query strings, fragments, encoded path aliases and other environments are rejected.

## Authentication, persistence and acknowledgment

```swift
let result = await linkbud.handle(url: incomingURL)
// A pending result is a navigation hint: retain it while the host presents its own login.
let refreshed = await linkbud.resume() // after login or an offline delay
// Allowlist the route, authorize its resource, and navigate idempotently in your host.
// Only after successful navigation:
let saved = await linkbud.acknowledge(id: pending.id)
```

The comments describe host responsibilities; the sample demonstrates only its allowlisted `/welcome` screen and simulated login. A `pending` result never authorizes private content. Calls are asynchronous; deliver UI updates on the main actor. `pending()` returns cached state for waiting UI only; call `resume()` before routing. Check acknowledgment's Boolean result and handle a crash between navigation and acknowledgment idempotently.

One journey is atomically stored under Application Support/LinkBud, excluded from backups and protected until first unlock on iOS. The namespace includes origin, application, environment, SDK ID and Apple app identity. State contains a random installation ID, input, pending hint and the last 64 acknowledged delivery hashes. It survives authentication, backgrounding and process restarts. It is not stored in Keychain or transferred across installs. Direct pending input lasts at most 24 hours; code input lasts at most 30 minutes from entry and always stops at the earlier server/link expiry. No analytics or navigation details are logged by the SDK.

The actor serializes mutations and refuses incoming input while a network operation is running (`operation_in_progress_retry_input`). The host must serialize callbacks or retain and resubmit that input; `resume()` only retries an input already persisted. A different journey cannot replace a pending one (`pending_destination_exists`). Do not create multiple instances or share the storage across app processes/extensions. Local acknowledgments suppress only the last 64 delivery IDs, not every future visit forever.

## Explicit recovery after installing

Share the **iOS install continuation page** beside the link in the tenant workspace. This separate `/continue/{application}/{environment}/{slug}` URL keeps original `/l/...` redirects unchanged. The page explains the flow before issuing anything:

1. The user requests a code with the visible button; the page shows a selectable code and its UTC expiry.
2. The user installs the app using the configured App Store link and opens it normally.
3. The host presents a labeled code field and an explicit submit action, then calls `await linkbud.recover(code: enteredCode)`.
4. On a pending result, the host requires its own authentication, revalidates and authorizes the route, navigates, and acknowledges.

Codes contain 24 hexadecimal characters, displayed in six groups of four. The SDK accepts lowercase and display hyphens, trims surrounding whitespace, then sends the canonical uppercase value. It never reads the clipboard; any user paste must be an explicit host UI action. Codes expire in 30 minutes or earlier link expiry. The backend stores hashes, binds claims to the complete environment/Apple identity and random installation ID, allows same-installation retries after a lost response, and rejects another installation with 409. Code possession is a capability for a public hint, not app attestation or user authentication. A leaked code can win the first claim; do not log codes, request bodies, install IDs or destination parameters.

Canceling an install leaves the code to expire. Missing, expired, disabled, deleted, already-claimed or mistyped codes do not fabricate navigation. Request another code or reopen the original link after installation. Reopening depends on the OS's association state and may still show the store. App Store installation does not automatically transfer a referral payload; automatic iOS deferred recovery is never promised.

## Results and retries

- `pending(PendingDestination)`: waiting hint with delivery ID, app-relative destination and expiry. Validate host authorization before use.
- `empty`: no persisted input. No automatic install/referrer lookup occurs.
- `alreadyAcknowledged`: delivery is in bounded local history.
- `retryable(retryAt:)`: call `resume()` from a visible retry/connectivity/lifecycle trigger at or after that time. Offline/429/5xx use exponential 2-second to 5-minute backoff; numeric `Retry-After` is capped at 24 hours and the request deadline. No background polling occurs.
- `rejected(reason:)`: invalid input, terminal HTTP status, unsafe/mismatched/expired payload or storage failure. Terminal network responses clear the journey; invalid new input and busy/pending conflicts preserve the existing journey. Reopen the original link or request a fresh code. Storage failures fail closed until the host recreates the instance after repairing storage.

Transport uses an ephemeral URLSession without cookies/cache, default platform TLS checks, no redirects, 10-second request / 15-second resource timeouts and a 16 KiB response cap. HTTP 401/404/409/410/422 and redirects are terminal. Pending expiry is checked again after responses arrive. Disabling a link during login prevents navigation when the host revalidates.

## Sample and verification

Open `Sample/LinkBudSample.xcodeproj`, copy `Sample/Sample.xcconfig` to ignored `Sample/Local.xcconfig`, and replace its public configuration and bundle identifier with your environment. Select your own signing team in Xcode for a provisioned device build. The default illustrative values allow building and inspecting the sample but cannot resolve your real links. Create a LinkBud link whose app-relative destination is `/welcome`.

```sh
cd linkbud-ios-sdk
swift test
xcodebuild -project Sample/LinkBudSample.xcodeproj -scheme LinkBudSample \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/linkbud-ios-derived CODE_SIGNING_ALLOWED=NO build
```

The SwiftUI sample forwards cold/warm URLs, preserves one queued URL during an existing operation, supports user code entry, shows retry/errors and waits for a clearly labeled simulated login before its welcome screen. Process restart signs out the simulation while retaining SDK pending input. It has no production login service. See [device acceptance](https://github.com/codel00ps/linkbud.io/blob/master/docs/ios-device-validation.md) for actual authentication and fresh-install requirements.

## Release procedure

Version 0.4.0 is a source preview distributed from the `0.4.0` Git tag using Swift Package Manager. It is not an App Store or TestFlight app. For a later SDK release, update the version/changelog and sample Info.plist metadata, run package tests and simulator/device builds, and complete the acceptance protocol. Never include provisioning profiles, signing keys, local config, management secrets, tokens or personal data in packages/reports.

## Basic analytics

The current native SDK persists a random per-journey event ID and sends it on direct link resolution, including OS-native opens that bypass web redirects. Restart, network retry and login revalidation reuse the ID. Successful deferred exchanges are counted once by the server. No installation identifier is sent for direct-open analytics. An SDK open means successful resolution, potentially before login; acknowledgment/navigation remains local. Upgrade the backend with the analytics migration before using these counts. Older servers ignore the additive request fields, and old SDKs continue resolving without direct-open counts. Read [the analytics contract](https://github.com/codel00ps/linkbud.io/blob/master/docs/analytics.md) for privacy, 30-day retention, public-client trust limits and queue operations.


## General link analytics (v2 preview)

The SDK requests v2 analytics on direct/recovered resolution. The server returns an optional,
short-lived opaque reporting receipt. Call the existing `acknowledge` only after actual authorized
navigation: it now atomically queues a destination-open report alongside the normal local progress.
Reports include only the receipt, outcome and elapsed SDK journey time, never the destination,
credentials, user IDs or installation identifier. Old servers without receipts still work.

For an abandoned destination, `destinationFailed(id, reason)` accepts only `navigation`,
`authentication`, `permission`, `unavailable`, or `unsupported`, persists the failure report and
finishes that local journey. Do not call this for a sign-in screen that is still waiting for login.
Flutter exposes the same method. This is not a business conversion or authorization API.

Delivery is best effort. Up to 16 reports persist outside backups; the oldest is evicted at the
bound. Reports retry on lifecycle resume/acknowledgement, honor bounded retry delays and expire with
the server receipt. Network errors do not undo successful navigation. No background polling occurs.
The dashboard separates browser clicks, successful resolution, completed navigation and store
redirects; none identify unique people or prove a download. Existing acknowledged-link deduplication
behavior and store/device acceptance limits remain unchanged. Rebuild host apps to use this version;
updating LinkBud alone cannot add destination reporting to an installed app.


## Testing and Live · 0.4.0 preview

Configure new integrations with Testing or Live. Staging is retired. Development and Production are accepted legacy aliases for Testing and Live respectively, including URL parsing. The backend echoes the requested API environment for older SDK payload validation. Association documents and Android manifest snippets include both canonical and legacy paths. Refresh app configuration/manifest when adopting new URLs; existing installed Android builds with only a development path filter cannot receive testing URLs until rebuilt. Keep legacy SDK configuration until outstanding pending journeys finish; changing the configured environment changes the SDK storage namespace.

### Explicitly opening a shared URL again

`handle(url:)` keeps its existing duplicate protection. For a fresh user activation of a URL
that returns `.alreadyAcknowledged`, a host with **no pending journey or presented destination**
may call `reopen(url:)`. This creates a new delivery/event identity and resolves the URL again;
it never grants access or reuses an old authorized payload. Apply the usual login/authorization
checks and acknowledge only after presentation. Never call reopening for duplicate callbacks
while the existing screen/journey is active. Recovery-code handling is unchanged, and another
pending request is rejected rather than replaced. Aurix's Debug demo integration exercises this
opt-in behavior; physical-device/store publication acceptance remains separate.

## Short URLs · 0.4.0 preview

Configure `routePrefix` with the environment’s immutable three-character Base62 value, without
slashes. A short link is `https://LINK_HOST/Ab1/Cd34Ef`: prefix and code are case-sensitive.
Copy the real value from LinkBud Settings; the example is illustrative. The SDK sends the
configured application/environment/SDK IDs plus `route_prefix` and `code` to resolution and
checks the response against that context. Short links reject extra path segments, credentials,
custom ports, queries, fragments and encoded aliases.

The optional setting keeps existing constructors working. While the rollout flag is off, old
paths remain accepted for a staged upgrade; after activation the server rejects legacy slug
resolution and publishes only short paths in association documents. Update Android manifest
filters before activation; cached OS association changes may take time. Reopening an old URL
after cutover fails and requires a newly shared URL. Adding a prefix preserves stored installation
identity and pending recovery; always resume/revalidate before authorizing navigation. Recovery
responses include the same prefix/code context. Android still needs a matching Play installation;
iOS still requires explicit code entry or reopening the original short link after installation.
New SDK releases do not update already-installed host apps; rebuild and distribute the host app to deliver an SDK update.
