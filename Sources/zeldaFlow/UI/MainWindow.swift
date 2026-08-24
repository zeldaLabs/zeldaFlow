import AppKit
import SwiftUI

/// The Hub window: a Flow-style dashboard — sidebar navigation with a Home
/// page of usage stats, plus History, Dictionary and Settings pages.
@MainActor
final class MainWindowController {
    static let shared = MainWindowController()
    private var window: NSWindow?

    private init() {}

    func show() {
        if window == nil {
            let view = MainView()
                .environmentObject(AppState.shared)
                .environmentObject(AppSettings.shared)
                .environmentObject(HistoryStore.shared)
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            w.title = "zeldaFlow"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.center()
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: view)
            window = w
        }
        // A window last shown on a since-disconnected display keeps that
        // stale frame (macOS only migrates windows that are on screen at
        // disconnect time) — ordering it in there looks like the menu click
        // did nothing. Re-center whenever the frame is off every live screen.
        if let w = window,
           !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(w.frame) }) {
            w.center()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Deep link from the pill chip, banner, and menu bar: open the Hub on
    /// the Meetings page (and a specific meeting when given).
    func showMeetings(meeting: UUID?) {
        show()
        HubNav.shared.page = .meetings
        MeetingNav.shared.openMeetingID = meeting
    }
}

// MARK: - Navigation

enum HubPage: String, CaseIterable, Identifiable {
    case home, history, meetings, dictionary, settings
    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return "Home"
        case .history: return "History"
        case .meetings: return "Meetings"
        case .dictionary: return "Dictionary"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .history: return "clock"
        case .meetings: return "person.2.wave.2"
        case .dictionary: return "character.book.closed"
        case .settings: return "gearshape"
        }
    }
}

// @State is unavailable on this beta CLT (missing SwiftUIMacros plugin);
// small @StateObject models replace it throughout this file.
// A singleton, because deep-link sources (pill chip, menu bar, banner) live
// outside the Hub window's view tree.
final class HubNav: ObservableObject {
    static let shared = HubNav()
    @Published var page: HubPage = .home
}

struct MainView: View {
    @ObservedObject private var nav = HubNav.shared

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(nav: nav)
            Divider()
            Group {
                switch nav.page {
                case .home: HomePage()
                case .history: HistoryPage()
                case .meetings: MeetingsPage()
                case .dictionary: DictionaryPage()
                case .settings: SettingsPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Zelda.background)
        }
        .frame(minWidth: 860, minHeight: 560)
        .tint(Zelda.primary)
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @ObservedObject var nav: HubNav

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 10) {
                // The mark itself, drawn rather than a rasterized icon, so it
                // stays sharp and picks up the window's light/dark ink.
                WaveMark(size: 46, ink: Zelda.foreground, animated: false)
                VStack(alignment: .leading, spacing: 1) {
                    Text("zeldaFlow")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Zelda.foreground)
                        .kerning(0.3)
                    (Text("by ").foregroundColor(Zelda.mutedFg)
                        + Text("zeldaLabs").foregroundColor(Zelda.primary))
                        .font(.system(size: 10, weight: .medium, design: .serif))
                        .kerning(0.4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 42)
            .padding(.bottom, 20)

            ForEach(HubPage.allCases) { page in
                SidebarItem(page: page, selected: nav.page == page) {
                    nav.page = page
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 3) {
                Label("local-first · private", systemImage: "lock.shield")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Zelda.mutedFg)
                Text("Version \(appVersion)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Zelda.mutedFg.opacity(0.7))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(width: 200)
        .background(Zelda.surface1)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

private struct SidebarItem: View {
    let page: HubPage
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? page.icon + ".fill" : page.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(page.label)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(selected ? Zelda.onPrimaryContainer : Zelda.foreground)
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .background(
                Capsule(style: .continuous)
                    .fill(selected ? Zelda.primaryContainer : Color.clear)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
    }
}

// MARK: - Home

private struct HomePage: View {
    @EnvironmentObject var history: HistoryStore
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(greeting), \(firstName)")
                        .font(.system(size: 28, weight: .medium))
                        .kerning(-0.3)
                        .foregroundStyle(Zelda.foreground)
                    HStack(spacing: 5) {
                        Text("Hold down")
                        KeyCap("fn")
                        Text("and speak into any textbox")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Zelda.mutedFg)
                }
                .padding(.top, 36)

                // Monochrome by intent: the three metrics are unrelated, so a
                // colour per card would encode nothing and only add noise
                // against an ink-and-paper identity. The numbers carry the
                // emphasis; violet stays reserved for interactive state.
                HStack(spacing: 14) {
                    StatCard(icon: "flame.fill", tint: Zelda.foreground, chip: Zelda.surface2,
                             title: "Day streak",
                             value: history.dayStreak > 0 ? "\(history.dayStreak) \(history.dayStreak == 1 ? "day" : "days")" : "—",
                             caption: history.dayStreak > 0 ? "Keep it going" : "Dictate today to start one")
                    StatCard(icon: "gauge.with.needle.fill", tint: Zelda.foreground, chip: Zelda.surface2,
                             title: "Average speed",
                             value: history.averageWPM > 0 ? "\(history.averageWPM) WPM" : "—",
                             caption: history.averageWPM > 40 ? "That's faster than typing" : "Speak naturally — it keeps up")
                    StatCard(icon: "text.word.spacing", tint: Zelda.foreground, chip: Zelda.surface2,
                             title: "Words dictated",
                             value: history.dictatedWords > 0 ? "\(history.dictatedWords)" : "—",
                             caption: history.dictatedWords > 45 ? "That's about \(max(1, history.dictatedWords / 45)) tweets!" : "Your words will add up here")
                }

                HStack(alignment: .top, spacing: 14) {
                    ChecklistCard()
                    CommandsCard()
                }

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Up late"
        }
    }

    private var firstName: String {
        // The name the user gave zeldaFlow in onboarding; fall back to the
        // macOS account name for installs that predate the name step.
        let source = settings.userName.isEmpty ? NSFullUserName() : settings.userName
        let first = source.split(separator: " ").first.map(String.init) ?? source
        return first.isEmpty ? "there" : first
    }
}

