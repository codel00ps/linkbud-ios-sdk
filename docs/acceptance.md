# iOS host acceptance

Follow [the SDK guide](../README.md). Use environment `default`, the public HTTPS origin, application/SDK IDs, the immutable three-character `routePrefix`, and the registered Apple team/bundle identity. Provision a physical device with Associated Domains and an operator-owned App Store/TestFlight build. The sample's simulated login is not authentication evidence.

## Universal Links

1. Serve `/.well-known/apple-app-site-association` with the matching team/bundle and scoped paths, HTTPS and no redirects. Allow for Apple CDN/device cache propagation.
2. Set `applinks:YOUR_HOST` in the host entitlement and enable the matching provisioning capability.
3. Tap a real current-format `https://YOUR_HOST/Ab1/Cd34Ef` URL from Notes or another domain while the host is stopped, running and backgrounded. Use the actual prefix/code from LinkBud. Check iOS 15, a current iOS release and iPad where supported.
4. Hosts with other Universal Links should check `configuration.canHandle(url:)` before forwarding. Never claim another integration's URL.

## Explicit recovery after installation

Uninstall, open the link's continuation page and explicitly request a recovery code. GET/HEAD alone must not issue a code. Install the signed distributed app and launch normally: no destination should appear until the user enters the code. Submit it, retain the hint across real login/restart, revalidate, authorize, navigate and acknowledge. A claiming installation can retry a lost response; another installation cannot reuse its code. Test malformed, wrong-context, expired and already-claimed codes, identity changes, canceled installation and expiry after 30 minutes or earlier link expiry. Reopening the original link depends on current OS association state. Confirm there is no automatic App Store payload transfer, fingerprinting or silent clipboard access. Inspect backup exclusion and verify reinstall does not restore pending state.

## Shared failure and navigation checks

- Keep a pending journey through real login and process restart. Call `resume` after authentication, authorize the returned route, navigate idempotently and only then acknowledge. Restart again and confirm no repeated navigation.
- Disable, delete or expire the link while login is pending. Revalidation must prevent stale cached routing. Reject another host, wrong application/environment/prefix, credentials, ports, encoded path aliases, queries and fragments.
- Deliver duplicate OS callbacks and confirm the completed URL returns `alreadyAcknowledged`. After leaving the destination, deliberately call `reopen` and confirm a new delivery/event identity and fresh server validation. Reopening must not replace another pending journey or bypass link unavailability.
- Restart offline, reconnect and honor `retryAt`; test 429/5xx, lost responses, expiry and storage failure. Keep navigation responsive and prevent a second distinct link from overwriting the current journey.
- Test v2 destination reports after acknowledgment/failure, offline persistence and retry. Inspect aggregate counts without storing receipt/token values. See [analytics](analytics.md).

## Evidence

Record date, device/OS, toolchain, host app version/commit, public origin, app identity, install source, association diagnostics and cold/warm/restart/authentication/recovery outcomes. Use disposable data. Never record credentials, codes, tokens, installation IDs or destination queries. Unit tests and unsigned builds do not establish signed-device associations, store installation or real host authentication. Rerun this protocol for every host app and release candidate.
