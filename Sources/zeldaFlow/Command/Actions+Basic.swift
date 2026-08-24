import Foundation
import AppKit

/// Local, non-communication actions: launch apps, open URLs, type generated
/// text, control Music playback and system volume. Nothing here contacts
/// another person.
enum BasicActions {
    static func openApp(_ a: ZeldaFlowAction) async -> ActionOutcome {
        guard let requested = a.app?.trimmingCharacters(in: .whitespacesAndNewlines),
              !requested.isEmpty else {
            return ActionOutcome(ok: false, summary: "[open: no app]", pillMessage: "No app name")
        }
        // Resolve against installed apps ("safari" → "Safari", "chrome" →
        // "Google Chrome") instead of trusting the LLM's spelling verbatim.
        let app = AppResolver.resolve(requested) ?? requested
        let ok = await Task.detached { () -> Bool in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", app]
            guard (try? p.run()) != nil else { return false }
            p.waitUntilExit()
            return p.terminationStatus == 0
        }.value
        if ok {
            return ActionOutcome(ok: true, summary: "[opened \(app)]", pillMessage: "Opening \(app)")
        }
        // Not installed on this Mac. For services people know by their app
        // name, the web app is what they mean — say so instead of a dead end.
        if let web = AppResolver.webFallback(for: requested) {
            await MainActor.run { NSWorkspace.shared.open(web) }
            return ActionOutcome(ok: true, summary: "[opened \(web.absoluteString)]",
                                 pillMessage: "\(app) isn't installed — opening \(web.host ?? "the web app")")
        }
        return ActionOutcome(ok: false, summary: "[app not found: \(app)]",
                             pillMessage: "No app called “\(app)”")
    }

    static func closeApp(_ a: ZeldaFlowAction) async -> ActionOutcome {
        guard let requested = a.app?.trimmingCharacters(in: .whitespacesAndNewlines),
              !requested.isEmpty else {
            return ActionOutcome(ok: false, summary: "[close: no app]", pillMessage: "Close which app?")
        }
        let name = AppResolver.resolveRunning(requested) ?? AppResolver.resolve(requested) ?? requested
        let lower = name.lowercased()
        // Never quit ourselves or Finder.
        guard lower != "zeldaFlow", lower != "finder" else {
            return ActionOutcome(ok: false, summary: "[close refused: \(name)]",
                                 pillMessage: "Can't close \(name)")
        }
        let running = await MainActor.run {
            NSWorkspace.shared.runningApplications.first {
                $0.activationPolicy == .regular &&
                ($0.localizedName?.caseInsensitiveCompare(name) == .orderedSame ||
                 $0.localizedName?.lowercased().contains(lower) == true)
            }
        }
        guard let running else {
            return ActionOutcome(ok: false, summary: "[close: not running: \(name)]",
                                 pillMessage: "\(name) isn't open")
        }
        let display = running.localizedName ?? name
        running.terminate()   // graceful quit — unsaved-changes dialogs still appear
        for _ in 0..<10 where !running.isTerminated {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return running.isTerminated
            ? ActionOutcome(ok: true, summary: "[closed \(display)]", pillMessage: "Closed \(display)")
            : ActionOutcome(ok: true, summary: "[asked \(display) to quit]",
                            pillMessage: "\(display) is asking about unsaved changes")
    }

    @MainActor
    static func openURL(_ a: ZeldaFlowAction) -> ActionOutcome {
        guard var s = a.url, !s.isEmpty else {
            return ActionOutcome(ok: false, summary: "[open_url: none]", pillMessage: "No URL")
        }
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s) else {
            return ActionOutcome(ok: false, summary: "[bad url]", pillMessage: "Bad URL")
        }
        NSWorkspace.shared.open(url)
        return ActionOutcome(ok: true, summary: "[opened \(s)]",
                             pillMessage: "Opening \(url.host ?? s)")
    }

    @MainActor
    static func typeText(_ a: ZeldaFlowAction, context: CommandContext) async -> ActionOutcome {
        guard let text = a.text, !text.isEmpty else {
            return ActionOutcome(ok: false, summary: "[type_text: empty]", pillMessage: "Nothing to write")
        }
        let result = await TextInserter.insert(text, expectedFrontmost: context.expectedFrontmost)
        switch result {
        case .pasted:
            return ActionOutcome(ok: true, summary: text, pillMessage: nil)
        case .leftOnClipboard(let reason):
            return ActionOutcome(ok: false, summary: text, pillMessage: reason)
        }
    }