private struct KeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(Zelda.foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Zelda.surface2)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(Zelda.border, lineWidth: 1))
            )
    }
}

private struct StatCard: View {
    let icon: String
    let tint: Color
    let chip: Color
    let title: String
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: Zelda.radiusSm).fill(chip))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Zelda.mutedFg)
            }
            Text(value)
                .font(.system(size: 22, weight: .semibold))
                .kerning(-0.2)
                .foregroundStyle(Zelda.foreground)
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(Zelda.mutedFg.opacity(0.8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(CardBackground())
    }
}

private struct CardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Zelda.radiusLg, style: .continuous)
            .fill(Zelda.card)
            .overlay(RoundedRectangle(cornerRadius: Zelda.radiusLg, style: .continuous)
                .stroke(Zelda.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
    }
}

private struct ChecklistCard: View {
    @EnvironmentObject var history: HistoryStore
    @EnvironmentObject var settings: AppSettings

    private struct Step: Identifiable {
        let id: String
        let title: String
        let done: Bool
    }

    private var steps: [Step] {
        // Words zeldaFlow added by itself (the product name, the user's own name
        // from onboarding) don't count as "taught it a word".
        var defaults: Set<String> = ["zeldaFlow"]
        defaults.insert(settings.userName)
        defaults.formUnion(settings.userName.split(separator: " ").map(String.init))
        let customWords = !Set(settings.dictionaryWords).isSubset(of: defaults)
        return [
            Step(id: "dictate", title: "Dictate your first note — hold fn and talk",
                 done: history.hasDictated),
            Step(id: "command", title: "Try command mode — triple-tap fn",
                 done: history.hasUsedCommands),
            Step(id: "music", title: "Ask for a song — “play some jazz”",
                 done: history.hasPlayedMusic),
            Step(id: "dictionary", title: "Teach it a word in Dictionary",
                 done: customWords),
            Step(id: "cleanup", title: "Turn on AI cleanup in Settings",
                 done: settings.cleanupMode == .full),
        ]
    }

