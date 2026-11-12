# Unattended internal TestFlight

The approved slots are **09:00, 14:00 and 20:00 Europe/Berlin**, including daylight saving time.
The drmeyers LaunchAgent wakes hourly at minute zero; the controller checks the named Berlin zone before doing work.
`workflow_dispatch` uses the same controller on the exclusive `cassini-ios-release-drmeyers` runner label.
Neither route signs on the rented Mac/pool runners. Both controller and archive worker reject a different hostname.
No scheduler or runner is installed merely by merging this PR. Activation requires the coordinator’s explicit go-ahead.

Existing manual archive/export, GUI/keychain, Apple upload/processing and internal `cassini` group are reused.
The added pipeline admits current `main` at slot start, waits up to 45 minutes if the newest exact-head main CI run from this repository's push/workflow_dispatch/schedule events is still in progress, and reports
unchanged, red, or timed-out main CI as a skip. Every push to main and nightly schedule runs CI; only pull requests retain path filters. After archive and validation it publishes the admitted SHA even if `main` fast-forwarded during the build, provided the admitted SHA remains an ancestor of canonical `main` and its latest CI is still green. A private local mutex
serializes calendar/manual calls; only archive/export hold `~/.cassini-heavy.lock`. Resource/keychain checks happen
inside that lock. A locked keychain fails with the exact Keychain Access unlock instruction; no identity is changed.

Build numbers are allocated from the current marketing version's Apple builds and durable local reservations.
Both app and extension receive the number as a build setting; no version PR or tracked source edit is needed.
Merged PR titles since the last successful TestFlight source become English TestFlight “What’s New” notes.
The CI search paginates past PR/fork runs; neither a green PR merge ref nor a failed fork run approves or blocks main.
Raw titles remain lossless in release-plan.json; release-notes.txt retains valid Unicode verbatim and escapes any
unencodable lone surrogate. TestFlight text replaces angle brackets with
‹/›, strips control/bidi/surrogate characters (keeping readable Unicode and emoji joiners), and is capped at4000
UTF-16 units without splitting supplementary characters. Truncation is marked with an ellipsis; full raw notes remain
in the artifacts. Sanitization is also applied when finalizing a pre-existing pending upload. The first successful release needs an accurate seed commit from the last verified manual upload. Empty notes fail before upload. Oversized sanitized notes retain the marked UTF-16 bound described above.

Export is **Internal**, `testFlightInternalTestingOnly=true`. Archive/export signatures, both bundle versions,
certificate continuity, memory entitlement, Whistle pins/runtime identity and embedded minimum OS are checked.
The controller validates the IPA hash again before upload. Frozen archive checkouts verify their immutable HEAD
and cleanliness, while the controller verifies immediately before upload that the admitted SHA is still an ancestor of canonical `main` and its CI remains green; normal fast-forwards on `main` during archive or validation never discard a valid admitted build. No App Store submission, public release, external group,
tester membership, production metadata, key import/unlock or signing identity edit is implemented.

Apple processing uses `altool --build-status --wait`, bounded by an outer hang guard. No sleep/poll loop or upload
retry is implemented. Upload stdout and stderr are logged separately; JSON is parsed only from stdout.
A delivery UUID in JSON is optional, with an explicit stderr Delivery UUID fallback. If neither is present after a
successful upload, processing is awaited by app/version/build in the same run. No accepted upload fails merely
because altool changed its optional JSON metadata shape. Before upload, durable intent is written; ambiguous interruption never resubmits that build.
The next invocation can finish the existing upload after Apple processing. State advances only after Apple confirms
VALID/unexpired, INTERNAL_ONLY, IN_BETA_TESTING and the existing group's automatic access, and beta notes are written.
If a prior intent has no identifiable Apple build, inspect its retained upload log before manually reconciling state;
never clear intent merely to retry an upload. Failed archive numbers remain reserved; later numbers may have gaps.

## Activation on drmeyers only after explicit coordinator authorization

Use a dedicated clean **main** clone (not an agent feature worktree) at
`~/dev/cassini-ios-daily-host`. Keep the existing GUI tmux session available (`~/bin/gui-tmux.command` in the
logged-in Terminal). Retain the existing private `.p8` under `~/.appstoreconnect/private_keys/` and issuer file
`~/.appstoreconnect/issuer-id.txt`; credentials are never copied to Actions or another Mac.

Create private config `~/.config/cassini/ios-daily-release.json` (0600), using absolute paths:

