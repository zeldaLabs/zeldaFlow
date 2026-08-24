import AppKit
import SwiftUI
import Combine

/// Menu bar presence: icon reflects state, menu offers the daily-driver
/// actions (hands-free toggle, paste last, cleanup mode, windows, quit).
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    static let shared = StatusBarController()

    private var item: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()
    private var state: AppState { AppState.shared }

    private override init() { super.init() }

    func setUp() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon(for: state.phase)
        let menu = NSMenu()
        // Manual enabling: AppKit's auto-validation would force-enable any
        // item whose target responds, overriding the isEnabled we set.
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu

        state.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in self?.updateIcon(for: phase) }
            .store(in: &cancellables)

        // A meeting recording changes the at-rest icon (consent visibility in
        // one more place); dictation-phase symbols still win.
        MeetingCenter.shared.$uiPhase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateIcon(for: self.state.phase)
            }
            .store(in: &cancellables)
    }

    /// The zeldaFlow wave mark, as a menu-bar template so macOS tints it for
    /// light/dark and for the highlighted (menu-open) state. Loaded once.
    /// Logical height of the menu-bar mark, in points. The wave mark is three
    /// stacked strokes, so it reads as heavy at the ~16 pt a single-stroke
    /// glyph would take — keep it well under the menu bar's cap height.
    private static let markHeight: CGFloat = 11

    private static let brandMark: NSImage? = {
        guard let img = NSImage(named: "MenuBarWave"), img.size.height > 0 else { return nil }
        let aspect = img.size.width / img.size.height
        img.size = NSSize(width: (markHeight * aspect).rounded(), height: markHeight)
        img.isTemplate = true
        return img
    }()

    private func updateIcon(for phase: AppState.Phase) {
        guard let button = item?.button else { return }
        // At rest the menu bar carries the brand mark; while recording or
        // processing it switches to symbols that read as *state*, which is
        // what the user needs to see mid-dictation.
        switch phase {
        case .recording, .processing:
            let name = phase == .processing ? "ellipsis.circle" : "waveform.circle.fill"
            let image = NSImage(systemSymbolName: name, accessibilityDescription: "zeldaFlow")
            image?.isTemplate = true
            button.image = image
        default:
            if case .recording = MeetingCenter.shared.uiPhase {
                let image = NSImage(systemSymbolName: "record.circle",
                                    accessibilityDescription: "zeldaFlow — meeting recording")
                image?.isTemplate = true
                button.image = image
            } else if let mark = Self.brandMark {
                button.image = mark
            } else {
                let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "zeldaFlow")
                image?.isTemplate = true
                button.image = image
            }
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = statusLine()
        let statusItem = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        menu.addItem(.separator())

        let handsFreeTitle: String
        if case .recording(.handsFree) = state.phase {
            handsFreeTitle = "Stop Hands-Free Dictation"
        } else {
            handsFreeTitle = "Start Hands-Free Dictation"
        }
        menu.addItem(makeItem(handsFreeTitle, #selector(toggleHandsFree), key: ""))
        menu.addItem(makeItem("Voice Command (tap Fn ×3)", #selector(startCommand), key: ""))

        let pasteItem = makeItem("Paste Last Transcript", #selector(pasteLast), key: "")
        pasteItem.isEnabled = state.lastInsertedText != nil
        menu.addItem(pasteItem)
        if AgentService.shared.isRunning {
            menu.addItem(makeItem("Cancel Agent Task", #selector(cancelAgent), key: ""))
        }
        menu.addItem(.separator())

        // Meetings: live controls only while one is active; the section rows
        // (open + auto-record toggle) always. The menu rebuilds on every
        // open, so these can't drift from Settings.
        switch MeetingCenter.shared.uiPhase {
        case .recording, .starting:
            menu.addItem(makeItem("Stop Meeting & Write Notes", #selector(stopMeeting), key: ""))
            menu.addItem(makeItem("Discard Meeting…", #selector(discardMeeting), key: ""))
            menu.addItem(makeItem("Open Current Meeting", #selector(openCurrentMeeting), key: ""))
        case .processing:
            menu.addItem(makeItem("Open Current Meeting", #selector(openCurrentMeeting), key: ""))
        case .idle:
            let manual = makeItem("Start Meeting Note", #selector(startMeetingNote), key: "")
            manual.isEnabled = Permissions.systemAudio == .granted || Permissions.micGranted
            menu.addItem(manual)
        }
        menu.addItem(makeItem("Open Meetings", #selector(openMeetings), key: ""))
        let autoRecord = makeItem("Auto-record Meetings", #selector(toggleMeetingAutoRecord), key: "")
        autoRecord.state = state.settings.meetingAutoRecord ? .on : .off
        menu.addItem(autoRecord)
        menu.addItem(.separator())

        // Cleanup mode
        let cleanupMenu = NSMenu()
        for mode in CleanupMode.allCases {
            let mi = NSMenuItem(title: mode.label, action: #selector(setCleanupMode(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = mode.rawValue
            mi.state = state.settings.cleanupMode == mode ? .on : .off
            cleanupMenu.addItem(mi)
        }
        let cleanupRoot = NSMenuItem(title: "AI Cleanup", action: nil, keyEquivalent: "")
        menu.addItem(cleanupRoot)
        menu.setSubmenu(cleanupMenu, for: cleanupRoot)

        // Language
        let langMenu = NSMenu()
        for (code, label) in AppSettings.languageChoices {
            let mi = NSMenuItem(title: label, action: #selector(setLanguage(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = code
            mi.state = state.settings.language == code ? .on : .off
            langMenu.addItem(mi)
        }
        let langRoot = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        menu.addItem(langRoot)
        menu.setSubmenu(langMenu, for: langRoot)

        // Agent (Claude-powered screen analysis & background tasks)
        let agentMenu = NSMenu()
        agentMenu.autoenablesItems = false
        let agentToggle = NSMenuItem(title: "Enable Agent (Claude)",
                                     action: #selector(toggleAgent), keyEquivalent: "")
        agentToggle.target = self
        agentToggle.state = state.settings.agentEnabled ? .on : .off
        agentToggle.isEnabled = AgentService.isAvailable
        agentMenu.addItem(agentToggle)
        for (id, label) in [("sonnet", "Model: Sonnet (fast)"), ("opus", "Model: Opus (deep)")] {
            let mi = NSMenuItem(title: label, action: #selector(setAgentModel(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = id
            mi.state = state.settings.agentModel == id ? .on : .off
            agentMenu.addItem(mi)
        }
        let echo = NSMenuItem(title: "Filter Background Music (experimental)",
                              action: #selector(toggleEchoCancel), keyEquivalent: "")
        echo.target = self
        echo.state = state.settings.echoCancellation ? .on : .off
        agentMenu.addItem(echo)
        let builtInMic = NSMenuItem(title: "Use Mac Microphone with Headphones",
                                    action: #selector(toggleBuiltInMic), keyEquivalent: "")
        builtInMic.target = self
        builtInMic.state = state.settings.preferBuiltInMic ? .on : .off
        agentMenu.addItem(builtInMic)
        let agentRoot = NSMenuItem(
            title: AgentService.isAvailable ? "Agent" : "Agent (Claude CLI not installed)",
            action: nil, keyEquivalent: "")
        menu.addItem(agentRoot)
        menu.setSubmenu(agentMenu, for: agentRoot)
        menu.addItem(.separator())

        menu.addItem(makeItem("History & Settings…", #selector(openMain), key: ""))
        menu.addItem(makeItem("Setup & Permissions…", #selector(openOnboarding), key: ""))
        menu.addItem(makeItem("About zeldaFlow — zeldaLabs", #selector(showAbout), key: ""))

        if LoginItem.isAvailable {
            let login = makeItem("Launch at Login", #selector(toggleLogin), key: "")
            login.state = LoginItem.isEnabled ? .on : .off
            menu.addItem(login)
        }
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit zeldaFlow", #selector(quit), key: "q"))
    }

    private func statusLine() -> String {
        if let problem = state.setupProblem { return "⚠️ \(problem)" }
        if !Permissions.accessibilityTrusted { return "⚠️ Accessibility permission needed" }
        if !Permissions.micGranted { return "⚠️ Microphone permission needed" }
        // Computed at menu open; fine that it doesn't tick while open.
        if case .recording(let started, _) = MeetingCenter.shared.uiPhase {
            let s = Int(Date().timeIntervalSince(started))
            return String(format: "● Meeting recording — %d:%02d", s / 60, s % 60)
        }
        if case .processing(let step) = MeetingCenter.shared.uiPhase {
            return "Meeting: \(step)"
        }
        if let task = AgentService.shared.runningTaskLabel { return "🤖 Agent: \(task)…" }
        if !state.whisperReady { return "Loading speech model…" }
        if state.settings.cleanupMode == .full {
            switch state.cleanup.status {
            case .ready: return "Ready — hold Fn to dictate"
            case .starting: return "Ready (AI cleanup warming up…)"
            case .failed: return "Ready (AI cleanup unavailable)"
            case .disabled: return "Ready — hold Fn to dictate"
            }
        }
        return "Ready — hold Fn to dictate"
    }

    private func makeItem(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        return mi
    }

    // MARK: - Actions

    @objc private func toggleHandsFree() { state.toggleHandsFree() }
    @objc private func startCommand() { state.startCommandMode() }
    @objc private func pasteLast() { state.pasteLastTranscript() }
    @objc private func openMain() { MainWindowController.shared.show() }
    @objc private func openOnboarding() { OnboardingWindowController.shared.show() }
    @objc private func showAbout() {
        // Accessory apps must activate first or the panel opens behind
        // everything. Shows name, version, and the zeldaLabs copyright line.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func setCleanupMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = CleanupMode(rawValue: raw) else { return }
        state.setCleanupMode(mode)
    }

    @objc private func setLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        state.settings.language = code
    }

    @objc private func toggleLogin() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
    }

    @objc private func cancelAgent() {
        AgentService.shared.cancel()
    }

    @objc private func toggleAgent() {
        state.settings.agentEnabled.toggle()
    }

    @objc private func setAgentModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        state.settings.agentModel = id
    }

    @objc private func toggleEchoCancel() {
        state.settings.echoCancellation.toggle()
    }

    @objc private func toggleBuiltInMic() {
        state.settings.preferBuiltInMic.toggle()
    }

    // MARK: - Meetings

    @objc private func stopMeeting() { MeetingCenter.shared.stopManually() }

    @objc private func discardMeeting() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Discard this meeting?"
        alert.informativeText = "The recording, transcript and notes are deleted. This can't be undone."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Keep Recording")
        if alert.runModal() == .alertFirstButtonReturn {
            MeetingCenter.shared.discardCurrent()
        }
    }

    @objc private func openCurrentMeeting() {
        MainWindowController.shared.showMeetings(
            meeting: MeetingCenter.shared.liveSession?.id)
    }

    @objc private func openMeetings() {
        MainWindowController.shared.showMeetings(meeting: nil)
    }

    @objc private func startMeetingNote() { MeetingCenter.shared.startManually() }

    @objc private func toggleMeetingAutoRecord() {
        state.settings.meetingAutoRecord.toggle()
    }
}
