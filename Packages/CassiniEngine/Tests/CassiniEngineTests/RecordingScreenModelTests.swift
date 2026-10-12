import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// The Recording screen over the real controller with a scripted microphone (RecordingViewModelTest).
@MainActor @Suite(.serialized) struct RecordingScreenModelTests {
    final class Screen {
        let h: RecordingHarness
        let permission: FakeMicrophonePermission
        var missing = false
        /// While true the speech-model lookup waits.
        var lookupHeld = false
        var effects: [RecordingEffect] = []
        let model: RecordingScreenModel

        @MainActor init(consented: Bool = true, access: MicrophoneAccess = .granted, answer: Bool = true, notifier: Bool = true) throws {
            h = try RecordingHarness(consented: consented)
            permission = FakeMicrophonePermission(access: access, answer: answer)
            var screen: Screen?
            model = RecordingScreenModel(controller: h.controller, ports: .init(
                permission: permission, modelsMissing: {
                    while screen?.lookupHeld == true { try? await Task.sleep(for: .milliseconds(5)) }
                    return screen?.missing ?? false
                },
                notifier: notifier ? h.notifier : nil, settings: h.settings))
            screen = self
            model.onEffect = { [weak self] in self?.effects.append($0) }
        }
    }

    // ports: RecordingViewModelTest#startsOnEntryWithThePermissionAndShowsTheCapture
    @Test func startsOnEntryWithThePermissionAndShowsTheCapture() async throws {
        let s = try Screen(); defer { s.h.tearDown() }
        #expect(s.model.phase == .starting)
        await s.model.enter()
        try await s.h.waitFor("the capture") { s.model.phase == .recording }
        #expect(s.permission.requests == 0)
        #expect(s.model.format == .pcm48kMono)
        #expect(s.model.levels.count == 56)
        #expect(s.model.banner == nil)
        s.h.capture.elapsed = 1_447
        try await s.h.waitFor("the time") { s.model.elapsed == 1_447 }
        let space = try #require(s.model.space)
        #expect(space.spaceMs > 0)
    }

    // ports: RecordingViewModelTest#prefillsTheDefaultTitleOnce
    @Test func prefillsTheDefaultTitleOnce() async throws {
        let s = try Screen(); defer { s.h.tearDown() }
        await s.model.enter()
        try await s.h.waitFor("the capture") { s.model.phase == .recording }
        #expect(s.model.title == "Voice note 8 Oct, 09:41")
        s.model.setTitle("")
        #expect(s.model.title == "", "the user may clear the field")
        s.model.setTitle("Standup")
        #expect(s.model.title == "Standup")
    }

    // ports: RecordingViewModelTest#entryDuringARecordingReturnsToIt
    @Test func entryDuringARecordingReturnsToIt() async throws {
        let s = try Screen(); defer { s.h.tearDown() }
        await s.model.enter()
        try await s.h.waitFor("the capture") { s.model.phase == .recording }
        await s.model.enter()
        #expect(s.h.capture.starts == 1)
        #expect(s.model.phase == .recording)
    }

    // ports: RecordingViewModelTest#asksForThePermissionsAndStartsWhenGranted
    @Test func asksForThePermissionsAndStartsWhenGranted() async throws {
        let s = try Screen(access: .undetermined, answer: true); defer { s.h.tearDown() }
        await s.model.enter()
        #expect(s.permission.requests == 1)
        try await s.h.waitFor("the capture") { s.model.phase == .recording }
        #expect(s.h.notifier.requestCount == 1, "notifications are asked at the first recording")
        #expect(s.h.settings.notificationsAsked)
    }

    @Test func notificationsAreAskedOnlyOnce() async throws {
        let s = try Screen(); defer { s.h.tearDown() }
        s.h.settings.markNotificationsAsked()
        await s.model.enter()
        #expect(s.h.notifier.requestCount == 0)
    }

