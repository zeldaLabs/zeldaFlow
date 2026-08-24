import Foundation
import AppKit

/// Which music app a play/control action should drive. zeldaFlow adapts to the
/// machine it's on instead of assuming the author's: an explicitly named
/// service always wins, then the user's Settings choice, then whatever this
/// Mac is actually using. Music.app ships with every Mac, so it's the floor.
enum MusicPlayer: String, CaseIterable {
    case appleMusic = "Music"
    case spotify = "Spotify"

    var bundleID: String {
        switch self {
        case .appleMusic: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        }
    }

    /// Name people say, for pill messages ("Music" reads oddly in a sentence).
    var displayName: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .spotify: return "Spotify"
        }
    }

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    /// "playing" / "paused" / "stopped", or nil when the app isn't running —
    /// asked via AppleScript only for running apps, because a bare
    /// `tell application` would launch it just to answer the question.
    func playerState() async -> String? {
        guard isRunning else { return nil }
        let r = await AppleScriptRunner.run(
            "tell application \(AppleScriptRunner.quote(rawValue)) to player state as string")
        return r.ok ? r.output.lowercased() : nil
    }

    /// The player a spoken service name refers to, if any ("on spotify",
    /// "in my library", "on apple music"). Third-party services we can't
    /// drive ("youtube music") return nil so the caller degrades honestly
    /// instead of hijacking the request into Apple Music.
    static func named(_ service: String?) -> MusicPlayer? {
        guard let s = service?.lowercased(), !s.isEmpty else { return nil }
        if s.contains("spotify") { return .spotify }
        if s.contains("youtube") || s.contains("tidal") || s.contains("deezer")
            || s.contains("soundcloud") || s.contains("amazon") { return nil }
        if s.contains("apple") || s == "music" || s.contains("library") { return .appleMusic }
        return nil
    }

    /// Resolve the player for this action on THIS machine.
    /// `preferActive` is true for playback control (pause/next): whatever is
    /// audibly playing is what the user means, regardless of their default.
    static func resolve(named service: String?, preferActive: Bool = false) async -> MusicPlayer {
        if let explicit = named(service) { return explicit }

        var configured: MusicPlayer?
        switch AppSettings.shared.musicApp {
        case "music": configured = .appleMusic
        case "spotify": configured = .spotify
        default: break   // auto
        }
        if let configured, !preferActive { return configured }

        // Playing beats everything; paused beats merely-running — a paused
        // player owns the session "resume"/"next" refers to.
        let spotifyState = await MusicPlayer.spotify.playerState()
        let musicState = await MusicPlayer.appleMusic.playerState()
        if spotifyState == "playing" { return .spotify }
        if musicState == "playing" { return .appleMusic }
        if spotifyState == "paused" { return .spotify }
        if musicState == "paused" { return .appleMusic }
        if let configured { return configured }
        if MusicPlayer.spotify.isRunning { return .spotify }
        if MusicPlayer.appleMusic.isRunning { return .appleMusic }
        // Nothing running: Spotify's presence means someone chose to install
        // it; Music is the universal fallback.
        if MusicPlayer.spotify.isInstalled { return .spotify }
        return .appleMusic
    }
}
