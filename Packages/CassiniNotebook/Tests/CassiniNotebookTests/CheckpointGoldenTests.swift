import Foundation
import Testing
import CassiniNotebook

/// A `checkpoint.json` as a stopped iOS job leaves it: a 60-second Italian recording stopped after its first 15 s of
/// final words. The words are those of Android's golden (a real 0.1.0 job on emulator-5554); the members are iOS's.
/// Equality is semantic: members are compared as parsed JSON, not as bytes.
@Suite struct CheckpointGoldenTests {
    private let golden = Data(Self.json.utf8)
    private var state: CheckpointState { get throws { try CheckpointState.decode(golden) } }

    private func object(_ data: Data) throws -> NSDictionary {
        try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    private func expected(source: String = "audio.m4a", signature: String = "247526:1791552443925",
                          language: String = "it-IT") -> CheckpointState.Expected {
        .init(source: source, signature: signature, language: language)
    }

    // ports: CheckpointGoldenTest#theGoldenHasExactlyTheVersionOneMembers
    @Test func theGoldenHasExactlyTheVersionOneMembers() throws {
        let json = try object(golden)
        #expect(Set(json.allKeys.compactMap { $0 as? String }) == CheckpointState.keys)
        #expect(json["version"] as? Int == 1)
        let segment = try #require((json["segments"] as? [NSDictionary])?.first)
        #expect(Set(segment.allKeys.compactMap { $0 as? String }) == ["id", "text", "start", "end", "words"])
        let word = try #require((segment["words"] as? [NSDictionary])?.first)
        #expect(Set(word.allKeys.compactMap { $0 as? String }) == ["id", "text", "start", "end"])
        let done = try #require(json["doneMs"] as? Int64), total = try #require(json["totalMs"] as? Int64)
        #expect(done > 0 && done < total, "Stopped before the end")
    }

    // ports: CheckpointGoldenTest#reEncodingTheDecodedStateKeepsEveryMemberAndValue
    @Test func reEncodingTheDecodedStateKeepsEveryMemberAndValue() throws {
        let encoded = try state.encoded()
        #expect(try object(encoded) == object(golden))
        #expect(try CheckpointState.decode(encoded) == state)
    }

    // ports: CheckpointGoldenTest#theGoldenValidatesAgainstItsOwnIdentity
    @Test func theGoldenValidatesAgainstItsOwnIdentity() throws {
        try state.validate(expected())
    }

    // ports: CheckpointGoldenTest#aChangedIdentityOrShorterFilesRejectTheGolden
    @Test func aChangedIdentityRejectsTheGolden() throws {
        let state = try state
        #expect(throws: CheckpointState.Mismatch.source) { try state.validate(expected(source: "audio.wav")) }
        #expect(throws: CheckpointState.Mismatch.signature) { try state.validate(expected(signature: "247526:0")) }
        #expect(throws: CheckpointState.Mismatch.language) { try state.validate(expected(language: "en-US")) }
    }

    // ports: CheckpointGoldenTest#recognitionRestoresWhereTheJobStopped
    @Test func theWordsRestoreWhereTheJobStopped() throws {
        let state = try state
        let words = state.draftWords
        #expect(!words.isEmpty)
        #expect(words.contains { $0.text.localizedCaseInsensitiveContains("settentrionale") })
        #expect(words.allSatisfy { $0.endMs <= state.doneMs && $0.speaker.isEmpty })
        #expect(words.first?.text == "La" && words[1].text == "parte")
        #expect(state.doneMs == words.last?.endMs)
        // A resumed run that hears the last second again adds none of it.
        #expect(state.segments.compactMap { $0.resumed(after: state.doneMs) }.isEmpty)
    }

    // ports: CheckpointGoldenTest#aWordBodyWithTheTagsLanguageMemberDecodesTheSameWords (adapted: unknown members)
    @Test func aCheckpointWithAnUnknownMemberDecodesTheSameWords() throws {
        let json = try #require(try JSONSerialization.jsonObject(with: golden) as? [String: Any])
        var tagged = json
        tagged["x-later"] = ["anything": 1]
        let decoded = try CheckpointState.decode(JSONSerialization.data(withJSONObject: tagged))
        #expect(try decoded == state)
    }

    private static let json = #"""
    {
      "doneMs": 14988,
      "elapsedMs": 18754,
      "inferenceMs": 4776,
      "language": "it-IT",
      "resumedFromMs": 0,
      "segments": [
        {
          "end": 8.478,
          "id": "00000000-0000-0000-0000-000000000001",
          "start": 1.308,
          "text": "La parte settentrionale, conosciuta come catena della sentinella, vanta le montagne più alte dell'Antartide,",
          "words": [
            {
              "end": 1.548,
              "id": "00000000-0000-0000-0000-000000000065",
              "start": 1.308,
              "text": "La"
            },
            {
              "end": 1.788,
              "id": "00000000-0000-0000-0000-000000000066",
              "start": 1.548,
              "text": " parte"
            },
            {
              "end": 2.898,
              "id": "00000000-0000-0000-0000-000000000067",
              "start": 1.788,
              "text": " settentrionale,"
            },
            {
              "end": 3.468,
              "id": "00000000-0000-0000-0000-000000000068",
              "start": 2.908,
              "text": " conosciuta"
            },
            {
              "end": 3.708,
              "id": "00000000-0000-0000-0000-000000000069",
              "start": 3.468,
              "text": " come"
            },
            {
              "end": 4.348,
              "id": "00000000-0000-0000-0000-00000000006A",
              "start": 3.708,
              "text": " catena"
            },
            {
              "end": 4.588,
              "id": "00000000-0000-0000-0000-00000000006B",
              "start": 4.348,
              "text": " della"
            },
            {
              "end": 5.598,
              "id": "00000000-0000-0000-0000-00000000006C",
              "start": 4.588,
              "text": " sentinella,"
            },
            {
              "end": 6.188,
              "id": "00000000-0000-0000-0000-00000000006D",
              "start": 5.628,
              "text": " vanta"
            },
            {
              "end": 6.268,
              "id": "00000000-0000-0000-0000-00000000006E",
              "start": 6.188,
              "text": " le"
            },
            {
              "end": 6.828,
              "id": "00000000-0000-0000-0000-00000000006F",
              "start": 6.268,
              "text": " montagne"
            },
            {
              "end": 6.988,
              "id": "00000000-0000-0000-0000-000000000070",
              "start": 6.828,
              "text": " più"
            },
            {
              "end": 7.308,
              "id": "00000000-0000-0000-0000-000000000071",
              "start": 6.988,
              "text": " alte"
            },
            {
              "end": 8.478,
              "id": "00000000-0000-0000-0000-000000000072",
              "start": 7.308,
              "text": " dell'Antartide,"
            }
          ]
        },
        {
          "end": 14.988,
          "id": "00000000-0000-0000-0000-000000000002",
          "start": 8.508,
          "text": "il massiccio del Vinson, che raggiunge i 4892 metri con il monte Vinson.",
          "words": [
            {
              "end": 8.668,
              "id": "00000000-0000-0000-0000-0000000000C9",
              "start": 8.508,
              "text": "il"
            },
            {
              "end": 9.388,
              "id": "00000000-0000-0000-0000-0000000000CA",
              "start": 8.668,
              "text": " massiccio"
            },
            {
              "end": 9.628,
              "id": "00000000-0000-0000-0000-0000000000CB",
              "start": 9.468,
              "text": " del"
            },
            {
              "end": 10.578,
              "id": "00000000-0000-0000-0000-0000000000CC",
              "start": 9.708,
              "text": " Vinson,"
            },
            {
              "end": 10.748,
              "id": "00000000-0000-0000-0000-0000000000CD",
              "start": 10.588,
              "text": " che"
            },
            {
              "end": 11.388,
              "id": "00000000-0000-0000-0000-0000000000CE",
              "start": 10.748,
              "text": " raggiunge"
            },
            {
              "end": 11.468,
              "id": "00000000-0000-0000-0000-0000000000CF",
              "start": 11.388,
              "text": " i"
            },
            {
              "end": 13.148,
              "id": "00000000-0000-0000-0000-0000000000D0",
              "start": 11.548,
              "text": " 4892"
            },
            {
              "end": 13.468,
              "id": "00000000-0000-0000-0000-0000000000D1",
              "start": 13.148,
              "text": " metri"
            },
            {
              "end": 13.628,
              "id": "00000000-0000-0000-0000-0000000000D2",
              "start": 13.468,
              "text": " con"
            },
            {
              "end": 13.868,
              "id": "00000000-0000-0000-0000-0000000000D3",
              "start": 13.628,
              "text": " il"
            },
            {
              "end": 14.268,
              "id": "00000000-0000-0000-0000-0000000000D4",
              "start": 13.868,
              "text": " monte"
            },
            {
              "end": 14.988,
              "id": "00000000-0000-0000-0000-0000000000D5",
              "start": 14.268,
              "text": " Vinson."
            }
          ]
        }
      ],
      "signature": "247526:1791552443925",
      "source": "audio.m4a",
      "totalMs": 59968,
      "version": 1,
      "wordsComplete": false
    }
    
    """#
}
