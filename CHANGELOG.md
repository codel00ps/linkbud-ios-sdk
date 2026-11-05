# 0.4.0 preview · unpublished

- Add optional public `routePrefix` configuration and strict six-character short-path resolution.
- Bind direct/recovery responses to the configured prefix; preserve persisted installation identity.
- Retain legacy parsing during rollout; server-side activation rejects old slug resolution.
- Update samples and Flutter native snapshots. Store/device release acceptance remains separate.

# 0.3.0 preview · unpublished

- Support Testing/Live and matching Development/Production URL aliases.
- Reject retired Staging configuration; preserve strict application/environment isolation.

# 0.3.0 preview · unpublished

- General analytics v2: persistent destination outcomes, bounded offline retry, and fixed failure reasons.
- Existing resolution and authentication contracts remain supported.

# Changelog

## Unreleased · 2026-10-27

- Add a persisted random per-journey analytics ID for direct-link resolutions; reuse it across retry, restart and login revalidation without sending installation identity.
- Keep existing stored journeys readable and preserve local acknowledgment/navigation behavior. See the analytics guide for measurement and privacy limits.

## 0.1.0 — 2026-10-26 · local preview

- Add an iOS 15+ Swift package and SwiftUI sample for Universal Link entry points and explicit recovery-code entry.
- Persist one pending journey across login/restarts, revalidate before routing, and acknowledge locally with bounded deduplication.
- Validate environment paths, API tuples, payloads and expiry; bound offline/server retries and refuse redirects.
- Keep iOS recovery user-initiated, expiring and installation-bound. No clipboard reads, fingerprinting or automatic install recovery.
- Signed-device Universal Links, actual App Store installation and real host authentication require acceptance evidence before release.
