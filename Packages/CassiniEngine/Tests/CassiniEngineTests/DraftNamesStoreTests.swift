import Foundation
import Testing
import CassiniEngine
import CassiniNotebook

/// Android's NamesStoreTest: the one owner of a note's draft names, reducers only, the latest value on disk.
@Suite struct DraftNamesStoreTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    private let id = UUID()
    private let anna = UUID(), luca = UUID(), marta = UUID()

    private func work(_ note: UUID) -> URL { root.appendingPathComponent(note.uuidString).appendingPathComponent("work") }
    private func file(_ note: UUID) -> URL { work(note).appendingPathComponent(DraftNamesStore.filename) }

    /// A store over the notes' folders, with the note's folder made.
    private func store() throws -> DraftNamesStore {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(id.uuidString), withIntermediateDirectories: true)
        return restarted()
    }

    /// A new store over the same files: the names in memory of the earlier process are gone.
    private func restarted() -> DraftNamesStore {
        DraftNamesStore(root: root) { [root] in root.appendingPathComponent($0.uuidString).appendingPathComponent("work") }
    }

    private func onDisk(_ note: UUID) throws -> DraftNames { try JSONDecoder().decode(DraftNames.self, from: Data(contentsOf: file(note))) }

    private func write(_ text: String, for note: UUID) throws {
        try FileManager.default.createDirectory(at: work(note), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file(note))
    }

    // ports: NamesStoreTest#namesWithoutTheNewMembersLoadAsEmpty
    @Test func namesWithoutTheNewMembersLoadAsEmpty() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let drafts = try store()
        // names.json as Android's 0.1.0 wrote it: no live, no rejected.
        try write(#"{"labels":{"S1":"Anna"},"merges":{"S3":"S2"},"remembered":{"S1":""},"automatic":{},"generation":4}"#, for: id)

        let names = drafts.current(id)
        #expect(names.labels == ["S1": "Anna"])
        #expect(names.merges == ["S3": "S2"])
        #expect(names.remembered == ["S1": .new])
        #expect(names.generation == 4)
        #expect(names.live.isEmpty && names.rejected.isEmpty)

        // A change that leaves them empty does not write them.
        drafts.mutate(id) { $0.rename("S2", "Bruno") }
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file(id))) as? [String: Any])
        #expect(json["live"] == nil && json["rejected"] == nil)
        #expect((json["labels"] as? [String: String])?["S2"] == "Bruno")
    }

    // ports: NamesStoreTest#namesWithTheNewMembersRoundTrip
    @Test func namesWithTheNewMembersRoundTrip() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try store().mutate(id) { names in
            names.confirm("S1", voice: anna, name: "Anna", generation: 2, score: 0.81)
                .applyLive(["S2": LiveMatch(luca, 0.62, .suggested)], names: [:])
                .reject("S3", voice: marta)
        }
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file(id))) as? [String: Any])
        #expect(json["live"] != nil && json["rejected"] != nil)

        let reloaded = restarted().current(id)
        #expect(reloaded.live["S1"] == LiveMatch(anna, 0.81, .confirmed))
        #expect(reloaded.live["S2"] == LiveMatch(luca, 0.62, .suggested))
        #expect(reloaded.rejected["S3"] == [marta])
        #expect(reloaded.remembered == ["S1": .saved(anna)])
    }

    // ports: NamesStoreTest#namesAreLoadedOncePerProcess
    @Test func namesAreLoadedOncePerProcess() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let drafts = try store()
        drafts.mutate(id) { $0.rename("S1", "Anna") }
        // Someone else writes the file: the owner keeps its value and the next write restores it.
        try write(#"{"labels":{"S1":"Other"},"merges":{}}"#, for: id)
        #expect(drafts.current(id).labels["S1"] == "Anna")

        drafts.release(id)
        #expect(drafts.current(id).labels["S1"] == "Other")
    }

    // ports: NamesStoreTest#aChangeAfterAdoptDoesNotCreateWork (adapted: iOS has no adopt; the job closes naming before
    // it saves the note and removes work/, so a late change from the screen is refused and makes no work/)
    @Test func aChangeAfterTheJobIsDoneDoesNotCreateWork() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let drafts = try store()
        drafts.mutate(id) { $0.rename("S1", "Anna") }
        _ = drafts.close(id)
        drafts.release(id)
        try FileManager.default.removeItem(at: work(id))

        #expect(!drafts.mutateIfOpen(id) { $0.rename("S2", "Bruno") })
        #expect(!FileManager.default.fileExists(atPath: work(id).path))
    }

    // ports: NamesStoreTest#observersSeeEveryWrite
    @Test func observersSeeEveryWrite() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let drafts = try store()
        var changes = drafts.changes(id).makeAsyncIterator()
        #expect(await changes.next() == .empty)
        drafts.mutate(id) { $0.rename("S1", "Anna") }
        #expect(await changes.next()?.labels["S1"] == "Anna")
    }

    // ports: NamesStoreTest#anObserverKeepsGettingValuesAfterRelease
    @Test func anObserverKeepsGettingValuesAfterRelease() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let drafts = try store()
        drafts.mutate(id) { $0.rename("S1", "Anna") }
        var changes = drafts.changes(id).makeAsyncIterator()
        #expect(await changes.next()?.labels["S1"] == "Anna")

        // "Start over": the old draft is gone, the job stays.
        try await NoteWorkFolders(notes: NoteStore(root: root), drafts: drafts).discard(id)
        #expect(await changes.next() == .empty)
        drafts.mutate(id) { $0.rename("S1", "Bruno") }

        #expect(await changes.next()?.labels == ["S1": "Bruno"])
    }

    // ports: CheckpointRepositoryTest#discardDeletesTheWorkDirectoryAndTheNamesInMemory
    @Test func discardDeletesTheWorkDirectoryAndTheNamesInMemory() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let drafts = try store()
        drafts.mutate(id) { $0.rename("S1", "Anna") }
        #expect(FileManager.default.fileExists(atPath: file(id).path))

        try await NoteWorkFolders(notes: NoteStore(root: root), drafts: drafts).discard(id)

        #expect(!FileManager.default.fileExists(atPath: work(id).path))
        #expect(drafts.current(id) == .empty)
    }

    // ports: NamesStoreTest#mutateAllReachesOpenAndSavedDrafts
    @Test func mutateAllReachesOpenAndSavedDrafts() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let drafts = try store()
        let other = UUID()
        try write(#"{"labels":{},"merges":{},"remembered":{"S1":"\#(anna.uuidString)"},"automatic":{},"generation":1}"#,
                  for: other)
        drafts.mutate(id) { $0.remember("S1", .saved(anna), generation: 1) }

        let changed = drafts.mutateAll { $0.forgetting(anna) }

        #expect(changed == [id, other].sorted { $0.uuidString < $1.uuidString })
        #expect(drafts.current(id).remembered.isEmpty)
        #expect(try onDisk(other).remembered.isEmpty)
    }

    // ports: NamesStoreTest#concurrentChangesLoseNothing (100 changes a thread, not 1000: every change is a durable
    // write, about 12 ms on a Mac)
    @Test func concurrentChangesLoseNothing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let iterations = 100
        let drafts = try store()
        let voices = (0..<iterations).map { _ in UUID() }, automatic = (0..<iterations).map { _ in UUID() }
        // The screen confirms speakers while the job applies live rounds, on two threads.
        async let ui: Void = Task.detached {
            for i in 0..<iterations {
                drafts.mutate(id) { $0.confirm("ui\(i)", voice: voices[i], name: "Name \(i)", generation: 0, score: 0.9) }
            }
        }.value
        async let job: Void = Task.detached {
            for i in 0..<iterations {
                drafts.mutate(id) {
                    $0.applyLive(["job\(i)": LiveMatch(automatic[i], 0.8, .auto)], names: [automatic[i]: "Auto \(i)"])
                }
            }
        }.value
        _ = await (ui, job)

        let final = drafts.current(id)
        for i in 0..<iterations {
            #expect(final.labels["ui\(i)"] == "Name \(i)")
            #expect(final.live["ui\(i)"] == LiveMatch(voices[i], 0.9, .confirmed))
            #expect(final.remembered["ui\(i)"] == .saved(voices[i]))
        }
        // Each live round replaces the open speakers' matches: only the last one is left.
        let last = iterations - 1
        #expect(final.live.filter { $0.value.state == .auto } == ["job\(last)": LiveMatch(automatic[last], 0.8, .auto)])
        #expect(try onDisk(id) == final)
        #expect(restarted().current(id) == final)
    }

    // ports: ProcessingCoordinatorTest#aDraftConfirmRacingTheJobsLiveUpdatesLosesNeither (the Note screen changes
    // the names through the store, `mutateIfOpen`, with no coordinator between)
    @Test func aDraftConfirmRacingTheJobsLiveUpdatesLosesNeither() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let drafts = try store()
        let v1 = UUID(), v2 = UUID(), v3 = UUID()
        let live = ["S2": LiveMatch(v2, 0.6, .suggested), "S3": LiveMatch(v3, 0.9, .auto)]
        async let updates: Void = Task.detached {
            for _ in 0..<50 { drafts.mutate(id) { $0.applyLive(live, names: [v3: "Marta"]) } }
        }.value
        async let confirm = Task.detached {
            drafts.mutateIfOpen(id) { $0.confirm("S1", voice: v1, name: "Luca", generation: 0, score: 0.8) }
        }.value
        _ = await updates
        #expect(await confirm)

        let names = drafts.current(id)
        #expect(names.labels["S1"] == "Luca")
        #expect(names.live["S1"]?.state == .confirmed)
        #expect(names.live["S2"]?.state == .suggested)
        #expect(names.automatic["S3"] == "Marta")
        #expect(names.remembered["S1"] == .saved(v1))
        #expect(try onDisk(id).labels["S1"] == "Luca", "names.json holds the confirmed label")

        // From the speaker step naming is closed: the screen's change is refused.
        _ = drafts.close(id)
        #expect(!drafts.mutateIfOpen(id) { $0.rename("S2", "Paolo") })
        #expect(drafts.current(id).labels["S2"] == nil)
    }

    @Test func theScreenNamesOnlyWhileTheGateIsOpen() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let drafts = try store()
        // The gate: the screen's changes apply only while naming is open; the job's always.
        #expect(drafts.isOpen(id))
        #expect(drafts.mutateIfOpen(id) { $0.rename("S1", "Anna") })
        #expect(drafts.close(id).labels == ["S1": "Anna"])
        #expect(!drafts.mutateIfOpen(id) { $0.rename("S1", "Bruno") })
        drafts.mutate(id) { $0.rename("S2", "Carla") }
        #expect(drafts.current(id).labels == ["S1": "Anna", "S2": "Carla"])
        drafts.open(id)
        #expect(drafts.mutateIfOpen(id) { $0.rename("S1", "Bruno") })
    }
}
