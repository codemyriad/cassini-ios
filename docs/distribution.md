# Distribution

How to build Cassini for TestFlight and the App Store, and what is still missing. The project is not released yet.

## Identity

| | App | Live Activity extension |
|---|---|---|
| Name | "Cassini talk" (`CFBundleDisplayName`, D45) | "Cassini talk" |
| Bundle ID | `io.codemyriad.cassini` | `io.codemyriad.cassini.activity` |
| Version | `MARKETING_VERSION` 0.1.0 | 0.1.0 |
| Build | `CURRENT_PROJECT_VERSION` 2 | 2 |

Both are set in `project.yml`, and the app and the extension must carry the same version and build. Raise the build
number for every upload; App Store Connect refuses a build number it has already seen for that version.

The home-screen name is set in the two `Info.plist` files, and the screens that name the product (the Library's
wordmark, About, Now Playing) use `ProductName.full`; running sentences keep "Cassini". The App Store Connect record's
name is changed in App Store Connect by Silvio, and the bundle IDs stay as they are (D-891).

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
keeps no entitlements either. Every build links the native speech runtime, the sherpa-onnx release
`v1.13.7-cassini-mobile.1` (fork `0c2ee3f`, ONNX Runtime 1.27.1; [README](../README.md#native-speech-runtime)).
Builds with `CASSINI_SHERPA_LOCAL=1` link a local build of it instead and are for development, not for upload.

It was last checked with Xcode 27 on the final PR D tree (2026-11-02): app and extension present, both with
their privacy manifests, version 0.1.0 build 2, minimum iOS 26, `ITSAppUsesNonExemptEncryption` false, arm64 only.
Sizes of the unsigned archive of the final PR D tree, against the `51bc71b` tree built without the two binary targets
(the share includes the runtime's licence texts, 0.3 MiB of them ONNX Runtime's own notices):

| | With the runtime | Without | Runtime's share |
|---|---|---|---|
| `Cassini.app` on disk | 32.4 MiB (33 164 KiB) | 9.8 MiB (10 072 KiB) | +22.6 MiB |
| Main binary `Cassini` | 30 370 464 B | 7 160 208 B | +23 210 256 B |
| `Cassini.app` zipped (`ditto -c -k`), about the download | 12 686 624 B | 4 190 847 B | +8 495 777 B |

The binary's `__TEXT` is 28.6 MB. App Store Connect's own figures (per device, after thinning and encryption) come only
with an upload. The models are not in the app: Parakeet Ultra (443 MB) with its speech detector (458 KB), and the
speaker models (88 MB), download on consent.

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

### Every build links the runtime: uploads wait for a registered device

There is no runtime-free build any more: every iOS build links the sherpa-onnx runtime and picks Parakeet Ultra on a
device with at least 5 GiB of memory. Parakeet Ultra needs `com.apple.developer.kernel.increased-memory-limit` on
devices with less headroom, and only a signed archive keeps that entitlement (below). So **do not upload an unsigned
archive**: the flow below, which build 0.1.0 (2) used on 2026-10-29 before the runtime was linked, ships Ultra without
the entitlement, leaving only the 5 GiB rule and the `os_proc_available_memory` check before each window between a
large recording and the memory limit. It stays here for local checks of the export (size, `nm -u`, entitlements).

`xcodebuild archive` with automatic signing signs for development first, and a development profile needs at least one
device registered to the team; with none it fails with "Your team has no devices from which to generate a provisioning
profile". Without one, the archive can only be made unsigned and signed by the export:

```sh
xcodegen generate
xcodebuild -project Cassini.xcodeproj -scheme Cassini -configuration Release -destination generic/platform=iOS \
  -archivePath build/Cassini.xcarchive CODE_SIGNING_ALLOWED=NO archive
xcodebuild -exportArchive -archivePath build/Cassini.xcarchive -exportPath build/export \
  -exportOptionsPlist ExportOptions.plist -allowProvisioningUpdates \
  -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 \
  -authenticationKeyID <KEY_ID> -authenticationKeyIssuerID <ISSUER_ID>
codesign -d --entitlements - build/export/Payload/Cassini.app   # after unzipping build/export/Cassini.ipa
```

`ExportOptions.plist` (kept outside the repository) has `method` `app-store-connect`, `destination` `export`,
`teamID` `4LS8W738Y3`, `signingStyle` `automatic` and `manageAppVersionAndBuildNumber` false.

Such a build has **no `com.apple.developer.kernel.increased-memory-limit`**: the unsigned archive carries no
entitlements for the export to keep (`codesign -d --entitlements -` shows none). That is why it is not uploaded.

### Uploads: a signed archive, from a registered device

Every uploaded build must keep `Cassini/Cassini.entitlements`. That takes a signed archive, which takes a development
profile, which takes a device registered to the team (developer.apple.com → Certificates, Identifiers & Profiles →
Devices, with the iPhone's UDID). Once one is, the archive is signed normally with the same API key flags and keeps
the entitlement; check it with `codesign -d --entitlements -` before uploading
(`xcrun altool --upload-app -f build/export/Cassini.ipa -t ios --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>`). The App
Store profile for `io.codemyriad.cassini` already grants it.

### Before an upload

1. The archive validates with no ITMS-91053 (missing required-reason API) warning. After a change of the native
   runtime, check the app binary's imports again (`nm -u`) against `Cassini/Resources/PrivacyInfo.xcprivacy`. Last
   checked on the archive above: of Apple's required-reason symbols the binary imports only `stat` and `fstat`, which
   the runtime adds (file timestamp: `C617.1`, the model files in the app container, already declared), besides the
   `NSUserDefaults`, `NSFileManager` and `NSProcessInfo` classes the app used before (`CA92.1`, `C617.1`, `E174.1`,
   `85F4.1`, `35F9.1`, all declared). It imports none of `getattrlist`, `getattrlistbulk`, `fgetattrlist`,
   `getattrlistat`, `fstatat`, `lstat`, `statfs`, `fstatfs`, `statvfs`, `fstatvfs` or `mach_absolute_time`; the
   runtime's `sysctl`, `sysctlbyname` and `clock_gettime` are not on Apple's list. No category is new.
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
  that the speech and speaker models (about 531 MB) download only after the user agrees, and are data, not code.
