import Foundation
import AppKit
import Combine

/// App-level orchestrator of the meeting notetaker (ADR 0027): owns the
/// detection engine, the dual-stream recorder, the live session, and notes
/// generation, and publishes the UI-facing state the pill, menu bar, and
/// Meetings page bind to. Deliberately NOT part of AppState.Phase — the
/// dictation phase machine assumes one short-lived session owns it, while a
/// meeting is a 45-minute ambient state that must coexist with dozens of
/// dictation sessions. Parallel state, rendered side by side.
@MainActor final class MeetingCenter: ObservableObject {
    static let shared = MeetingCenter()

    enum UIPhase: Equatable {
        case idle
        case starting
        case recording(started: Date, micHealthy: Bool)
        case processing(step: String)
    }

    enum Banner: Equatable {
        case started(app: String)       // consent visibility: "Recording this meeting"
        case finished(title: String)    // "Meeting saved" + Open/Discard window
        case micOnly                    // tap failed: "Recording your side only"
    }

    @Published private(set) var uiPhase: UIPhase = .idle
    @Published private(set) var banner: Banner?
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var liveSession: MeetingSession?

    let store = MeetingStore.shared
    let recorder = MeetingRecorder()
    private let engine = MeetingDetectionEngine()
    private let micMonitor = MicActivityMonitor()
    private let processMonitor = MeetingProcessMonitor()
    private let notesGenerator = MeetingNotesGenerator()

    private var whisper: WhisperEngine?
    private var cleanup: CleanupService?
    /// Read from the transcriber tick queue and the notes loop — never from
    /// the main actor directly (same mirror pattern as HotkeyMonitor's
    /// sessionIsLive).
    private let dictationBusy = LockedFlag()
    /// Bumped on start/stop/discard; async completions compare before
    /// publishing — a notes job finishing after Discard must not resurrect
    /// the meeting (the sessionGeneration pattern).
    private var meetingGeneration = 0
    private var bannerWork: DispatchWorkItem?
    private var pendingBanner: Banner?
    /// Notes runs still in flight — see generateNotes for why progress ticks
    /// must be dropped once the run's terminal state is written.
    private var activeNotesRuns: Set<UUID> = []
    private var cancellables: Set<AnyCancellable> = []
    private var bootstrapped = false

    var isCapturing: Bool { recorder.isCapturing }

    // MARK: - Bootstrap

    func bootstrap(whisper: WhisperEngine, cleanup: CleanupService) {
        guard !bootstrapped else { return }
        bootstrapped = true
        self.whisper = whisper
        self.cleanup = cleanup

        recorder.levelHandler = { [weak self] level in
            guard let self else { return }
            self.micLevel = level
            AppState.shared.meetingMicLevel(level)
        }
        recorder.onHealthChange = { [weak self] health in
            guard let self, case .recording(let started, let healthy) = self.uiPhase else { return }
            if case .micOnly = health {
                self.uiPhase = .recording(started: started, micHealthy: healthy)
                self.show(banner: .micOnly)
            }
        }
        recorder.onShouldStop = { [weak self] reason in
            self?.stopMeeting(reason: reason)
        }

        engine.onShouldStart = { [weak self] trigger in
            self?.startMeeting(trigger: trigger)
        }
        engine.onShouldStop = { [weak self] reason in
            self?.stopMeeting(reason: reason)
        }
        engine.browserProbe = { completion in
            BrowserMeetingProbe.meetingTabVisible(completion: completion)
        }
        engine.enabledPersonalCallApps = {
            var enabled: Set<String> = []
            if AppSettings.shared.meetingDetectFaceTime { enabled.insert(MeetingApps.facetime) }
            if AppSettings.shared.meetingDetectWhatsApp { enabled.insert(MeetingApps.whatsapp) }
            return enabled
        }
        engine.runningApps = { [weak self] in
            self?.processMonitor.runningMeetingApps ?? []
        }

        micMonitor.onChange = { [weak self] users in
            guard let self else { return }
            self.engine.handle(.micUsers(users, attributed: self.micMonitor.attributionAvailable))
        }
        processMonitor.onLaunch = { [weak self] bundleID in
            self?.engine.handle(.appLaunched(bundleID: bundleID))
        }
        processMonitor.onTerminate = { [weak self] bundleID in
            self?.engine.handle(.appTerminated(bundleID: bundleID))
        }

        // Menu toggle and Settings both write the same key; re-arm on change.
        AppSettings.shared.$meetingAutoRecord
            .removeDuplicates()
            .sink { [weak self] _ in Task { @MainActor in self?.rearm() } }
            .store(in: &cancellables)

        sweepOrphans()
        store.sweep(retentionDays: AppSettings.shared.meetingRetentionDays)
        rearm()
    }

