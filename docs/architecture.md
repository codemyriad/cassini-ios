# Architecture

`CassiniCore` preserves the existing portable Ogg Opus document implementation, including integrity verification and transcript variants. `CassiniNotebook` depends on it and owns the note/transcript/bookmark model, deterministic text and subtitle exports, search rules, time formatting, and atomic metadata storage. It is testable on the host with Swift Testing.

The app uses SwiftUI and Observation. `AppStore` coordinates navigation, durable mutations, import, recovery, and a single transcription worker. `Recorder`, `Player`, and `SpeechService` own their respective AVFoundation / Speech lifecycles. FluidAudio supplies the on-device speaker pipeline; libopus supplies packet encoding/decoding. No audio-processing server is used. Network access in the inference dependency is enabled only during explicitly permitted model preparation.

## Storage

Each note lives under Application Support/Cassini/<UUID>/:

- `note.json`: versioned metadata, transcript segments and word times, bookmarks, title, state, favorites, trash timestamp, playback position, and sampled waveform.
- `capture.caf`: original PCM during recording, and the fallback when compression is interrupted.
- `audio.m4a`: successfully compressed capture; imports retain their source extension.

Metadata is written atomically before updating observable UI state. One corrupt document cannot prevent other notes loading. Unknown versions and damaged files are kept in place and reported. No whole-library destructive reset or migration fallback is used.

The application support directory uses protection until first device unlock, allowing a started recording to continue after screen lock. Files are eligible for system backup; app copy explains this. Permanent deletion removes voice samples first and then the note directory. Individual and bulk deletion require confirmation; 30-day automatic expiry follows calendar days in the current device time zone and runs on activation/trash access. Exports use unique temporary directories and the system share sheet.

## Recording lifecycle

The metadata document is created before microphone capture begins. PCM CAF avoids relying on M4A finalization for the only copy of a recording. Finish closes the recorder, seals duration/status, inspects the file, then creates the compressed copy. Only after the metadata points to that copy is the original removed. A failed export leaves the source authoritative.

An interruption or removed input pauses recording without automatically resuming a different microphone. A low-space check or recorder error triggers a best-effort finish. At launch, a stale recording state is inspected and recovered if readable; unrecoverable files remain on disk with an explanation.

## Transcription lifecycle

The serial queue saves each transition. Apple asset availability is checked before inference; missing models require the download preference to be enabled. There is no automatic off-device fallback. Results are time-indexed and only replace the previous transcript on successful completion. Cancel or failure preserves the old transcript and the audio.

A finite UIKit background task allows short work to finish. Expiration cancels the running job and queued work, saves retryable state, and ends the task. Relaunch converts stale work states into retryable notes. Inference restarts from the beginning; there is no checkpoint-resume claim.

Transcription progress measures finalized timestamps, not an estimated percentage of model loading. Language choice is captured per queued job. Speaker identities are stable IDs. Display labels are projected onto every matching passage; embeddings live separately from note metadata.

## Playback and editing

`AVAudioPlayer` provides rate control and seeking. MediaPlayer supplies lock-screen transport and Now Playing metadata. A single player prevents overlapping audio. Starting capture stops playback. Pause, leaving the detail screen, and background transitions persist position.

Transcript edits preserve segment time ranges but remove word timing if the words changed. Word links always refer to original audio positions. Auto-follow stops when the user manually scrolls, and can be re-enabled. Subtitle exports use real stored time ranges.

## Release work still required

Validate on physical iPhones: microphone routes and phone interruptions; recording with screen locked; low-space and force-termination recovery; model installation and offline transcription in supported languages; long recordings, thermal load, and energy use. Test on minimum supported iOS 26 as well as the current SDK. Measure diarization error and saved-voice false-match rates on a representative physical-device corpus. Validate speaker processing and Opus playback on minimum-version devices. Confirm signing, accessibility, privacy declarations, and store metadata before distribution.

## Portable document import

Only a verified Cassini document supplies an imported transcript. Canonical word order, overlapping timestamps, and speaker labels are preserved. The source is copied unchanged, retaining all variants and extensions. If AVFoundation cannot decode its audio, the transcript remains accessible with a playback explanation. Imports retain all verified readable variants. Exports append local versions into a separate portable document and preserve original audio packets when the source is Opus. New AAC/PCM captures are converted incrementally to Opus. Source files are never overwritten. Multiword edited passages retain their passage timing for each exported word instead of fabricating fine-grained alignment.

## Speaker processing and saved voices

`CassiniInference` runs FluidAudio’s offline segmentation, embedding extraction, and VBx clustering on a disk-backed 16 kHz source with a small embedding batch. Models are released when the job finishes. A serial AppStore queue shares cancellation and finite background-task handling with transcription. Speech results are saved before speaker analysis, so a failed or cancelled speaker pass cannot discard the transcript.

Diarization turns are joined to words by maximum time overlap. Uncovered words remain unassigned. Each analysis creates a fresh speaker-ID namespace and retains the previous transcript. Speaker renames affect every passage carrying the ID; merges create a new version. Selecting a saved version preserves unsaved edits as another snapshot.

`PrivateVoices` stores note-specific embeddings and explicitly enrolled samples separately from `note.json`. It is excluded from system backup, and JSON exports strip voice links and suggestions from all versions. Model fingerprints prevent comparison across changed weights. Matching normalizes vectors, rejects invalid or short samples, uses one-to-one assignment, and checks competing matches before optional automatic naming. Trashed recordings do not supply matching evidence. Permanently deleting a recording removes its contributions; forgetting a saved voice removes its profile without erasing transcript labels. Automatic matches never enroll samples without explicit user action. Forget all clears both profiles and note-specific prints and advances an in-memory generation so an already-running job cannot restore forgotten evidence.

The model runner enables FluidAudio offline mode whenever downloads are not permitted, including its corruption-recovery path. Installed models continue to work after download permission is disabled. Local model weights, recordings, and generated Xcode projects are excluded from source control.
