# iOS SDK 2.0.0 release candidate

The source archive contains the Swift package, its tests and fixtures, and the Xcode sample.
The package retains Swift tools 5.9 and iOS 15 support. The release version will be identified by
the `2.0.0` SwiftPM Git tag.

## Local verification

Extract the archive into a fresh directory. Run `swift test` and build the sample with
`CODE_SIGNING_ALLOWED=NO` for `generic/platform=iOS Simulator` and `generic/platform=iOS`.
Build a clean SwiftPM consumer against the extracted `LinkBud` product.

## Host and release acceptance

Use the managed HTTPS origin and public IDs from Settings → Domains. Supply only the exported
additional incoming-link hosts, with a separate Associated Domains entry for each declared host,
including the managed host. Rebuild the app after changing declarations. Check the six-character
Universal Link path and confirm that `/continue/{code}` stays in the browser. Remove retired
route-prefix configuration from host apps.

Follow [signed-device acceptance](acceptance.md) for Universal Links, explicit recovery,
restart and destination authorization. Resolve the exact public `2.0.0` tag in a clean SwiftPM
consumer after publication.