    /// Detection runs only when the feature is on AND both permissions are
    /// granted. A user who denied system audio gets the Meetings-page CTA,
    /// never surprise half-recordings.
    func rearm() {
        let armed = AppSettings.shared.meetingAutoRecord
            && Permissions.micGranted
            && Permissions.systemAudio == .granted
        if armed {
            micMonitor.start()
            processMonitor.start()
            engine.arm()
            Log.info("MeetingCenter: armed (auto-record on, permissions granted)")
        } else {
            engine.disarm()
            micMonitor.stop()
            processMonitor.stop()
        }
    }

    /// UI entry point (Settings row, Meetings empty state): run the probe —
    /// the first-ever probe is what makes macOS show the consent dialog —
    /// then arm if it came back granted.
    func probeSystemAudioAndRearm(completion: ((Permissions.SystemAudioPermission) -> Void)? = nil) {
        SystemAudioTap.probePermission { [weak self] status in
            Task { @MainActor in
                self?.rearm()
                completion?(status)
            }
        }
    }

    // MARK: - Start

    func startManually() {
        startMeeting(trigger: .manual)
    }

    private func startMeeting(trigger: MeetingTrigger) {
        guard case .idle = uiPhase, liveSession == nil, let whisper else { return }
        meetingGeneration += 1
        let generation = meetingGeneration
        uiPhase = .starting

        let id = UUID()
        let record = MeetingRecord(id: id, date: Date(), title: "",
                                   durationSeconds: 0, appName: trigger.appName,
                                   noteState: .none, deleted: nil)
        let meta = MeetingMeta(startedAt: Date(),
                               trigger: trigger.bundleID ?? "manual",
                               appName: trigger.appName)
        store.create(record, meta: meta)
        let folder = store.folderURL(id)

        let session = MeetingSession(id: id, startedAt: Date(), engine: whisper,
                                     store: store,
                                     dictationActive: { [dictationBusy] in dictationBusy.value })
        recorder.consumer = session.consumer

        Task { [weak self] in
            let result: Result<MeetingRecorder.CaptureInfo, Error> = await Task.detached {
                do {
                    return .success(try self?.recorder.start(id: id, trigger: trigger, folder: folder)
                                    ?? { throw MeetingRecorder.RecorderError.alreadyCapturing }())
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self, self.meetingGeneration == generation else { return }
            switch result {
            case .success:
                session.begin()
                self.liveSession = session
                self.uiPhase = .recording(started: Date(), micHealthy: true)
                self.engine.meetingDidStart()
                self.show(banner: .started(app: trigger.appName))
                self.playSound("Pop")
                Log.info("MeetingCenter: recording started (\(trigger.appName.isEmpty ? "manual" : trigger.appName))")
            case .failure(let error):
                Log.error("MeetingCenter: meeting start failed: \(error)")
                self.store.delete(id)
                self.recorder.consumer = nil
                self.uiPhase = .idle
                self.engine.meetingWasStopped(manually: false)
            }
        }
    }

    // MARK: - Stop / discard

    func stopManually() { stopMeeting(reason: .manual) }

    func discardCurrent() { stopMeeting(reason: .discard) }

    private func stopMeeting(reason: MeetingStopReason) {
        guard let session = liveSession else { return }
        switch uiPhase {
        case .recording, .starting: break
        default: return
        }
        meetingGeneration += 1
        let generation = meetingGeneration
        let id = session.id
        liveSession = nil
        uiPhase = .processing(step: reason == .discard ? "Discarding…" : "Transcribing…")

        Task { [weak self] in
            guard let self else { return }
            let result = await Task.detached { self.recorder.stop(reason: reason) }.value
            self.recorder.consumer = nil
            self.micLevel = 0

            if reason == .discard {
                await session.abort()
                self.store.delete(id)
                self.finishStopUI(generation: generation, banner: nil)
                self.engine.meetingWasStopped(manually: true)
                Log.info("MeetingCenter: meeting discarded")
                return
            }

            let segments = await session.finish()
            self.engine.meetingWasStopped(manually: reason == .manual)

            // Sub-30 s captures are mic-test blips and misfires that slipped
            // through corroboration — a "meeting" nobody would keep.
            guard result.durationSeconds >= 30, !segments.isEmpty else {
                Log.info("MeetingCenter: auto-discarding \(Int(result.durationSeconds)) s " +
                         "capture (\(segments.count) segments)")
                self.store.delete(id)
                self.finishStopUI(generation: generation, banner: nil)
                return
            }

            guard var record = self.store.records.first(where: { $0.id == id }) else {
                self.finishStopUI(generation: generation, banner: nil)
                return
            }
            record.durationSeconds = result.durationSeconds
            self.store.update(record)
            self.store.updateMeta(id) { meta in
                meta.endedAt = Date()
                meta.stopReason = reason.rawValue
            }

            var noteSegments = segments

            // Diarize BEFORE the spools are deleted — it is the only pass
            // that needs system.wav. ANE-bound, so running it ahead of the
            // Gemma passes serializes ANE and GPU work instead of contending.
            // Fail-closed: nil (models missing, micOnly, timeout) changes
            // nothing, and the spools are cleaned up either way (ADR 31).
            if AppSettings.shared.meetingIdentifySpeakers {
                if self.meetingGeneration == generation {
                    self.uiPhase = .processing(step: "Identifying speakers…")
                }
                if let outcome = await SpeakerDiarizer.run(
                        folder: self.store.folderURL(id), segments: noteSegments) {
                    // A 1:1 call stays plain You/Them — no rewrite, no labels.
                    if outcome.speakerCount > 1 {
                        noteSegments = outcome.segments
                        self.store.rewriteTranscript(id, segments: outcome.segments)
                    }
                    self.store.updateMeta(id) { meta in
                        meta.speakerCount = outcome.speakerCount
                        meta.diarizedAt = Date()
                    }
                }
            }
            self.cleanupSpools(id)

            // Polish BEFORE notes, so the notes read the corrected words.
            // Fail-closed throughout: nil (server missing, nothing changed,
            // every batch unusable) keeps the raw transcript untouched.
            // Polishes the diarized segments so its rewrite carries the
            // speaker field through.
            if AppSettings.shared.meetingPolishTranscript, let cleanup = self.cleanup {
                if self.meetingGeneration == generation {
                    self.uiPhase = .processing(step: "Polishing transcript…")
                }
                if let polished = await TranscriptPolisher.polish(
                    segments: noteSegments, cleanup: cleanup,
                    dictationActive: { [dictationBusy] in dictationBusy.value }) {
                    noteSegments = polished
                    self.store.rewriteTranscript(id, segments: polished)
                }
            }

            if AppSettings.shared.meetingAutoNotes, let cleanup = self.cleanup {
                if self.meetingGeneration == generation {
                    self.uiPhase = .processing(step: "Writing notes…")
                }
                await self.generateNotes(id: id, segments: noteSegments, cleanup: cleanup)
            }
            let title = self.store.records.first(where: { $0.id == id })?.displayTitle
                ?? "Meeting saved"
            self.finishStopUI(generation: generation, banner: .finished(title: title))
        }
    }

    private func finishStopUI(generation: Int, banner: Banner?) {
        guard meetingGeneration == generation else { return }
        uiPhase = .idle
        if let banner { show(banner: banner) }
    }

    /// The WAVs are a spool, not an archive: once the transcript is finalized
    /// they hold nothing the transcript doesn't — except replayable audio of
    /// other people, which the all-local privacy story is better off without.
    private func cleanupSpools(_ id: UUID) {
        guard !AppSettings.shared.keepMeetingAudioForDebug else { return }
        let folder = store.folderURL(id)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("mic.wav"))
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("system.wav"))
    }

