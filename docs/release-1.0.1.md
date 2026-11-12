# iOS 1.0.1 release candidate

The Swift package/source distribution is prepared for tag `1.0.1`. Swift tools 5.9, iOS 15 and the existing persisted journey format are retained. Version 1.0.0 remains immutable.

```sh
swift test
xcodebuild -project Sample/LinkBudSample.xcodeproj -scheme LinkBudSample \
  -destination 'generic/platform=iOS' -configuration Release \
  -derivedDataPath /tmp/linkbud-ios-101 CODE_SIGNING_ALLOWED=NO build
```

Inspect the source archive, including test URL fixtures and bundled guides. Exclude `.build`, `.swiftpm`, local configuration, signing/provisioning material and user-specific Xcode data. Extract it into a fresh directory and run `swift test` without the original checkout.

Commit the reviewed source and create a new 1.0.1 semantic-version tag in the public repository; never move an existing tag. After publication, resolve exactly 1.0.1 in a clean SPM consumer. Signed Universal Links, explicit recovery and real host authentication remain [host acceptance](acceptance.md) checks. No App Store automatic deferred recovery is introduced.

## Host migration

Configure `environment` as `default`, matching the backend's single application configuration. Testing/Live and Development/Production names are retired; changing the configured environment changes the storage namespace. Coordinate this with the existing backend rollout and finish/revalidate outstanding journeys before changing host configuration. Use the real immutable short-link prefix and rebuild/distribute the host app.

Android and iOS now both reject legacy URL queries/fragments. Share canonical URLs. Reopening is explicit, server-validated and intended for a deliberate repeat user activation; duplicate OS callbacks keep normal acknowledgment protection. No database migration is introduced by this SDK patch.