    // MARK: - Navigation

    /// Directions in Apple Maps from the current location. On macOS the
    /// maps:// URL computes the route AND opens the turn-by-turn Details
    /// panel by itself — verified live; no UI scripting needed.
    @MainActor
    static func navigate(_ a: ZeldaFlowAction) -> ActionOutcome {
        guard let dest = a.destination?.trimmingCharacters(in: .whitespacesAndNewlines),
              !dest.isEmpty else {
            return ActionOutcome(ok: false, summary: "[navigate: no destination]",
                                 pillMessage: "Directions to where?")
        }
        let flag: String
        switch a.transport?.lowercased() {
        case "walk", "walking": flag = "w"
        case "transit", "public transit", "train", "bus": flag = "r"
        default: flag = "d"
        }
        // Alphanumerics-only encoding: .urlQueryAllowed passes '&' and '='
        // through, so "H&M Times Square" would truncate the daddr parameter.
        let encoded = dest.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? dest
        guard let url = URL(string: "maps://?daddr=\(encoded)&dirflg=\(flag)") else {
            return ActionOutcome(ok: false, summary: "[navigate: bad destination]",
                                 pillMessage: "Couldn't map that destination")
        }
        NSWorkspace.shared.open(url)
        Log.info("navigate: \(dest) (\(flag))")
        return ActionOutcome(ok: true, summary: "[directions to \(dest)]",
                             pillMessage: "🧭 Directions to \(dest)")
    }

    // MARK: - Music