    var body: some View {
        let done = steps.filter(\.done).count
        VStack(alignment: .leading, spacing: 12) {
            Text("Get the most out of zeldaFlow")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Zelda.foreground)
            ProgressView(value: Double(done), total: Double(steps.count))
                .tint(Zelda.primary)
            Text("\(done)/\(steps.count) steps completed")
                .font(.system(size: 11))
                .foregroundStyle(Zelda.mutedFg)
            VStack(alignment: .leading, spacing: 9) {
                ForEach(steps) { step in
                    HStack(spacing: 8) {
                        Image(systemName: step.done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(step.done ? Zelda.primary : Zelda.mutedFg.opacity(0.5))
                        Text(step.title)
                            .font(.system(size: 12))
                            .foregroundStyle(step.done ? Zelda.mutedFg : Zelda.foreground)
                            .strikethrough(step.done, color: Zelda.mutedFg)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(CardBackground())
    }
}

private struct CommandsCard: View {
    // Every example works on a stock install — nothing here depends on the
    // optional Claude CLI.
    private let examples = [
        "“Open Safari”",
        "“Play some jazz”",
        "“Navigate to the airport”",
        "“Email Sam that the demo moved to 3pm”",
        "“Remind me to call mom at 7”",
        "“Write a PRD for the new onboarding flow”",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Zelda.primary)
                Text("Voice commands")
                    .font(.system(size: 14, weight: .semibold))
            }
            Text("Triple-tap fn and just say it:")
                .font(.system(size: 11))
                .opacity(0.85)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(examples, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Zelda.primary)
                }
            }
            Spacer(minLength: 0)
        }
        // Deliberately the same card as its neighbour rather than a violet
        // slab: it was the loudest thing on the page while saying the least.
        // The example commands carry the accent instead.
        .foregroundStyle(Zelda.foreground)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(CardBackground())
    }
}

// MARK: - Page chrome shared by History / Dictionary / Settings

struct PageHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 24, weight: .medium))
            .kerning(-0.3)
            .foregroundStyle(Zelda.foreground)
            .padding(.top, 36)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
    }
}

// MARK: - History

private struct HistoryPage: View {
    @EnvironmentObject var history: HistoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "History")
            HStack {
                Text("\(history.entries.count) dictations · \(history.totalWords) words")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear All") { history.clearAll() }
                    .disabled(history.entries.isEmpty)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 12)

            if history.entries.isEmpty {
                Spacer()
                VStack(spacing: 14) {
                    WaveMark(size: 72, ink: Zelda.mutedFg.opacity(0.45), animated: false)
                    Text("Hold fn and speak — your dictations appear here.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(history.entries) { entry in
                    HistoryRow(entry: entry)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 16)
            }
        }
    }
}