    // MARK: - Notes

    private func generateNotes(id: UUID, segments: [MeetingSegment],
                               cleanup: CleanupService) async {
        // The progress closure hops to the main actor through a Task, so its
        // final tick can land AFTER the terminal .done/.failed write below and
        // stomp the record back to .generating — which the UI renders as
        // "writing notes" forever (observed 2026-08-08: index held done then a
        // later generating line). The run leaves this set in the same
        // synchronous main-actor stretch as the terminal write, so a straggler
        // tick finds it gone and drops.
        activeNotesRuns.insert(id)
        defer { activeNotesRuns.remove(id) }
        setNoteState(id, .generating(completed: 0, total: max(segments.count / 8, 3)))
        let result = await notesGenerator.generate(
            segments: segments, cleanup: cleanup,
            dictationActive: { [dictationBusy] in dictationBusy.value },
            progress: { [weak self] completed, total in
                Task { @MainActor in
                    guard let self, self.activeNotesRuns.contains(id) else { return }
                    self.setNoteState(id, .generating(completed: completed, total: total))
                }
            })
        guard let result else {
            // Honest and generic: the run also fails with the engine up (a
            // model call failing both attempts) — the log has the specifics.
            setNoteState(id, .failed("Notes failed — transcript saved, tap Retry"))
            return
        }
        store.writeNotes(id, markdown: result.markdown)
        if var record = store.records.first(where: { $0.id == id }) {
            if record.title.isEmpty { record.title = result.title }
            record.noteState = .done
            store.update(record)
        }
        let hash = segments.transcriptHash()
        store.updateMeta(id) { meta in
            meta.notesHash = hash
            meta.notesGeneratedAt = Date()
            meta.notesModel = "gemma-4-E2B-it-Q4_0"
            meta.notesEditedAt = nil       // freshly generated = unedited
        }
        Log.info("MeetingCenter: notes ready for \(id) (\(result.markdown.count) chars)")
    }