    static func playMusic(_ a: ZeldaFlowAction) async -> ActionOutcome {
        // The LLM sometimes emits "" for fields the user didn't mention —
        // treat those as absent, never as a real value.
        func norm(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        let song = norm(a.song), artist = norm(a.artist), playlist = norm(a.playlist)

        // A named service we can't drive (YouTube Music, Tidal…): open it
        // for the user instead of hijacking the request into another player.
        if let service = norm(a.service), MusicPlayer.named(service) == nil {
            if let app = AppResolver.resolve(service) {
                return await openApp(ZeldaFlowAction(action: "open_app", app: app))
            }
            if let web = AppResolver.webFallback(for: service) {
                await MainActor.run { NSWorkspace.shared.open(web) }
                return ActionOutcome(ok: true, summary: "[opened \(web.absoluteString)]",
                                     pillMessage: "zeldaFlow drives Apple Music & Spotify — opened \(service) for you")
            }
            return ActionOutcome(ok: false, summary: "[unsupported music service: \(service)]",
                                 pillMessage: "zeldaFlow can only control Apple Music and Spotify")
        }

        switch await MusicPlayer.resolve(named: norm(a.service)) {
        case .spotify:
            return await playInSpotify(song: song, artist: artist, playlist: playlist)
        case .appleMusic:
            return await playInAppleMusic(song: song, artist: artist, playlist: playlist)
        }
    }

    /// Spotify's AppleScript can control playback but not search the catalog,
    /// so specific requests open the in-app search — one click from playing —
    /// and generic ones just resume.
    private static func playInSpotify(song: String?, artist: String?,
                                      playlist: String?) async -> ActionOutcome {
        let term = [song, artist].compactMap { $0 }.joined(separator: " ")
        let query = playlist.map { "\($0) playlist" } ?? term

        guard MusicPlayer.spotify.isInstalled else {
            // The user named Spotify on a Mac without it — the web player is
            // the honest fallback, never a silent switch to another app.
            let path = query.isEmpty ? "" : "search/" +
                (query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query)
            if let url = URL(string: "https://open.spotify.com/" + path) {
                await MainActor.run { NSWorkspace.shared.open(url) }
            }
            return ActionOutcome(ok: true, summary: "[Spotify web: \(query.isEmpty ? "open" : query)]",
                                 pillMessage: "Spotify isn't installed — opening the web player")
        }

        if query.isEmpty {
            let r = await AppleScriptRunner.run("""
            tell application "Spotify"
                activate
                play
            end tell
            """)
            return ActionOutcome(ok: r.ok, summary: "[Spotify: play]",
                                 pillMessage: r.ok ? "♪ Playing in Spotify" : "Spotify error")
        }

        // Percent-encoding to alphanumerics leaves nothing that could escape
        // the AppleScript string literal.
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
        let r = await AppleScriptRunner.run("""
        tell application "Spotify"
            activate
            open location "spotify:search:\(encoded)"
        end tell
        """)
        return ActionOutcome(ok: r.ok, summary: "[Spotify search: \(query)]",
                             pillMessage: r.ok ? "♪ “\(query)” is up in Spotify — pick one to play"
                                              : "Spotify error")
    }

    private static func playInAppleMusic(song: String?, artist: String?,
                                         playlist: String?) async -> ActionOutcome {
        let q = AppleScriptRunner.quote

        if let playlist {
            let script = """
            tell application "Music"
                activate
                set pls to (every playlist whose name contains \(q(playlist)))
                if (count of pls) is 0 then return "NOTFOUND"
                set shuffle enabled to true
                play item 1 of pls
                return "Playing playlist " & (name of item 1 of pls)
            end tell
            """
            let r = await AppleScriptRunner.run(script)
            if r.ok, r.output != "NOTFOUND" {
                return ActionOutcome(ok: true, summary: "[\(r.output)]", pillMessage: "♪ \(r.output)")
            }
            return ActionOutcome(ok: false, summary: "[playlist not found]",
                                 pillMessage: "No playlist matching “\(playlist)”")
        }

        // Build library filters, most specific first. A bare "play X" may be
        // a song OR an artist, so try both before giving up on the library.
        var filters: [(filter: String, shuffle: Bool)] = []
        if let song {
            if let artist {
                filters.append(("name contains \(q(song)) and artist contains \(q(artist))", false))
            }
            filters.append(("name contains \(q(song))", false))
            if artist == nil {
                filters.append(("artist contains \(q(song))", true))
            }
        } else if let artist {
            filters.append(("artist contains \(q(artist))", true))
        }

        guard !filters.isEmpty else {
            let r = await AppleScriptRunner.run("""
            tell application "Music"
                activate
                set shuffle enabled to true
                play library playlist 1
                return "Playing your library"
            end tell
            """)
            return ActionOutcome(ok: r.ok, summary: "[play library]",
                                 pillMessage: r.ok ? "♪ Playing your library" : "Music error")
        }

        for (filter, shuffle) in filters {
            let script = """
            tell application "Music"
                activate
                set matches to (every track of library playlist 1 whose \(filter))
                if (count of matches) is 0 then return "NOTFOUND"
                \(shuffle ? "set shuffle enabled to true" : "")
                play item 1 of matches
                return "Playing " & (name of item 1 of matches) & " — " & (artist of item 1 of matches)
            end tell
            """
            let r = await AppleScriptRunner.run(script)
            if r.ok, r.output != "NOTFOUND" {
                Log.info("playMusic: library hit via [\(filter)]")
                return ActionOutcome(ok: true, summary: "[\(r.output)]", pillMessage: "♪ \(r.output)")
            }
            if !r.ok { break }
        }
        Log.info("playMusic: no library match (song: \(song ?? "-"), artist: \(artist ?? "-")) — trying catalog")

        // Not in the library: find it in the Apple Music catalog and play it.
        let term = [song, artist].compactMap { $0 }.joined(separator: " ")
        if let track = await AppleMusicCatalog.topTrack(song: song, artist: artist) {
            switch await AppleMusicCatalog.play(track) {
            case .playing(let label):
                return ActionOutcome(ok: true, summary: "[Playing \(label)]",
                                     pillMessage: "♪ \(label)")
            case .opened:
                return ActionOutcome(ok: true, summary: "[opened in Music: \(track.name)]",
                                     pillMessage: "♪ \(track.name) is up in Music — press play")
            case .failed:
                break
            }
        }
        // Last resort: Apple Music search page. Alphanumerics-only encoding —
        // '&' in a song title must not split the query parameter.
        let encoded = term.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? term
        if let url = URL(string: "music://music.apple.com/search?term=\(encoded)") {
            await MainActor.run { NSWorkspace.shared.open(url) }
        }
        return ActionOutcome(ok: true, summary: "[searched Apple Music: \(term)]",
                             pillMessage: "Not in library — searching for “\(term)”")
    }

    static func musicControl(_ a: ZeldaFlowAction) async -> ActionOutcome {
        let cmd: String
        switch a.command ?? "" {
        case "pause": cmd = "pause"
        case "play": cmd = "play"
        case "next": cmd = "next track"
        case "previous": cmd = "previous track"
        default:
            return ActionOutcome(ok: false, summary: "[music_control: ?]", pillMessage: "Unknown playback command")
        }
        // "Pause" means whatever is audibly playing on this Mac — Spotify or
        // Music — not a hardcoded app.
        let player = await MusicPlayer.resolve(named: a.service, preferActive: true)
        guard player.isInstalled else {
            // Only reachable when the user named a player by voice —
            // "pause spotify" on a Mac without it deserves the honest answer.
            return ActionOutcome(ok: false, summary: "[\(player.displayName) not installed]",
                                 pillMessage: "\(player.displayName) isn't installed on this Mac")
        }
        let r = await AppleScriptRunner.run(
            "tell application \(AppleScriptRunner.quote(player.rawValue)) to \(cmd)")
        return ActionOutcome(ok: r.ok, summary: "[\(player.displayName): \(cmd)]",
                             pillMessage: r.ok ? "♪ \(a.command ?? "")" : "\(player.displayName) error")
    }

    static func setVolume(_ a: ZeldaFlowAction) async -> ActionOutcome {
        let script: String
        let label: String
        if let mute = a.mute {
            script = "set volume \(mute ? "with" : "without") output muted"
            label = mute ? "Muted" : "Unmuted"
        } else if let level = a.level {
            let clamped = max(0, min(100, level))
            script = "set volume output volume \(clamped)"
            label = "Volume \(clamped)%"
        } else {
            return ActionOutcome(ok: false, summary: "[set_volume: ?]", pillMessage: "No volume level")
        }
        let r = await AppleScriptRunner.run(script)
        return ActionOutcome(ok: r.ok, summary: "[\(label)]", pillMessage: r.ok ? label : "Volume error")
    }

    // MARK: - Reminders / Notes / Calendar (personal organizers, no recipient)

    static func addReminder(_ a: ZeldaFlowAction) async -> ActionOutcome {
        guard let title = a.title, !title.isEmpty else {
            return ActionOutcome(ok: false, summary: "[reminder: no title]", pillMessage: "Remind you about what?")
        }
        let q = AppleScriptRunner.quote
        let script: String
        if let dateStr = a.date,
           let dateLines = AppleScriptRunner.dateAssignment(varName: "d", from: dateStr) {
            script = """
            \(dateLines)
            tell application "Reminders" to make new reminder with properties {name:\(q(title)), due date:d}
            """
        } else {
            script = "tell application \"Reminders\" to make new reminder with properties {name:\(q(title))}"
        }
        let r = await AppleScriptRunner.run(script)
        return ActionOutcome(ok: r.ok, summary: "[reminder: \(title)]",
                             pillMessage: r.ok ? "☑️ Reminder: \(title)" : "Reminders error")
    }

    static func createNote(_ a: ZeldaFlowAction) async -> ActionOutcome {
        let title = a.title ?? "Voice note"
        let body = a.body ?? a.text ?? ""
        let q = AppleScriptRunner.quote
        let html = body
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "\n", with: "<br>")
        let script = "tell application \"Notes\" to make new note with properties {name:\(q(title)), body:\(q(html))}"
        let r = await AppleScriptRunner.run(script)
        return ActionOutcome(ok: r.ok, summary: "[note: \(title)]",
                             pillMessage: r.ok ? "📝 Note: \(title)" : "Notes error")
    }

