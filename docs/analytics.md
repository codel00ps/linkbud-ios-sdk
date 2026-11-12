# SDK analytics contract

LinkBud measures link resolution and host-reported navigation separately. A resolved destination is an untrusted navigation hint; it does not authorize protected content or prove navigation, installation, a unique person or a business conversion.

## Resolution and navigation

- Native direct-link resolution persists a random `event_id` before transmission. Network retries, process restart and login revalidation reuse it. A deliberate `reopen` after completing a URL creates a fresh delivery and event identity and validates the link again with the server.
- Android Play handoff and explicit iOS code recovery use installation-bound claims. A lost response can be retried by the claiming installation. iOS does not provide automatic recovery after App Store installation.
- `acknowledge` belongs after successful, authorized, idempotent host navigation. With a v2 server receipt, it atomically queues a destination-open report and completes the local journey. A login screen waiting for credentials is not completed navigation.
- `destinationFailed` completes an abandoned journey and queues a failure report. Only `navigation`, `authentication`, `permission`, `unavailable` and `unsupported` are accepted. Never send business data in a reason.
- Older servers without analytics receipts still resolve and acknowledge journeys without outcome reports.

## Delivery and privacy

The outcome report contains only an opaque receipt, outcome, elapsed SDK journey time and an optional fixed failure reason. It does not contain the destination, user credentials, installation identifier or host account ID. Direct-link resolution does not send an installation identifier; deferred claim endpoints do.

Up to 16 reports persist in app-private, backup-excluded storage. Delivery is best effort: later SDK activity retries transient failures with bounded delays, terminal responses drop reports, and receipts expire. There is no background polling or guaranteed delivery. A reporting failure does not undo completed navigation. Hosts must review these behaviors for their own privacy disclosures and avoid logging capabilities, receipts, installation IDs or destination queries.

Public SDK identifiers and event IDs are not app attestation. Resolution counts can be fabricated by a knowledgeable public client, and a leaked recovery capability can win first claim. Analytics must not be used as authorization, billing authority or proof of a download.

The server's raw analytics events and deduplication keys have a 30-day retention window; actual deletion depends on server maintenance. Infrastructure logs and backups have separate operator policies. Server deployment, queue workers and retention are backend operator responsibilities, not functions of the mobile SDK.

## Validate in the host

Check resolution separately from authorized navigation. Exercise acknowledgment exactly once, duplicate callbacks, deliberate reopening, abandoned navigation, offline report persistence, retry after restart and receipt expiry. A crash between navigation and acknowledgment still requires host-side idempotency. Record sanitized outcomes and timing, never raw receipts or destination queries.