    // ports: RecordingViewModelTest#deniedShowsMicrophoneOffAndStartsOnResumeWithThePermission
    @Test func deniedShowsMicrophoneOffAndStartsOnResumeWithThePermission() async throws {
        let s = try Screen(access: .undetermined, answer: false); defer { s.h.tearDown() }
        await s.model.enter()
        #expect(s.model.phase == .needsPermission)
        #expect(s.model.banner == .microphoneOff)
        s.model.perform(.openSettings)
        #expect(s.effects == [.openSettings])

        s.model.appBecameActive()
        #expect(s.h.capture.starts == 0)
        s.permission.access = .granted
        s.model.appBecameActive()
        try await s.h.waitFor("the capture") { s.model.phase == .recording }
        #expect(s.model.banner == nil)
    }

    // The model outlives the screen: a start waiting for access must not begin once the user has left.
    @Test func leavingWhileAccessIsOffDropsTheWaitingStart() async throws {
        let s = try Screen(access: .undetermined, answer: false); defer { s.h.tearDown() }
        await s.model.enter()
        #expect(s.model.phase == .needsPermission)
        s.model.minimise()
        #expect(s.effects == [.close])
        s.permission.access = .granted
        s.model.appBecameActive()
        try await Task.sleep(for: .milliseconds(50))
        #expect(s.h.capture.starts == 0)
        #expect(s.h.controller.state == .idle)
        #expect(s.model.banner == nil)
    }

    // ports: RecordingViewModelTest#pauseResumeFinishAndMinimise
    @Test func pauseResumeFinishAndMinimise() async throws {
        let s = try Screen(); defer { s.h.tearDown() }
        await s.model.enter()
        try await s.h.waitFor("the capture") { s.model.phase == .recording }
        s.model.pauseOrResume()
        #expect(s.model.phase == .paused)
        s.model.pauseOrResume()
        #expect(s.model.phase == .recording)
        s.model.minimise()
        #expect(s.effects == [.close])
        #expect(s.h.controller.state.isActive, "the recording continues")
        await s.model.enter()
        s.model.setTitle("Weekly sync")
        s.model.finish()
        try await s.h.waitFor("the note") { s.effects.count == 2 }
        let id = try #require(await s.h.store.all().first?.id)
        #expect(s.effects.last == .openNote(id, modelDownload: false))
        #expect(await s.h.note(id)?.title == "Weekly sync")
    }

    // ports: RecordingViewModelTest#otherAppPauseAndWarningsShowTheirBanners
    @Test func otherAppPauseAndWarningsShowTheirBanners() async throws {
        let s = try Screen(); defer { s.h.tearDown() }
        await s.model.enter()
        try await s.h.waitFor("the capture") { s.model.phase == .recording }
        s.h.capture.send(.interrupted)
        try await s.h.waitFor("the banner") { s.model.banner == .pausedByOtherApp }
        s.model.perform(.resume)
        #expect(s.model.phase == .recording)
        let perSecond = RecordingPolicy.pcmBytesPerSecond + RecordingPolicy.finishBytesPerSecond
        s.h.storage.set(availableBytes: Limits.minRecordingFreeBytes + 10 * 60 * perSecond)
        try await s.h.waitFor("the warning") { s.model.banner == .storageLow(minutes: 10) }
    }

    private func finish(_ s: Screen) async throws -> RecordingEffect? {
        await s.model.enter()
        try await s.h.waitFor("the capture") { s.model.phase == .recording }
        s.model.finish()
        try await s.h.waitFor("the effect") { !s.effects.isEmpty }
        return s.effects.last
    }

    // ports: RecordingViewModelTest#finishWithConsentOpensTheNote
    @Test func finishWithConsentOpensTheNote() async throws {
        let s = try Screen(); defer { s.h.tearDown() }
        let effect = try await finish(s)
        let id = try #require(await s.h.store.all().first?.id)
        #expect(effect == .openNote(id, modelDownload: false))
        #expect(s.h.controller.state == .idle)
    }

