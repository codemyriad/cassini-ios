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
their privacy manifests, version 0.1.0 build 2, minimum iOS 26 (the target then; it is now iOS 18.0, and no archive
has been checked at 18.0 yet), `ITSAppUsesNonExemptEncryption` false, arm64 only.
Sizes of the unsigned archive of the final PR D tree, against the `51bc71b` tree built without the two binary targets
(the share includes the runtime's licence texts, 0.3 MiB of them ONNX Runtime's own notices):

| | With the runtime | Without | Runtime's share |
|---|---|---|---|
| `Cassini.app` on disk | 32.4 MiB (33 164 KiB) | 9.8 MiB (10 072 KiB) | +22.6 MiB |
| Main binary `Cassini` | 30 370 464 B | 7 160 208 B | +23 210 256 B |
| `Cassini.app` zipped (`ditto -c -k`), about the download | 12 686 624 B | 4 190 847 B | +8 495 777 B |

The binary's `__TEXT` is 28.6 MB. App Store Connect's own figures (per device, after thinning and encryption) come only
with an upload. Whistle's model and engine are in the app; they came after these measurements and are not in them.
Parakeet Ultra (443 MB) with its speech detector (458 KB), and the speaker models (88 MB), download on consent.

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

Since 2026-11-05 the team has a registered device, so archives are signed normally ("Uploads" below); the unsigned flow in this section is only for local checks.

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

The archive is signed with a development identity from the login keychain, so over SSH it fails at CodeSign with
`errSecInternalComponent` (the SSH session cannot use the keychain). Run the `xcodebuild archive` in the GUI login
session instead. On drmeyers, with the existing `gui` tmux session:

```sh
python3 scripts/run-in-gui.py lockf -k -t 3600 ~/.cassini-heavy.lock xcodebuild archive …
```

The runner preserves the caller's working directory and PATH and streams the command's combined output. It waits
on filesystem events for output and completion, then returns the command's exit status without a drain delay.
`GUIRUN_TIMEOUT` is an upper bound (default 86400 seconds); on timeout the GUI command continues and the error
reports its retained log. Interrupting the local watcher or closing its output pipe also preserves the GUI command
and reports its pane and log. If the GUI process exits without a completion status, the runner reports that failure
instead of waiting for the deadline. If the GUI session is absent, start `~/bin/gui-tmux.command` in the Mac's logged-in
Terminal, then retry. The shared `~/bin/guirun` tool is unchanged. `python3 scripts/test-run-in-gui.py` checks the
runner with a fake tmux launcher and real filesystem events, without a GUI or simulator.

The export and the upload sign in the cloud and work over SSH.

### Before an upload

