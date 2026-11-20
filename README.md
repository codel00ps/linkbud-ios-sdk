> SDK 2.0.0 subdomain candidate — publication pending. Use this checkout for local integration until the new artifacts are released. Published 1.x packages use the retired protocol.

# LinkBud iOS SDK · 2.0.0

> Release candidate for 2.0.0. Publication and host-device acceptance are separate steps; existing 1.0.0 artifacts and tags remain unchanged.

The Swift package supports Universal Link input and **explicit** recovery-code entry. iOS 15+ is supported; macOS 12+ is a Foundation test harness, not a macOS app-opening integration. The package uses Swift tools 5.9, Foundation and CryptoKit with no external dependencies. Version 1.0.0 established the stable public API. The owner confirmed real-device cold/warm links and login/restart recovery passed on November 11, 2026; these are owner-reported integration results, not new device tests performed by release preparation.

## Install with Swift Package Manager

In Xcode, choose **File → Add Package Dependencies**, enter the repository URL, select version `2.0.0`, and add the **LinkBud** product to your app target:

```text
https://github.com/codel00ps/linkbud-ios-sdk
```

The repository must be public for unauthenticated installs; otherwise, each developer and build machine needs GitHub access. The release is distributed from the Git tag through Swift Package Manager, not from CocoaPods or the App Store. See [Apple's Swift package instructions](https://developer.apple.com/documentation/xcode/publishing-a-swift-package-with-xcode).

## Configure one environment

Register the signed build's Apple team and bundle IDs in its LinkBud environment. Serve `LINK_URL` directly over public HTTPS with valid TLS, and enable Associated Domains in the app's provisioning profile and entitlements (`applinks:YOUR_LINK_HOST`). Check the generated AASA document for this application host and its six-character code path. Each application uses its single default configuration.

```swift
import LinkBud

let configuration = try LinkBudConfiguration(
    origin: URL(string: "https://aurix.linkbud.io")!,
    applicationID: "YOUR_APPLICATION_PUBLIC_ID",
    environment: "default",
    sdkID: "YOUR_ENVIRONMENT_PUBLIC_SDK_ID",
    appleAppID: "A1B2C3D4E5.com.example.app.dev"
)
let linkbud = try LinkBud(configuration: configuration)
```

Replace the illustrative IDs with the generated lowercase 26-character public IDs. Initialize **one** long-lived instance per configuration in your host's app model. Initialization throws for invalid configuration or corrupt/unavailable storage; show a recoverable error rather than navigating. No management secret belongs in a mobile binary. The SDK requires a root HTTPS origin with no credentials, custom port, query or fragment.

Forward URLs from cold and warm entry points. For SwiftUI, use `.onOpenURL` and `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)` with `activity.webpageURL`. For UIKit scenes, handle `connectionOptions.userActivities` in `scene(_:willConnectTo:options:)` and `scene(_:continue:)`; for an app without scenes, handle `application(_:continue:restorationHandler:)`. Forward only the browsing-web activity to `await linkbud.handle(url:)`. The SDK verifies the exact HTTPS host, application, environment and six-character code on its configured application domain. Query strings, fragments, encoded path aliases and other environments are rejected.

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

Share the **iOS install continuation page** beside the link in the tenant workspace. This separate `/continue/{code}` URL is on the application domain and stays in the browser. The page explains the flow before issuing anything:

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

The SwiftUI sample forwards cold/warm URLs, preserves one queued URL during an existing operation, supports user code entry, shows retry/errors and waits for a clearly labeled simulated login before its welcome screen. Process restart signs out the simulation while retaining SDK pending input. It has no production login service. See [device acceptance](docs/acceptance.md) for actual authentication and fresh-install requirements.

## Release procedure

Version 1.0.0 established the public 1.x API baseline without changing the 0.4.0 runtime protocol or persisted journey format. Compatible fixes and additive APIs use patch/minor releases; incompatible public API changes require a major version. Keep Swift tools 5.9 and iOS 15 minimums; macOS is only a test harness. The host remains responsible for authentication, resource authorization and allowlisted navigation.

Distribution uses the public repository's `2.0.0` semantic-version Git tag. Commit the reviewed candidate before tagging; never move an existing release tag. Run package tests and iOS simulator/device-target builds, inspect the source archive, and install the final tag in a clean consumer before claiming publication. No provisioning profiles, signing keys, local config, management secrets, tokens or personal data belong in the package.

## Basic analytics

The current native SDK persists a random per-journey event ID and sends it on direct link resolution, including OS-native opens that bypass web redirects. Restart, network retry and login revalidation reuse the ID. Successful deferred exchanges are counted once by the server. No installation identifier is sent for direct-open analytics. An SDK open means successful resolution, potentially before login; navigation is reported separately when the host acknowledges it with a v2 receipt. Upgrade the backend with the analytics migration before using these counts. Older servers ignore the additive request fields, and old SDKs continue resolving without direct-open counts. Read [the analytics contract](docs/analytics.md) for privacy, 30-day retention, public-client trust limits and delivery behavior.


## General link analytics (v2)

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


## Testing and Live

Every application has one configuration. Set environment to `default`. Testing, Live, Development and Production are retired; update installed integrations before the backend migration. Changing the configured environment changes the SDK storage namespace.

## Short URLs

`handle(url:)` retains duplicate protection. For deliberate repeat activation after leaving a
completed destination, call `reopen(url:)` with no pending journey. It creates a fresh delivery
and event identity and resolves the link again. Apply host authentication/authorization and
acknowledge after navigation. Use `resume` to continue an existing journey; another pending
request is rejected rather than replaced.

Hosts with other Universal Links can use `configuration.canHandle(url:)` to check the full URL
format before claiming a callback, without network or storage access.

Configure the application’s permanent origin, for example `https://aurix.linkbud.io`.
A link is `https://aurix.linkbud.io/Cd34Ef`; its six-character Base62 code is case-sensitive.
There is no route-prefix setting. Direct resolution sends `sdk_id`, `application_id`,
`environment: default` and `code` to `/api/v1/resolve` on that application origin.
Direct and recovery responses must include the matching `link_host` and `short_code`.
The SDK checks the exact HTTPS host, IDs, code and payload before returning a destination.
Credentials, custom ports, extra segments, encoded path aliases, queries and fragments are rejected.

Old prefix URLs and `/l/...` URLs are retired and return 404. SDK 1.x configurations do not
support this contract. Rebuild and distribute host apps with SDK 2.0.0, replace their configured
origin and OS associations, and reshare links. A new origin changes the SDK storage namespace;
finish existing journeys before cutover. Recovery remains limited to matching Play installations
on Android and explicit code entry or reopening the link on iOS. Continuation pages use
`https://aurix.linkbud.io/continue/Cd34Ef` and remain in the browser.


## Privacy and host responsibilities

The package has no third-party dependencies and does not read the clipboard, fingerprint devices or promise automatic App Store recovery. App-private pending state and a random installation identifier are excluded from backup; direct-link analytics use random journey identifiers. Review network/analytics behavior against the host app's App Privacy disclosures. No privacy manifest is currently bundled: the candidate does not use UserDefaults, file-timestamp, disk-space or system-boot-time APIs that require a reason declaration. Reassess manifest requirements whenever APIs/dependencies change; this is not a privacy declaration for the host app.

See [the 2.0.0 release checks](docs/release-2.0.0.md) for artifact preparation and publication gates.

## Custom domains

The API origin is always the application's LinkBud subdomain, for example
`https://aurix.linkbud.io`. Only approved active additional incoming hosts go in
`additionalLinkHosts`. Saved, pending, disconnected and unavailable domains are omitted
from LinkBud's generated configuration. Do not put a customer hostname in `origin`, accept
configuration from an incoming URL, or embed server management credentials in the app.

Backend configuration uses `additional_link_hosts`; map that public list to the SDK's
`additionalLinkHosts` option. The SDK continues to validate response `link_host` against its
managed API origin, with exact app/SDK/environment/code identity checks. The cross-repository
`mobile-domain-contract.json` fixture is checked against actual backend responses and consumed
by Android, Swift and Flutter tests. Native URL vectors also cover IDNs (ASCII punycode),
encoded/wildcard/port/foreign hosts and retired paths.

Keep **both** the managed and approved custom hosts in platform declarations. For Android, use
a separate autoVerify intent filter per exact host, HTTPS only, with `android:pathPattern="/......"`.
For iOS, add one `applinks:HOST` Associated Domains entry per host. `/continue/{code}` is a browser
recovery page and must not be captured by the Android six-character filter or iOS associations.
Flutter needs the declarations for each selected Android/iOS build and its built-in deep-link
handlers disabled as documented above. Use LinkBud's generated app-specific snippets.

A hostname change needs a new signed mobile build and release. DNS/SSL cannot change installed
manifests, entitlements or the native client's allowlist snapshot. The samples keep an empty
additional-host list by default; add approved hosts and matching OS declarations together.
After removal, backend custom-host HTTP endpoints fail closed and generated exports return to
managed-only. A stale installed app may still accept a previously configured host and resolve its
code through the managed API; it cannot resolve another application's code. Update/restart the
app with the new trusted configuration to reject newly received removed-host URLs. Existing
pending journeys deliberately survive allowlist changes and are revalidated through the managed
API; disabled/expired links fail closed. Do not treat domain removal as remote erasure of client
state or installed OS declarations. Flutter's initialized native engine locks configuration until
process restart.

Android Play Install Referrer and explicit iOS recovery still use the managed API origin. Never
claim automatic iOS deferred recovery. Destination hints remain untrusted: revalidate after real
authentication and acknowledge only successful authorized navigation.

Follow the [signed-device acceptance guide](docs/acceptance.md) before rolling
out a host app. Verify signed cold and warm launches, store installation, and public HTTPS
association files for every configured host.
