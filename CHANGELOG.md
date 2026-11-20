# 1.0.1 — November 12, 2026

## 2.0.0 — Unreleased

- Prepare optional `additionalLinkHosts` for incoming URLs while keeping API/response identity
  and persisted journeys on the managed origin. Defaults/generated configs stay managed-only.
- Cover exact host parsing, cross-host deduplication/restart, recovery and unchanged response
  authority with shared native fixtures. Custom domains remain inactive; no publication.

- Replace route-prefix configuration with a permanent application HTTPS origin and root-level six-character link codes.
- Bind direct and recovery responses to the configured application host and code; reject retired URL formats.
- Update samples, OS associations and setup documentation. A host app rebuild and coordinated backend cutover are required.


- Align SDK/sample release metadata to 1.0.1 and configuration to the backend's single `default` environment. Retired environment names must be migrated before rebuilding.

- Expose side-effect-free URL ownership checks for hosts and Flutter.
- Extend shared URL and reopened-journey restart/backoff regression coverage.
- Bundle acceptance and analytics guides.

# 1.0.0 — November 11, 2026

- Establish the stable 1.x public API baseline, retaining the existing runtime protocol and stored journeys from 0.4.0.
- Align SDK/sample metadata and installation guidance to 1.0.0; document compatibility and privacy responsibilities.
- Record owner-confirmed real-device link and login/restart acceptance; Android Play install/referrer and Flutter on both platforms were also confirmed in the coordinated release audit.
- Preserve explicit iOS recovery, host-owned authentication/authorization, bounded retries and navigation acknowledgment.

Earlier entries below describe historical preview milestones; their acceptance notes are not the current release status.

# 0.4.0 preview

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
