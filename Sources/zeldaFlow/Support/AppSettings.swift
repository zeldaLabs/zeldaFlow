import Foundation
import Combine

enum CleanupMode: String, CaseIterable, Identifiable {
    case off      // insert raw whisper output
    case light    // regex filler-strip only, no LLM
    case full     // Gemma cleanup via llama-server

    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off (raw transcript)"
        case .light: return "Light (filler removal)"
        case .full: return "Full (Gemma AI cleanup)"
        }
    }
}

/// UserDefaults-backed settings. All @Published so SwiftUI views update live.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    /// "en" for fixed English, "auto" for per-utterance language detection.
    @Published var language: String {
        didSet { d.set(language, forKey: "language") }
    }
    @Published var cleanupMode: CleanupMode {
        didSet { d.set(cleanupMode.rawValue, forKey: "cleanupMode") }
    }
    @Published var dictionaryWords: [String] {
        didSet { d.set(dictionaryWords, forKey: "dictionaryWords") }
    }
    /// Applied verbatim after transcription/cleanup, case-insensitive whole-word match.
    @Published var replacements: [String: String] {
        didSet { d.set(replacements, forKey: "replacements") }
    }
    @Published var appendTrailingSpace: Bool {
        didSet { d.set(appendTrailingSpace, forKey: "appendTrailingSpace") }
    }
    @Published var soundFeedback: Bool {
        didSet { d.set(soundFeedback, forKey: "soundFeedback") }
    }
    /// Wispr-style always-visible mini pill at the bottom of the screen.
    @Published var showIdlePill: Bool {
        didSet { d.set(showIdlePill, forKey: "showIdlePill") }
    }
    /// Local Deep Context: bias STT with terms visible on screen (local-only).
    @Published var screenContext: Bool {
        didSet { d.set(screenContext, forKey: "screenContext") }
    }
    /// Learn from corrections: after a paste, two bounded re-reads of the
    /// focused field notice a retyped word and offer to learn it (ADR 0037).
    @Published var learnFromCorrections: Bool {
        didSet { d.set(learnFromCorrections, forKey: "learnFromCorrections") }
    }
    /// What zeldaFlow calls the user — asked on first launch, per-person.
    @Published var userName: String {
        didSet { d.set(userName, forKey: "userName") }
    }
    @Published var maxRecordingSeconds: Int {
        didSet { d.set(maxRecordingSeconds, forKey: "maxRecordingSeconds") }
    }
    @Published var llamaPort: Int {
        didSet { d.set(llamaPort, forKey: "llamaPort") }
    }
    /// Skip the LLM for utterances shorter than this many words (raw whisper is already clean).
    @Published var cleanupMinWords: Int {
        didSet { d.set(cleanupMinWords, forKey: "cleanupMinWords") }
    }
    @Published var onboardingCompleted: Bool {
        didSet { d.set(onboardingCompleted, forKey: "onboardingCompleted") }
    }
    /// Require a spoken Fn-tap confirmation before sending emails/messages.
    @Published var confirmBeforeSending: Bool {
        didSet { d.set(confirmBeforeSending, forKey: "confirmBeforeSending") }
    }
    /// Capture from the Mac's built-in mic when the default input is a
    /// Bluetooth headset. Opening a Bluetooth mic flips the headset into the
    /// hands-free profile — music pauses, drops to mono, comes back after —
    /// on every single dictation. The built-in array avoids all of it and is
    /// the better microphone anyway.
    @Published var preferBuiltInMic: Bool {
        didSet { d.set(preferBuiltInMic, forKey: "preferBuiltInMic") }
    }
    /// Let a spoken task run as several steps ("download Slack from the App
    /// Store") instead of stopping after the first action. Still fully local,
    /// still gated: anything that spends money or destroys data asks first.
    @Published var multiStepTasks: Bool {
        didSet { d.set(multiStepTasks, forKey: "multiStepTasks") }
    }
    /// Agent mode: screen analysis and background tasks via the Claude Code
    /// CLI. The one non-local capability — off means fully local, always.
    @Published var agentEnabled: Bool {
        didSet { d.set(agentEnabled, forKey: "agentEnabled") }
    }
    /// Claude model for agent work ("sonnet" is fast; "opus" for harder tasks).
    @Published var agentModel: String {
        didSet { d.set(agentModel, forKey: "agentModel") }
    }
    /// Hard ceiling on a background agent task.
    @Published var agentMaxMinutes: Int {
        didSet { d.set(agentMaxMinutes, forKey: "agentMaxMinutes") }
    }
    /// Voice-processing echo cancellation: keeps music playing from the Mac's
    /// own speakers out of the dictation mic.
    /// The key that starts dictation. Stored as JSON so the shape can grow
    /// without another defaults key.
    @Published var hotkey: HotkeyBinding {
        didSet {
            guard let data = try? JSONEncoder().encode(hotkey) else { return }
            d.set(data, forKey: "hotkey")
        }
    }

    @Published var echoCancellation: Bool {
        didSet { d.set(echoCancellation, forKey: "echoCancellation") }
    }
    /// Which player answers "play some music": "auto" adapts to this machine
    /// (see MusicPlayer.resolve); "music" / "spotify" pin it.
    @Published var musicApp: String {
        didSet { d.set(musicApp, forKey: "musicApp") }
    }

    // MARK: Meeting notetaker

    /// Auto-record meetings: when a meeting app holds the microphone, zeldaFlow
    /// records both sides and writes notes when the call ends. Defaults on, but
    /// has no effect until the system-audio permission is granted — the
    /// Meetings page and Settings carry the enable flow (ADR 0027).
    @Published var meetingAutoRecord: Bool {
        didSet { d.set(meetingAutoRecord, forKey: "meetingAutoRecord") }
    }
    /// Write notes automatically when a meeting ends (manual Regenerate stays).
    @Published var meetingAutoNotes: Bool {
        didSet { d.set(meetingAutoNotes, forKey: "meetingAutoNotes") }
    }
    /// Post-meeting Gemma pass over the transcript itself — the same cleanup
    /// dictation gets, fail-closed per line (TranscriptPolisher).
    @Published var meetingPolishTranscript: Bool {
        didSet { d.set(meetingPolishTranscript, forKey: "meetingPolishTranscript") }
    }
    /// FaceTime calls are personal by default — recording them is opt-in.
    @Published var meetingDetectFaceTime: Bool {
        didSet { d.set(meetingDetectFaceTime, forKey: "meetingDetectFaceTime") }
    }
    /// WhatsApp calls, same opt-in posture as FaceTime (ADR 33). Only CALLS
    /// are detected (mic input + audio output concurrently, sustained) —
    /// voice notes never trigger.
    @Published var meetingDetectWhatsApp: Bool {
        didSet { d.set(meetingDetectWhatsApp, forKey: "meetingDetectWhatsApp") }
    }
    /// Post-meeting speaker diarization of the system channel (ADR 31).
    /// Harmless when the models aren't installed — the pass just skips.
    @Published var meetingIdentifySpeakers: Bool {
        didSet { d.set(meetingIdentifySpeakers, forKey: "meetingIdentifySpeakers") }
    }
    /// Days to keep meetings (transcript + notes). 0 = forever.
    @Published var meetingRetentionDays: Int {
        didSet { d.set(meetingRetentionDays, forKey: "meetingRetentionDays") }
    }
    /// Debug only, no UI: keep the spooled mic/system WAVs after a meeting is
    /// finalized instead of deleting them (eval fixtures, field debugging).
    @Published var keepMeetingAudioForDebug: Bool {
        didSet { d.set(keepMeetingAudioForDebug, forKey: "keepMeetingAudioForDebug") }
    }

    private init() {
        language = d.string(forKey: "language") ?? "auto"
        cleanupMode = CleanupMode(rawValue: d.string(forKey: "cleanupMode") ?? "") ?? .full
        // No personal seed data — each install starts clean and learns its
        // own user (their name is added when they enter it in onboarding).
        dictionaryWords = d.stringArray(forKey: "dictionaryWords") ?? ["zeldaFlow"]
        replacements = (d.dictionary(forKey: "replacements") as? [String: String]) ?? [:]
        appendTrailingSpace = d.object(forKey: "appendTrailingSpace") == nil
            ? true : d.bool(forKey: "appendTrailingSpace")
        soundFeedback = d.object(forKey: "soundFeedback") == nil
            ? true : d.bool(forKey: "soundFeedback")
        showIdlePill = d.object(forKey: "showIdlePill") == nil
            ? true : d.bool(forKey: "showIdlePill")
        screenContext = d.object(forKey: "screenContext") == nil
            ? true : d.bool(forKey: "screenContext")
        learnFromCorrections = d.object(forKey: "learnFromCorrections") == nil
            ? true : d.bool(forKey: "learnFromCorrections")
        userName = d.string(forKey: "userName") ?? ""
        maxRecordingSeconds = d.object(forKey: "maxRecordingSeconds") == nil
            ? 300 : d.integer(forKey: "maxRecordingSeconds")
        llamaPort = d.object(forKey: "llamaPort") == nil
            ? 8765 : d.integer(forKey: "llamaPort")
        cleanupMinWords = d.object(forKey: "cleanupMinWords") == nil
            ? 5 : d.integer(forKey: "cleanupMinWords")
        onboardingCompleted = d.bool(forKey: "onboardingCompleted")
        confirmBeforeSending = d.object(forKey: "confirmBeforeSending") == nil
            ? true : d.bool(forKey: "confirmBeforeSending")
        preferBuiltInMic = d.object(forKey: "preferBuiltInMic") == nil
            ? true : d.bool(forKey: "preferBuiltInMic")
        multiStepTasks = d.object(forKey: "multiStepTasks") == nil
            ? true : d.bool(forKey: "multiStepTasks")
        agentEnabled = d.object(forKey: "agentEnabled") == nil
            ? true : d.bool(forKey: "agentEnabled")
        agentModel = d.string(forKey: "agentModel") ?? "sonnet"
        agentMaxMinutes = d.object(forKey: "agentMaxMinutes") == nil
            ? 10 : d.integer(forKey: "agentMaxMinutes")
        // Off by default: the VPIO graph reshapes the input pipeline
        // (multichannel format, AGC) — opt-in for people who dictate over
        // speaker audio, not a default everyone silently inherits.
        hotkey = (d.data(forKey: "hotkey")
            .flatMap { try? JSONDecoder().decode(HotkeyBinding.self, from: $0) }) ?? .fn
        echoCancellation = d.bool(forKey: "echoCancellation")
        musicApp = d.string(forKey: "musicApp") ?? "auto"
        meetingAutoRecord = d.object(forKey: "meetingAutoRecord") == nil
            ? true : d.bool(forKey: "meetingAutoRecord")
        meetingAutoNotes = d.object(forKey: "meetingAutoNotes") == nil
            ? true : d.bool(forKey: "meetingAutoNotes")
        meetingPolishTranscript = d.object(forKey: "meetingPolishTranscript") == nil
            ? true : d.bool(forKey: "meetingPolishTranscript")
        meetingDetectFaceTime = d.bool(forKey: "meetingDetectFaceTime")
        meetingDetectWhatsApp = d.bool(forKey: "meetingDetectWhatsApp")
        meetingIdentifySpeakers = d.object(forKey: "meetingIdentifySpeakers") == nil
            ? true : d.bool(forKey: "meetingIdentifySpeakers")
        meetingRetentionDays = d.object(forKey: "meetingRetentionDays") == nil
            ? 0 : d.integer(forKey: "meetingRetentionDays")
        keepMeetingAudioForDebug = d.bool(forKey: "keepMeetingAudioForDebug")
    }

    /// Dictation languages offered in the UI (menu bar + Settings share this
    /// one list). Whisper accepts many more; these cover the common asks —
    /// "auto" transcribes each utterance in whatever language was spoken.
    static let languageChoices: [(code: String, label: String)] = [
        ("auto", "Auto-detect"),
        ("en", "English (faster)"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("pt", "Portuguese"),
        ("it", "Italian"),
        ("hi", "Hindi"),
        ("ta", "Tamil"),
        ("zh", "Chinese"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("ar", "Arabic"),
        ("ru", "Russian"),
    ]

    /// Whisper initial_prompt: steers punctuation style and biases the decoder
    /// toward dictionary words (carried into every decode window).
    var whisperPrompt: String {
        Self.sttPrompt(base: "This is a carefully punctuated dictated note.",
                       dictionary: dictionaryWords)
    }

    /// Same glossary bias for command mode — proper nouns (artist names,
    /// project jargon) transcribe far better when the decoder has seen them.
    var commandWhisperPrompt: String {
        Self.sttPrompt(base: "This is a spoken command to a computer assistant.",
                       dictionary: dictionaryWords)
    }

    /// Every glossary word in the prompt widens HallucinationFilter's
    /// prompt-echo kill radius (5-char-prefix matching), so a dictionary that
    /// now grows from corrections (ADR 0037) is capped here: the most recent
    /// 40 words ride the prompt. The FULL list still reaches the Gemma
    /// cleanup pass and the replacement rules, which scrub nothing.
    static let promptGlossaryCap = 40

    static func sttPrompt(base: String, dictionary: [String]) -> String {
        var p = base
        let glossary = dictionary.suffix(promptGlossaryCap)
        if !glossary.isEmpty {
            p += " Glossary: \(glossary.joined(separator: ", "))."
        }
        return p
    }

    // The meeting "Them" channel has no prompt at all — see
    // MeetingTranscriber.decodePrompt(for:). It briefly had a punctuation-
    // steering string ("This is a meeting conversation, carefully
    // punctuated."), which whisper carried into every window and recited as
    // speech on quiet ones: a real call came back with "there is a meeting
    // conversation" four times (ADR 34). Biasing other people's audio was
    // already banned for the glossary; it turned out to be unsafe for
    // punctuation steering too.
}