    // ports: RecordingViewModelTest#finishWithoutConsentOpensModelDownloadOnlyWhenPartsAreMissing
    @Test func finishWithoutConsentOpensModelDownloadOnlyWhenPartsAreMissing() async throws {
        let s = try Screen(consented: false); defer { s.h.tearDown() }
        s.missing = true
        let effect = try await finish(s)
        let id = try #require(await s.h.store.all().first?.id)
        #expect(effect == .openNote(id, modelDownload: true))
    }

    // ports: RecordingViewModelTest#finishWithoutConsentAndNothingMissingOpensTheNote
    @Test func finishWithoutConsentAndNothingMissingOpensTheNote() async throws {
        let s = try Screen(consented: false); defer { s.h.tearDown() }
        let effect = try await finish(s)
        let id = try #require(await s.h.store.all().first?.id)
        #expect(effect == .openNote(id, modelDownload: false))
    }

    // ports: RecordingViewModelTest#finishAfterADeclineOpensTheNoteAudioOnly
    @Test func finishAfterADeclineOpensTheNoteAudioOnly() async throws {
        let s = try Screen(consented: false); defer { s.h.tearDown() }
        s.h.settings.recordDeclined()
        s.missing = true
        let effect = try await finish(s)
        let id = try #require(await s.h.store.all().first?.id)
        #expect(effect == .openNote(id, modelDownload: false))
    }

    @Test func aSlowModelLookupDoesNotLeadAwayFromANewerRecording() async throws {
        let s = try Screen(consented: false); defer { s.h.tearDown() }
        s.missing = true
        s.lookupHeld = true
        await s.model.enter()
        try await s.h.waitFor("the capture") { s.model.phase == .recording }
        s.model.finish()
        try await s.h.waitFor("the end") { s.h.controller.state == .idle }
        await s.model.enter()
        try await s.h.waitFor("the second capture") { s.model.phase == .recording }
        s.lookupHeld = false
        try await Task.sleep(for: .milliseconds(50))
        #expect(s.effects.isEmpty, "the new recording keeps the screen")
        #expect(s.h.controller.state.isActive)
    }

    // ports: RecordingViewModelTest#aStorageStopStaysWithItsBannerAndOpensTheNote
    @Test func aStorageStopStaysWithItsBannerAndOpensTheNote() async throws {
        let s = try Screen(); defer { s.h.tearDown() }
        await s.model.enter()
        try await s.h.waitFor("the capture") { s.model.phase == .recording }
        let id = try #require(s.h.controller.state.noteID)
        s.h.storage.set(availableBytes: Limits.minRecordingFreeBytes - 1)
        try await s.h.waitFor("the banner") { s.model.banner == .stoppedForSpace }
        #expect(s.model.phase == .stopping)
        #expect(s.effects == [.show], "the screen shows why the recording stopped")
        s.model.perform(.openNote)
        #expect(s.effects.last == .openNote(id, modelDownload: false))
    }

    // ports: RecordingViewModelTest#aFailedStartOffersTryAgain
    @Test func aFailedStartOffersTryAgain() async throws {
        let s = try Screen(); defer { s.h.tearDown() }
        s.h.capture.startError = CocoaError(.featureUnsupported)
        await s.model.enter()
        try await s.h.waitFor("the banner") { s.model.banner == .couldNotStart }
        #expect(s.model.phase == .starting)
        #expect(s.effects.isEmpty)
        s.h.capture.startError = nil
        s.model.perform(.tryAgain)
        try await s.h.waitFor("the capture") { s.model.phase == .recording }
        #expect(s.model.banner == nil)
    }