    static func createEvent(_ a: ZeldaFlowAction) async -> ActionOutcome {
        guard let title = a.title, !title.isEmpty,
              let dateStr = a.date,
              let dateLines = AppleScriptRunner.dateAssignment(varName: "d", from: dateStr) else {
            return ActionOutcome(ok: false, summary: "[event: needs title+date]",
                                 pillMessage: "Need an event title and time")
        }
        let minutes = a.durationMinutes ?? 60
        let q = AppleScriptRunner.quote
        // "calendar 1" can be a read-only subscribed calendar (Holidays,
        // Birthdays) on someone else's Mac — pick the first writable one.
        let script = """
        \(dateLines)
        tell application "Calendar"
            set targetCal to missing value
            repeat with c in calendars
                if writable of c then
                    set targetCal to c
                    exit repeat
                end if
            end repeat
            if targetCal is missing value then set targetCal to calendar 1
            tell targetCal
                make new event with properties {summary:\(q(title)), start date:d, end date:d + (\(minutes) * minutes)}
            end tell
        end tell
        """
        let r = await AppleScriptRunner.run(script)
        return ActionOutcome(ok: r.ok, summary: "[event: \(title) @ \(dateStr)]",
                             pillMessage: r.ok ? "📅 \(title) — \(dateStr)" : "Calendar error")
    }
}
