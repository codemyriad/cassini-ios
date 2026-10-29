# Distribution

How to build Cassini for TestFlight and the App Store, and what is still missing. The project is not released yet.

## Identity

| | App | Live Activity extension |
|---|---|---|
| Bundle ID | `io.codemyriad.cassini` | `io.codemyriad.cassini.activity` |
| Version | `MARKETING_VERSION` 0.1.0 | 0.1.0 |
| Build | `CURRENT_PROJECT_VERSION` 2 | 2 |

Both are set in `project.yml`, and the app and the extension must carry the same version and build. Raise the build
number for every upload; App Store Connect refuses a build number it has already seen for that version.

Signing is automatic (`CODE_SIGN_STYLE: Automatic`). Codemyriad OU's team ID, `4LS8W738Y3`, is set in
`project.yml` and inherited by the app and Live Activity extension. Run `xcodegen generate` after changing it.
Sign in to the organization's Apple Account in Xcode on the build Mac; automatic provisioning still needs access
to that account and its signing certificates. Register both bundle IDs, or let Xcode register them during provisioning.

## Checking a build without signing

An unsigned Release archive shows that the app, the extension, their privacy manifests and `Info.plist` build for a
device, without any certificate:

```sh
xcodegen generate
xcodebuild -project Cassini.xcodeproj -scheme Cassini -configuration Release \
  -destination generic/platform=iOS -archivePath build/Cassini.xcarchive CODE_SIGNING_ALLOWED=NO archive
```

An unsigned archive carries no entitlements and no signature; exported as below, it is signed for the App Store but
keeps no entitlements either. It was last checked with Xcode 27 on the plain
build at `de5868d`: app and extension present, version 0.1.0 build 1, minimum iOS 26, `ITSAppUsesNonExemptEncryption`
false. The plain build links no native speech runtime. Builds with `CASSINI_SHERPA_LOCAL=1` (Parakeet Ultra and the
speaker models) are for development until the runtime is published as a release asset
([README](../README.md#native-speech-runtime-in-progress)), and are not for upload.

Never commit archives, exported `.ipa` files, certificates, provisioning profiles or App Store Connect API keys.
`build/` is ignored for the first two.

## Signing and uploading

The team signs with Xcode's cloud-managed **Apple Distribution: Codemyriad OU** certificate and Xcode-managed "iOS
Team Store" profiles, both made by automatic signing through an App Store Connect API key. Its private key stays with
Apple, so it is not in any keychain and manual signing cannot use it. The key works over SSH, where the login
keychain, and with it an Apple Account signed in to Xcode, is not available.

- **API key:** a Team key with the Admin role (App Store Connect → Users and Access → Integrations → App Store Connect
  API), whose `.p8` lives in `~/.appstoreconnect/private_keys/` with mode 600. Every command below needs its key ID and
  the issuer ID shown above the keys.
- **Build number:** raise `CURRENT_PROJECT_VERSION` in `project.yml` for every upload (above).

### Until a device is registered: the plain build only

`xcodebuild archive` with automatic signing signs for development first, and a development profile needs at least one
device registered to the team; with none it fails with "Your team has no devices from which to generate a provisioning
profile". Until one is registered, the archive is made unsigned and signed only by the export:

```sh
xcodegen generate
xcodebuild -project Cassini.xcodeproj -scheme Cassini -configuration Release -destination generic/platform=iOS \
  -archivePath build/Cassini.xcarchive CODE_SIGNING_ALLOWED=NO archive
xcodebuild -exportArchive -archivePath build/Cassini.xcarchive -exportPath build/export \
  -exportOptionsPlist ExportOptions.plist -allowProvisioningUpdates \
  -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 \
  -authenticationKeyID <KEY_ID> -authenticationKeyIssuerID <ISSUER_ID>
codesign -d --entitlements - build/export/Payload/Cassini.app   # after unzipping build/export/Cassini.ipa
xcrun altool --upload-app -f build/export/Cassini.ipa -t ios --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
```

`ExportOptions.plist` (kept outside the repository) has `method` `app-store-connect`, `destination` `export`,
`teamID` `4LS8W738Y3`, `signingStyle` `automatic` and `manageAppVersionAndBuildNumber` false.

Such a build has **no `com.apple.developer.kernel.increased-memory-limit`**: the unsigned archive carries no
entitlements for the export to keep. The plain build links no Parakeet runtime, so that changes nothing for it. Build
0.1.0 (2) was uploaded this way on 2026-10-29.

### Parakeet builds need a registered device

Parakeet Ultra needs the increased memory limit on devices with less memory, so a build with the native runtime must
keep `Cassini/Cassini.entitlements`. That takes a signed archive, which takes a development profile, which takes a
device registered to the team (developer.apple.com → Certificates, Identifiers & Profiles → Devices, with the iPhone's
UDID). Once one is, the archive is signed normally with the same API key flags and keeps the entitlement; check it with
`codesign -d --entitlements -` before uploading. The App Store profile for `io.codemyriad.cassini` already grants it.

### Before an upload

1. The archive validates with no ITMS-91053 (missing required-reason API) warning. After the native runtime is
   linked, check the app binary's imports again (`nm -u`) against `Cassini/Resources/PrivacyInfo.xcprivacy`.
2. The upload goes to the App Store Connect record for `io.codemyriad.cassini` (SKU `cassini`). An earlier record for
   `app.codemyriad.cassini` (SKU `cassini-ios`, TestFlight build 0.1.0 (1)) is retired: never upload to it. Builds
   for the new record start at build number 2, so they are not confused with that build 1.
3. A processed build is installable only by testers in a TestFlight group; the new record starts with none.

## App Store Connect answers

- **App Privacy:** Data Not Collected; no tracking. This matches both privacy manifests (`NSPrivacyCollectedDataTypes`
  empty, `NSPrivacyTracking` false) and `Privacy.txt`: recordings, transcripts and voiceprints stay on the device, and
  the only network use is downloading pinned models.
- **Privacy policy URL:** still to be decided; the default is to host it next to Android's.
- **Export compliance:** answered in the build (`ITSAppUsesNonExemptEncryption` false), so no question per upload.
- **App Review note:** explain that background audio (`UIBackgroundModes` audio) keeps a recording going with the screen
  locked and lets playback continue on the lock screen, and that `processing` finishes a running transcription. Mention
  that the speech and speaker models (about 700 MB) download only after the user agrees, and are data, not code.
