import Foundation
import AppKit

/// Plays songs that aren't in the user's library straight from the Apple
/// Music catalog. Search uses the public iTunes Search API (no key needed);
/// playback opens the track's deep link in Music.app and verifies the right
/// song actually started before claiming success.
enum AppleMusicCatalog {
    struct Track {
        let name: String
        let artist: String
        let url: String
    }

    /// Best catalog match for a spoken song/artist query, in the user's
    /// storefront. Cascades from precise to fuzzy so genre words ("jazz"),
    /// soundtrack names, and half-misheard queries still land somewhere
    /// sensible instead of nowhere.
    static func topTrack(song: String?, artist: String?) async -> Track? {
        let term = [song, artist].compactMap { $0 }.joined(separator: " ")
        guard !term.isEmpty else { return nil }
        let artistOnly = (song == nil)
        let country = (Locale.current.region?.identifier ?? "US").lowercased()

        var results = await search(term: term, country: country, artistOnly: artistOnly)
        if results.isEmpty, artistOnly {
            // Not an artist name — treat it as a genre/mood/movie search.
            results = await search(term: term, country: country, artistOnly: false)
        }
        if results.isEmpty, let song, artist != nil {
            // Combined query missed (artist word may be garbage) — song alone.
            results = await search(term: song, country: country, artistOnly: false)
        }
        if results.isEmpty, country != "us" {
            results = await search(term: term, country: "us", artistOnly: false)
        }
        Log.info("AppleMusicCatalog: \(results.count) results for \"\(term)\"" +
                 (results.isEmpty ? "" : " — top: \(results[0].name) — \(results[0].artist)"))
        guard !results.isEmpty else { return nil }

        // When the user named an artist, insist the match is really theirs —
        // the API happily returns cover versions otherwise.
        if let artist {
            let want = artist.lowercased()
            let theirs = results.filter { $0.artist.lowercased().contains(want) }
            // Prefer a real song over background scores / instrumentals.
            if let hit = theirs.first(where: { t in
                let n = t.name.lowercased()
                return !n.contains("background score") && !n.contains("instrumental") && !n.contains("theme")
            }) {
                return hit
            }
            if let hit = theirs.first { return hit }
        }
        return results.first
    }

    private struct SearchResponse: Decodable {
        struct Result: Decodable {
            let trackName: String?
            let artistName: String?
            let trackViewUrl: String?
        }
        let results: [Result]
    }

    private static func search(term: String, country: String, artistOnly: Bool) async -> [Track] {
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        var items = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "country", value: country),
        ]
        if artistOnly {
            items.append(URLQueryItem(name: "attribute", value: "artistTerm"))
        }
        comps.queryItems = items
        guard let url = comps.url else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let parsed = try? JSONDecoder().decode(SearchResponse.self, from: data) else {
            return []
        }
        return parsed.results.compactMap { r in
            guard let name = r.trackName, let artist = r.artistName,
                  let link = r.trackViewUrl else { return nil }
            return Track(name: name, artist: artist, url: link)
        }
    }

    enum PlayResult {
        case playing(String)   // confirmed the requested track is playing
        case opened            // track page is open in Music, playback unconfirmed
        case failed
    }

    /// Open the track's page in Music and press its Play button. Verified
    /// empirically: `open location` never auto-plays a catalog track, and
    /// AppleScript `play` only resumes the OLD queue — so the page's own
    /// Play control (pressed via accessibility) is the only real path.
    /// Every step is verified against the expected track name; we never
    /// leave the wrong song playing and call it success.
    static func play(_ track: Track) async -> PlayResult {
        let q = AppleScriptRunner.quote
        // `reopen` first: if the user closed Music's window the app keeps
        // running headless, open location silently goes nowhere, and there
        // is no page to press Play on.
        let open = await AppleScriptRunner.run("""
        with timeout of 20 seconds
        tell application "Music"
            reopen
            activate
            open location \(q(track.url))
        end tell
        end timeout
        """)
        guard open.ok else {
            Log.error("AppleMusicCatalog: open location failed")
            return .failed
        }
        // Let the page render before touching it.
        try? await Task.sleep(nanoseconds: 2_500_000_000)

        // In case a future Music version does auto-play the deep link.
        if let label = await verifyPlaying(expected: track.name, attempts: 1) {
            Log.info("AppleMusicCatalog: deep link auto-played \(label)")
            return .playing(label)
        }
        if let label = await MusicUIDriver.pressPlayAndVerify(expected: track.name) {
            Log.info("AppleMusicCatalog: playing via page button: \(label)")
            return .playing(label)
        }

        // Observed: Music sometimes ignores the first open location (stays
        // on Home). Route the deep link through LaunchServices and retry.
        Log.info("AppleMusicCatalog: retrying navigation via music:// URL")
        let deepLink = track.url.replacingOccurrences(of: "https://", with: "music://")
        if let url = URL(string: deepLink) {
            await MainActor.run { NSWorkspace.shared.open(url) }
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if let label = await MusicUIDriver.pressPlayAndVerify(expected: track.name) {
                Log.info("AppleMusicCatalog: playing after retry: \(label)")
                return .playing(label)
            }
        }
        Log.info("AppleMusicCatalog: could not confirm playback — leaving page open")
        return .opened
    }

    /// Poll Music until the expected track is confirmed playing.
    /// Returns "Track — Artist" on success, nil if it never matches.
    static func verifyPlaying(expected: String, attempts: Int) async -> String? {
        for attempt in 0..<max(1, attempts) {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 700_000_000) }
            let r = await AppleScriptRunner.run("""
            tell application "Music"
                try
                    return (player state as text) & "|" & (name of current track) & "|" & (artist of current track)
                on error
                    return (player state as text) & "||"
                end try
            end tell
            """)
            guard r.ok else { continue }
            let parts = r.output.components(separatedBy: "|")
            guard parts.count >= 3, parts[0] == "playing" else { continue }
            let playing = parts[1].lowercased()
            let want = expected.lowercased()
            if !playing.isEmpty, playing.contains(want) || want.contains(playing) {
                return "\(parts[1]) — \(parts[2])"
            }
        }
        return nil
    }
}