    // ports: RecordingViewModelTest#aStaleEndedStateDoesNotLeadAway
    @Test func aStaleEndedStateDoesNotLeadAway() async throws {
        let h = try RecordingHarness(); defer { h.tearDown() }
        try await h.startRecording()
        h.controller.finish()
        guard case .ended(_, .saved) = try await h.awaitEnded() else { Issue.record("not saved"); return }
        let model = RecordingScreenModel(controller: h.controller, ports: .init(
            permission: FakeMicrophonePermission(), modelsMissing: { false }, notifier: nil, settings: h.settings))
        var effects: [RecordingEffect] = []
        model.onEffect = { effects.append($0) }
        await model.enter()
        try await h.waitFor("the capture") { model.phase == .recording }
        #expect(effects.isEmpty)
        #expect(h.capture.starts == 2)
    }

    // The model outlives each showing of the screen: shown again without `enter()` (the Library's card, the Live
    // Activity), it leads away again.
    @Test func aMinimisedRecordingShownAgainLeadsAwayAgain() async throws {
        let s = try Screen(); defer { s.h.tearDown() }
        await s.model.enter()
        try await s.h.waitFor("the capture") { s.model.phase == .recording }
        s.model.minimise()
        s.model.minimise()
        #expect(s.effects == [.close], "one showing leads away once")
        s.model.appeared()
        s.model.minimise()
        #expect(s.effects == [.close, .close])
        s.model.appeared()
        s.model.finish()
        try await s.h.waitFor("the note") { s.effects.count == 3 }
        let id = try #require(await s.h.store.all().first?.id)
        #expect(s.effects.last == .openNote(id, modelDownload: false))
        #expect(s.model.phase == .starting && !s.h.controller.state.inProgress)
    }

    @Test func anAutomaticStopWhileMinimisedShowsTheScreenAndOpensTheNote() async throws {
        let s = try Screen(); defer { s.h.tearDown() }
        await s.model.enter()
        try await s.h.waitFor("the capture") { s.model.phase == .recording }
        let id = try #require(s.h.controller.state.noteID)
        s.model.minimise()
        s.h.storage.set(availableBytes: Limits.minRecordingFreeBytes - 1)
        try await s.h.waitFor("the banner") { s.model.banner == .stoppedForSpace }
        #expect(s.effects == [.close, .show])
        s.model.perform(.openNote)
        #expect(s.effects.last == .openNote(id, modelDownload: false))
    }

    @Test func anAutomaticStopWhileMinimisedCanBeMinimisedAgain() async throws {
        let s = try Screen(); defer { s.h.tearDown() }
        await s.model.enter()
        try await s.h.waitFor("the capture") { s.model.phase == .recording }
        s.model.minimise()
        s.h.capture.send(.failed)
        try await s.h.waitFor("the banner") { s.model.banner == .microphoneFailed }
        s.model.minimise()
        #expect(s.effects == [.close, .show, .close])
    }

    @Test func aTitleTypedWhileStartingIsKept() async throws {
        let s = try Screen(); defer { s.h.tearDown() }
        s.h.isReady = false
        await s.model.enter()
        #expect(s.model.phase == .starting)
        s.model.setTitle("Standup")
        #expect(s.model.title == "Standup")
        s.h.isReady = true
        try await s.h.waitFor("the capture") { s.model.phase == .recording }
        #expect(s.model.title == "Standup", "not replaced by the default")
        s.model.setTitle("")
        #expect(s.model.title == "", "the user may still clear the field")
        s.model.setTitle("Standup")
        let id = try #require(s.h.controller.state.noteID)
        try await s.h.waitFor("the title write") { await s.h.note(id)?.title == "Standup" }
    }

    @Test func laterObserversSeeTheStateAnEarlierOneMade() async throws {
        let s = try Screen(); defer { s.h.tearDown() }
        var seen: [RecordingState] = []
        s.h.controller.observe { seen.append($0) }
        await s.model.enter()
        try await s.h.waitFor("the prefill") { s.model.title == "Voice note 8 Oct, 09:41" }
        #expect(seen.last == s.h.controller.state)
        let titles = seen.compactMap { $0.activeRecording?.title }
        #expect(titles.prefix(2) == ["", "Voice note 8 Oct, 09:41"], "in the order they were set")
    }
}
