# Cassini for iPhone and iPad

Early work on an iOS and iPadOS version of [Cassini for Android](https://github.com/codemyriad/cassini-android).

So far this is `CassiniCore`, a Swift package that reads and writes portable Cassini documents: an Ogg Opus recording with its timed words and manifest sealed into the comment header. It is a port of the Android format layer and passes the published [conformance vectors](https://github.com/codemyriad/cassini-format/tree/main/spec/conformance). There is no app, recording or transcription yet.

## Testing

Building needs a Mac with Xcode. From any machine with SSH access to one:

```sh
CASSINI_MAC=ghyston ./scripts/test-remote.sh
```

On the Mac itself, run `swift test` with [cassini-format](https://github.com/codemyriad/cassini-format) checked out beside this repository. Set `CASSINI_CONFORMANCE_REQUIRED=1` to fail instead of skipping when it is missing.

## Differences from Android

* The JSON layer keeps member order and number spelling. A lone UTF-16 surrogate in a payload string is rejected, because a Swift string cannot hold one; Android would accept it.
* Created files carry the vendor string `cassini-ios/0.1`. The gzip and JSON bytes inside the payload differ from Android's, so the payload digests differ too. Readers verify against the declared values, so both remain valid.

## License

GPL-3.0, as Cassini for Android.