    /// Manual regenerate (stale notes, failed runs, changed transcripts).
    func regenerateNotes(_ id: UUID) {
        guard let cleanup else { return }
        Task { [weak self] in
            guard let self else { return }
            let segments = await Task.detached { self.store.loadSegments(id) }.value
            guard !segments.isEmpty else { return }
            await self.generateNotes(id: id, segments: segments, cleanup: cleanup)
        }
    }

    private func setNoteState(_ id: UUID, _ state: NoteState) {
        guard var record = store.records.first(where: { $0.id == id }) else { return }
        record.noteState = state
        store.update(record)
    }

    // MARK: - Crash recovery

    /// A meeting whose meta has no endedAt died with the process. Finalize,
    /// never resume: capture died too, and a rejoined call minutes later is a
    /// new meeting. The spooled WAVs get their headers repaired so the audio
    /// is recoverable, but v1 finalizes from the incrementally-appended
    /// transcript (loss window ≤ ~11 s of audio — see MeetingStore).
    private func sweepOrphans() {
        for id in store.orphanedRecordingIDs() {
            let folder = store.folderURL(id)
            WavSpool.repairHeader(url: folder.appendingPathComponent("mic.wav"))
            WavSpool.repairHeader(url: folder.appendingPathComponent("system.wav"))
            let segments = store.loadSegments(id)
            guard !segments.isEmpty, let last = segments.last else {
                Log.info("MeetingCenter: discarding empty orphaned meeting \(id)")
                store.delete(id)
                continue
            }
            if var record = store.records.first(where: { $0.id == id }) {
                record.durationSeconds = last.end
                store.update(record)
            }
            store.updateMeta(id) { meta in
                meta.endedAt = meta.startedAt.addingTimeInterval(last.end)
                meta.stopReason = MeetingStopReason.crashRecovery.rawValue
            }
            cleanupSpools(id)
            Log.info("MeetingCenter: finalized orphaned meeting \(id) (\(Int(last.end)) s)")
            if AppSettings.shared.meetingAutoNotes, let cleanup {
                Task { [weak self] in
                    await self?.generateNotes(id: id, segments: segments, cleanup: cleanup)
                }
            }
        }
    }

    // MARK: - System hooks (called by AppState)

    func setUserDictating(_ active: Bool) {
        dictationBusy.value = active
        engine.setUserDictating(active)
        if case .recording(let started, _) = uiPhase {
            // The chip's bars go amber while dictation holds the mic stream.
            uiPhase = .recording(started: started, micHealthy: !active)
        }
        if !active, let queued = pendingBanner {
            pendingBanner = nil
            show(banner: queued)
        }
    }

    func systemWillSleep() {
        guard isCapturing else { return }
        stopMeeting(reason: .sleep)
    }

    func systemDidWake() {
        rearm()
    }

    func borrowMicForDictation() -> MicLoan? {
        recorder.borrowMicForDictation()
    }

    // MARK: - Banner

    private func show(banner newBanner: Banner) {
        // Never fight the dictation pill for the surface — hold the banner
        // until the session ends (the pendingAgentNotice pattern).
        if dictationBusy.value {
            pendingBanner = newBanner
            return
        }
        banner = newBanner
        bannerWork?.cancel()
        let generation = meetingGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.meetingGeneration == generation else { return }
            self.banner = nil
        }
        bannerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    func dismissBanner() {
        bannerWork?.cancel()
        banner = nil
    }

    private func playSound(_ name: String) {
        guard AppSettings.shared.soundFeedback else { return }
        if let sound = NSSound(named: name) {
            sound.volume = 0.18
            sound.play()
        }
    }
}

/// A bool readable from any thread — the main-actor mirror pattern used
/// wherever pipeline threads need a fact only the main actor owns.
final class LockedFlag {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return flag }
        set { lock.lock(); flag = newValue; lock.unlock() }
    }
}