private final class CopyFlag: ObservableObject {
    @Published var copied = false
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    @StateObject private var flag = CopyFlag()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.date, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !entry.appName.isEmpty {
                    Text("→ \(entry.appName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(String(format: "%.1f", entry.audioSeconds))s · stt \(entry.transcribeMs)ms" +
                     (entry.cleanupMs > 0 ? " · ai \(entry.cleanupMs)ms" : ""))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.finalText, forType: .string)
                    flag.copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { flag.copied = false }
                } label: {
                    Image(systemName: flag.copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }
            Text(entry.finalText)
                .font(.body)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Dictionary

private final class DictionaryFields: ObservableObject {
    @Published var newWord = ""
    @Published var newFrom = ""
    @Published var newTo = ""
}

private struct DictionaryPage: View {
    @EnvironmentObject var settings: AppSettings
    @StateObject private var fields = DictionaryFields()
    @ObservedObject private var learned = LearnedWords.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Dictionary")
            Form {
                if !learned.suggestions.isEmpty {
                    Section("Suggested by zeldaFlow — words you keep using") {
                        ForEach(learned.suggestions, id: \.self) { word in
                            HStack {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(Zelda.primary)
                                Text(word)
                                Spacer()
                                Button("Add") { learned.approve(word) }
                                    .buttonStyle(.bordered)
                                Button {
                                    learned.dismiss(word)
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .buttonStyle(.borderless)
                                .help("Don't suggest this word again")
                            }
                        }
                    }
                }

                Section("Words Whisper should spell correctly — names, artists, jargon") {
                    HStack {
                        AppKitTextField(placeholder: "Add word (e.g. Kubernetes)",
                                        text: fields.newWord,
                                        onChange: { fields.newWord = $0 },
                                        onSubmit: addWord)
                        Button("Add", action: addWord)
                            .disabled(fields.newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    ForEach(settings.dictionaryWords, id: \.self) { word in
                        HStack {
                            Text(word)
                            Spacer()
                            Button {
                                settings.dictionaryWords.removeAll { $0 == word }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                Section("Replacements — applied after transcription (e.g. \"btw\" → \"by the way\")") {
                    HStack {
                        AppKitTextField(placeholder: "Say…", text: fields.newFrom,
                                        onChange: { fields.newFrom = $0 })
                        Image(systemName: "arrow.right")
                        AppKitTextField(placeholder: "Type…", text: fields.newTo,
                                        onChange: { fields.newTo = $0 })
                        Button("Add") {
                            let from = fields.newFrom.trimmingCharacters(in: .whitespaces)
                            guard !from.isEmpty else { return }
                            settings.replacements[from] = fields.newTo
                            fields.newFrom = ""; fields.newTo = ""
                        }
                    }
                    ForEach(settings.replacements.sorted(by: { $0.key < $1.key }), id: \.key) { from, to in
                        HStack {
                            Text("\(from) → \(to)")
                            Spacer()
                            Button {
                                settings.replacements.removeValue(forKey: from)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    private func addWord() {
        let word = fields.newWord.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty, !settings.dictionaryWords.contains(word) else { return }
        settings.dictionaryWords.append(word)
        fields.newWord = ""
    }
}

// MARK: - Settings

private final class LoginFlag: ObservableObject {
    @Published var enabled = LoginItem.isEnabled
}

/// Captures the next keypress so the user can pick their own dictation key.
/// Runs a local NSEvent monitor (the Hub window is key while Settings is
/// open) and suspends the global tap for the duration — otherwise the tap
/// would swallow the very press we're waiting for.
@MainActor
private final class HotkeyRecorder: ObservableObject {
    @Published var recording = false
    @Published var rejected: String?
    private var monitor: Any?

    func start() {
        guard !recording else { return }
        recording = true
        rejected = nil
        AppState.shared.hotkeyMonitor.isSuspended = true
        // Local monitors are delivered on the main thread.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return event }
                let code = Int64(event.keyCode)

                if event.type == .flagsChanged {
                    guard let mod = HotkeyBinding.modifierFlags[code] else { return nil }
                    // Only the press edge — the matching release would
                    // otherwise immediately re-trigger this handler.
                    guard UInt64(event.modifierFlags.rawValue) & mod.mask.rawValue != 0 else { return nil }
                    self.commit(HotkeyBinding(keyCode: code, flagMask: mod.mask.rawValue, label: mod.label))
                    return nil
                }

                if code == 53 { self.stop(); return nil }      // Esc cancels
                if let binding = HotkeyBinding.from(keyCode: code,
                                                    characters: event.charactersIgnoringModifiers) {
                    self.commit(binding)
                } else {
                    // Binding a text key would make that character untypable.
                    self.rejected = "That key types text. Try \(HotkeyBinding.suggestions)."
                    self.stop()
                }
                return nil
            }
        }
    }

    private func commit(_ binding: HotkeyBinding) {
        AppSettings.shared.hotkey = binding
        Log.info("hotkey rebound to \(binding.label) (keyCode \(binding.keyCode))")
        stop()
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        AppState.shared.hotkeyMonitor.isSuspended = false
    }
}

private struct HotkeyRow: View {
    @EnvironmentObject var settings: AppSettings
    @StateObject private var recorder = HotkeyRecorder()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Dictation key")
                Spacer()
                Text(recorder.recording ? "press a key…" : settings.hotkey.label)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(recorder.recording ? Zelda.primary : Zelda.foreground)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Zelda.surface2))
                Button(recorder.recording ? "Cancel" : "Change…") {
                    recorder.recording ? recorder.stop() : recorder.start()
                }
                if settings.hotkey != .fn {
                    Button("Reset") { settings.hotkey = .fn }
                }
            }
            Text(recorder.rejected
                 ?? "Hold it to dictate, double-tap for hands-free, triple-tap for commands. "
                    + "Pick a key you don't type with: \(HotkeyBinding.suggestions).")
                .font(.caption)
                .foregroundStyle(recorder.rejected == nil ? .secondary : Color.orange)
        }
    }
}

private struct SettingsPage: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var state: AppState
    @StateObject private var login = LoginFlag()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Settings")
            Form {
                Section("Hotkey") {
                    HotkeyRow()
                }

                Section("Dictation") {
                    Picker("Language", selection: $settings.language) {
                        ForEach(AppSettings.languageChoices, id: \.code) { choice in
                            Text(choice.label).tag(choice.code)
                        }
                    }
                    Text("Auto-detect transcribes each dictation in the language you spoke, in its own script — never translated.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("AI cleanup", selection: Binding(
                        get: { settings.cleanupMode },
                        set: { state.setCleanupMode($0) }
                    )) {
                        ForEach(CleanupMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    cleanupStatusRow
                    Stepper("Skip AI cleanup under \(settings.cleanupMinWords) words",
                            value: $settings.cleanupMinWords, in: 0...20)
                    Toggle("Append a space after inserted text", isOn: $settings.appendTrailingSpace)
                    Toggle("Sound when recording starts", isOn: $settings.soundFeedback)
                    Toggle("Always show mini pill at screen bottom", isOn: $settings.showIdlePill)
                    Toggle("Screen-aware accuracy (reads on-screen names locally)", isOn: $settings.screenContext)
                    Stepper("Max recording: \(settings.maxRecordingSeconds / 60) min",
                            value: $settings.maxRecordingSeconds, in: 60...1200, step: 60)
                }

                Section("Voice commands (triple-tap Fn)") {
                    Toggle("Confirm before sending emails & messages", isOn: $settings.confirmBeforeSending)
                    Text("When on, zeldaFlow shows the recipient and waits for you to tap Fn again before anything is sent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Music app", selection: $settings.musicApp) {
                        Text("Automatic").tag("auto")
                        Text("Apple Music").tag("music")
                        Text("Spotify").tag("spotify")
                    }
                    Text("Automatic follows whatever this Mac is playing — Spotify when it's installed and active, Apple Music otherwise. Naming an app in the command always wins.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Meetings") {
                    Toggle("Automatically record meetings", isOn: $settings.meetingAutoRecord)
                    Text("When a call starts in Zoom, Teams, Meet or Webex, zeldaFlow records both sides and writes notes when it ends. Everything stays on this Mac. A violet pill is always visible while recording — stop or discard any meeting with one click.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Write notes when a meeting ends", isOn: $settings.meetingAutoNotes)
                    Toggle("Identify separate speakers", isOn: $settings.meetingIdentifySpeakers)
                    if Paths.diarizerModelsExist {
                        Text("After a meeting ends, the far side of the call is split into Speaker 1, 2, 3… — right-click a name in the transcript to rename it. Runs on the Neural Engine, fully on this Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Speaker models aren't installed — run scripts/setup.sh to download them (~100 MB). Until then transcripts stay You/Them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Also record FaceTime calls", isOn: $settings.meetingDetectFaceTime)
                    Toggle("Also record WhatsApp calls", isOn: $settings.meetingDetectWhatsApp)
                    Text("Personal calls are off by default. Recording laws vary by region — make sure everyone on the call is okay with it; the violet pill is always visible while recording. Voice notes are never recorded, only calls.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Keep meetings", selection: $settings.meetingRetentionDays) {
                        Text("Forever").tag(0)
                        Text("90 days").tag(90)
                        Text("30 days").tag(30)
                        Text("7 days").tag(7)
                    }
                    meetingAudioStatusRow
                    LabeledContent("Meeting models", value: "same local Whisper + Gemma — nothing leaves this Mac")
                }

                Section("System") {
                    if LoginItem.isAvailable {
                        Toggle("Launch at login", isOn: Binding(
                            get: { login.enabled },
                            set: { on in
                                LoginItem.setEnabled(on)
                                login.enabled = LoginItem.isEnabled
                            }
                        ))
                    } else {
                        Text("Launch at login available when running from zeldaFlow.app")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Whisper model", value: "large-v3-turbo (q8_0, local)")
                    LabeledContent("Cleanup model", value: "Gemma 4 E2B (Q4_0, local)")
                    LabeledContent("Data folder", value: Paths.appSupport.path)
                    LabeledContent("Made by", value: "zeldaLabs")
                }

                Section {
                    Text("Hold **Fn** to talk · release to insert · double-tap **Fn** for hands-free · triple-tap **Fn** for voice commands · **Esc** cancels")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder
    private var meetingAudioStatusRow: some View {
        switch Permissions.systemAudio {
        case .granted:
            Label("System audio access granted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .denied:
            HStack {
                Label("System audio access denied — the other side of calls can't be heard",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Spacer()
                Button("Open Settings…") { Permissions.openSystemAudioPane() }
            }
        case .unknown:
            HStack {
                Label("System audio not yet requested", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Enable…") {
                    MeetingCenter.shared.probeSystemAudioAndRearm { status in
                        if status == .denied { Permissions.openSystemAudioPane() }
                        // Re-render the row with the fresh cached status.
                        settings.objectWillChange.send()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var cleanupStatusRow: some View {
        if settings.cleanupMode == .full {
            switch state.cleanup.status {
            case .ready:
                Label("Gemma is ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .starting:
                Label("Gemma is warming up…", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            case .failed(let why):
                Label(why, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .disabled:
                EmptyView()
            }
        }
    }
}
