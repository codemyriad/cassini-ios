# Distribution

How to build Cassini for TestFlight and the App Store, and what is still missing. The project is not released yet.

## Identity

| | App | Live Activity extension |
|---|---|---|
| Bundle ID | `app.codemyriad.cassini` | `app.codemyriad.cassini.activity` |
| Version | `MARKETING_VERSION` 0.1.0 | 0.1.0 |
| Build | `CURRENT_PROJECT_VERSION` 1 | 1 |

Both are set in `project.yml`, and the app and the extension must carry the same version and build. Raise the build
number for every upload; App Store Connect refuses a build number it has already seen for that version.

Signing is automatic (`CODE_SIGN_STYLE: Automatic`), and `DEVELOPMENT_TEAM` is empty until Codemyriad's Apple Developer
organization membership is active. Then set it to the team ID in `project.yml`, run `xcodegen generate`, and register
both bundle IDs.

## Checking a build without signing

An unsigned Release archive shows that the app, the extension, their privacy manifests and `Info.plist` build for a
device, without any certificate:

```sh
xcodegen generate
xcodebuild -project Cassini.xcodeproj -scheme Cassini -configuration Release \
  -destination generic/platform=iOS -archivePath build/Cassini.xcarchive CODE_SIGNING_ALLOWED=NO archive
```

An unsigned archive does not apply entitlements and cannot be uploaded. It was last checked with Xcode 27 on the plain
build at `de5868d`: app and extension present, version 0.1.0 build 1, minimum iOS 26, `ITSAppUsesNonExemptEncryption`
false. The plain build links no native speech runtime. Builds with `CASSINI_SHERPA_LOCAL=1` (Parakeet Ultra and the
speaker models) are for development until the runtime is published as a release asset
([README](../README.md#native-speech-runtime-in-progress)), and are not for upload.

Never commit archives, exported `.ipa` files, certificates, provisioning profiles or App Store Connect API keys.

## Before the first TestFlight upload

1. The organization membership is active, and `DEVELOPMENT_TEAM` is set (above).
2. Automatic signing makes a profile that grants `com.apple.developer.kernel.increased-memory-limit`
   (`Cassini/Cassini.entitlements`). Parakeet Ultra needs it on devices with less memory.
3. A signed archive (Xcode Organizer, or `xcodebuild archive` without `CODE_SIGNING_ALLOWED=NO`) validates with no
   ITMS-91053 (missing required-reason API) warning. After the native runtime is linked, check the app binary's imports
   again (`nm -u`) against `Cassini/Resources/PrivacyInfo.xcprivacy`.
4. The App Store Connect record exists for `app.codemyriad.cassini`.

## App Store Connect answers

- **App Privacy:** Data Not Collected; no tracking. This matches both privacy manifests (`NSPrivacyCollectedDataTypes`
  empty, `NSPrivacyTracking` false) and `Privacy.txt`: recordings, transcripts and voiceprints stay on the device, and
  the only network use is downloading pinned models.
- **Privacy policy URL:** still to be decided; the default is to host it next to Android's.
- **Export compliance:** answered in the build (`ITSAppUsesNonExemptEncryption` false), so no question per upload.
- **App Review note:** explain that background audio (`UIBackgroundModes` audio) keeps a recording going with the screen
  locked and lets playback continue on the lock screen, and that `processing` finishes a running transcription. Mention
  that the speech and speaker models (about 700 MB) download only after the user agrees, and are data, not code.