1. `xcrun altool --validate-app` passes. Every bundled framework's `CFBundleVersion` must be up to three
   period-separated integers, at most 18 characters (errors 90058/90059); `scripts/build-sherpa-xcframework.sh`
   writes `1.13.7`. It does not check that each bundle's `MinimumOSVersion` matches its binary (`otool -l`,
   `LC_BUILD_VERSION` minos); Apple's processing does, after the upload (90208, seen with `xcrun altool
   --build-status --delivery-id <id>`). The app embeds one framework, the private `CassiniWhistleRuntime.framework`:
   `scripts/bundle-whistle.py` links its binary for `Whistle/pins.json` `deploymentTarget` (18.0, the app's target)
   and writes the same value as its `MinimumOSVersion`, and `scripts/check-embedded-minos.py` (run by
   `scripts/test.sh` after every build for testing) fails if any embedded binary or plist needs a newer iOS than the
   app. The sherpa runtime's xcframeworks are static, and a build step drops the stubs Xcode embeds for them.
2. The archive validates with no ITMS-91053 (missing required-reason API) warning. After a change of the native
   runtime, check the app binary's imports again (`nm -u`) against `Cassini/Resources/PrivacyInfo.xcprivacy`. Last
   checked on the archive above: of Apple's required-reason symbols the binary imports only `stat` and `fstat`, which
   the runtime adds (file timestamp: `C617.1`, the model files in the app container, already declared), besides the
   `NSUserDefaults`, `NSFileManager` and `NSProcessInfo` classes the app used before (`CA92.1`, `C617.1`, `E174.1`,
   `85F4.1`, `35F9.1`, all declared). It imports none of `getattrlist`, `getattrlistbulk`, `fgetattrlist`,
   `getattrlistat`, `fstatat`, `lstat`, `statfs`, `fstatfs`, `statvfs`, `fstatvfs` or `mach_absolute_time`; the
   runtime's `sysctl`, `sysctlbyname` and `clock_gettime` are not on Apple's list. No category is new.
3. The upload goes to the App Store Connect record for `io.codemyriad.cassini` (SKU `cassini`). An earlier record for
   `app.codemyriad.cassini` (SKU `cassini-ios`, TestFlight build 0.1.0 (1)) is retired: never upload to it. Builds
   for the new record start at build number 2, so they are not confused with that build 1.
4. A processed build is installable only by testers in a TestFlight group; the internal group "cassini" gets every build.

## App Store Connect answers

- **App Privacy:** Data Not Collected; no tracking. This matches both privacy manifests (`NSPrivacyCollectedDataTypes`
  empty, `NSPrivacyTracking` false) and `Privacy.txt`: recordings, transcripts and voiceprints stay on the device, and
  the only network use is downloading pinned models.
- **Privacy policy URL:** https://cassini.talk/privacy/ios/ (the overview for every app is
  https://cassini.talk/privacy/). That page is the legal text, which the coordinator keeps outside this repository.
  The technical page, https://cassini.talk/privacy/ios/technical/, is published from
  `Cassini/Resources/Licenses/Privacy.txt`, the text Settings shows, so those two say the same. When `Privacy.txt`
  changes, ask the coordinator to republish the technical page and to check the legal page against it.
  The legal page's URL goes in App Store Connect under App Information → Privacy Policy URL.
- **Compatible devices:** the minimum OS in the store listing comes from the build (`MinimumOSVersion` 18.0). The
  app sets no `UIRequiredDeviceCapabilities`, so the store lists every iPhone and iPad on iOS 18 or later, the iPhone
  XR, XS and XS Max and the iPad (7th generation) included. That iPad gets no speech engine ([iOS 18](ios18.md)): no
  Whistle (the A10 lacks its CPU features), no Parakeet Ultra (3 GB) and no Apple speech on iPadOS 18. It records,
  plays, searches and exports but cannot transcribe. An app cannot exclude that device by minimum OS, and
  `UIRequiredDeviceCapabilities` has no key that separates the A10 from the A12 in a useful way (not checked further).
  Put in the description and in the App Review note: "Transcription needs an A12 chip or later, so it is not available
  on the iPad (7th generation)." That follows from the rules above; Whistle on the A12 has been measured on iPadOS 26
  only, not on iOS 18.
- **Export compliance:** answered in the build (`ITSAppUsesNonExemptEncryption` false), so no question per upload.
- **App Review note:** explain that background audio (`UIBackgroundModes` audio) keeps a recording going with the screen
  locked and lets playback continue on the lock screen, and that `processing` finishes a running transcription on
  iOS 26 and later, through continued processing. Add: "On iOS 18, which has no continued processing, a transcription
  that is still running when iOS ends the app's background time pauses, and the user resumes it from the app." (see
  [iOS 18](ios18.md)). Add the A12 sentence from **Compatible devices** above. Mention that the Whistle speech model
  and its native engine are in the app, so transcribing with Whistle needs no download. On devices with enough memory,
  Parakeet Ultra with its speech detector (about 444 MB), and the speaker models (about 88 MB), download from
  `dist.gocassini.com` only after the user agrees, and are data, not code.
- **Not yet verified:** no build at 18.0 has been archived, validated or uploaded to App Store Connect. The 90208
  check (each embedded `MinimumOSVersion` against its binary's minos) is covered locally by
  `scripts/check-embedded-minos.py`, but Apple's processing of an 18.0 build has not been seen yet. On iOS 18 the
  full test leg passed on the iOS 18.2 simulator ([iOS 18](ios18.md)), and two AWS Device Farm runs on 2026-11-10
  (iPhone 11 on iOS 18.6.2, iPhone 15 on iOS 18.0) ran the Whistle tests in a Debug build with development signing.
  No A12 or A10 device on iOS 18 and no Release build has run the app.