```json
{
  "source": "/Users/silvio/dev/cassini-ios-daily-host",
  "state_dir": "/Users/silvio/.local/state/cassini-ios-daily",
  "output_root": "/Volumes/DrMeyers2/cassini-ios-daily",
  "notification_file": "/Users/silvio/dev/cassini-coordination/DAILY-TEST-RELEASES-IOS.log",
  "initial_release_head": "<40-character source SHA of the last verified TestFlight>",
  "development_certificate_sha256": "<SHA256 of the existing archive leaf certificate>",
  "distribution_certificate_sha256": "<SHA256 of the existing exported app leaf certificate>"
}
```

Use the known successful archive/export for certificate baselines; do not trust a newly produced identity.
Do not fabricate the source seed from the latest main commit. State and upload intent stay internal/durable when
USB storage is absent; build outputs, Swift/Whistle/package/module caches, GUI temporary files and logs stay external.
A stale `/Volumes/DrMeyers2` directory is refused. Archives/results are retained for diagnosis; monitor external free
space and remove only this pipeline's own obsolete build outputs after preserving required evidence.

Render `scripts/launchd/io.codemyriad.cassini.daily-testflight.plist` by replacing `__CONTROL__` with the dedicated
clone's absolute path and `__HOME__` with the home path, then place it in `~/Library/LaunchAgents/`. Validate it with
`plutil -lint`, then load it using `launchctl bootstrap gui/$(id -u) <plist>`. The hourly wake follows Berlin slots in
Python independently of the host's configured time zone; it does not use an elapsed-time timer. The shell wrapper
only enters the controller. The controller checks the Berlin slot, then takes the shared release mutex BEFORE any
fetch/fast-forward. When it updates itself, it execs the current controller with the same validated inherited lock
file descriptor, so no manual release can enter during deployment. Non-slot hours and busy release slots do not
touch the clone or shared refs. The private lock-transfer CLI options are implementation details, not operator flags.

The LaunchAgent enters `run-in-gui.py` first. An Aqua LaunchAgent by itself does not inherit Terminal's removable-
volume permission: the controller creates external outputs before the archive worker starts. The existing GUI tmux
server must therefore supply Terminal's approved context to the whole scheduled controller. No new permission or
signing identity is created. `CASSINI_RELEASE_STDERR_RELAY=1` applies only inside this launchd bridge: stderr is
forwarded to the coordinator inbox, so the controller does not append the same failure a second time. Direct manual
runs keep their normal notification path. Prove activation by starting a no-upload audit through launchd itself;
a shell/guirun-only dry run cannot establish the LaunchAgent's volume access.

For manual dispatch, register a drmeyers-only Actions runner with label `cassini-ios-release-drmeyers`; this exclusive
label is intentionally absent from general pool selectors. Restrict its runner group to this repository/workflow.
Keep its service in the logged-in user context with Homebrew tools on PATH. Do not attach this label to any rented Mac.
Manual workflow runs accept only `workflow_dispatch` on canonical `refs/heads/main`; the checkout explicitly uses main.
Local manual equivalent: `/usr/bin/python3 scripts/daily-testflight.py --manual --config <private-config>`.

Failures append **`[iOS] daily test release failed: <cause>`** to the coordination inbox and scheduler/Actions logs;
skips and successful build/version/source are logged too. The inbox is a delivery surface for the coordinator to
watch; it is not email/Slack/PR comments. When launchd already sends stderr to that same inode, failures are not
appended a second time. Config/bootstrap failures also go to LaunchAgent stderr in that same inbox.
No live launchd job, signing runner, notification watcher or upload has been activated by the implementation PR.

## Validation

`/usr/bin/python3 scripts/test-daily-testflight.py` tests DST slots, paginated push/manual/scheduled CI provenance (excluding PR/fork runs), sanitized Unicode/UTF-16 notes, version-specific numbering,
failed reservations, durable intent before upload, no duplicate on an ambiguous upload, resumed finalization,
internal-only guards, JWT redaction and scheduler/workflow routing without network, signing, GUI or simulators.
`test-testflight-archive.py` uses real temporary linked Git worktrees to verify shared-ref advances are harmless
but changed HEAD or dirty releases are refused, and checks that main pushes always have CI. Scheduler tests use
process/pipe events to verify active releases (also across exec) prevent any hourly clone mutation.
`test-ci-runner-selection.py` retains the general CI trust matrix and separately checks every signing-event/ref/repo
combination. CI runs both. Real unattended signing remains an activation check on drmeyers after merge/configuration;
this PR does not claim a TestFlight upload was performed.

Apple references: [internal-only build audience](https://developer.apple.com/documentation/appstoreconnectapi/buildaudiencetype),
[beta build notes](https://developer.apple.com/documentation/appstoreconnectapi/beta-build-localizations),
[existing group attributes](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-betagroups).
