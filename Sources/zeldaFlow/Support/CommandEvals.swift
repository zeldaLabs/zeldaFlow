import Foundation

/// Deterministic behavior pins for the voice-command layer: the fast-path
/// parser, the confirmation gates, and the transcript scrubbing that stands
/// between the decoder and the user's document.
/// Run with `zeldaFlow --evalcommands`.
/// No LLM, no network, no permissions — safe on any machine, so these can
/// gate a release: if one fails, a command people rely on changed meaning.
enum CommandEvals {
    static func run() -> Int32 {
        var failures = 0
        func check(_ name: String, _ pass: Bool) {
            print(pass ? "  ok  \(name)" : "FAIL  \(name)")
            if !pass { failures += 1 }
        }
        func first(_ s: String) -> ZeldaFlowAction? { CommandFastPath.parse(s)?.first }

        print("zeldaFlow command evals")

        // Must-execute: exact-word commands the parser owns outright.
        var a = first("open safari")
        check("open safari → open_app Safari", a?.action == "open_app" && a?.app == "Safari")
        a = first("hey zelda flow can you please open safari")
        check("wake words stripped", a?.action == "open_app" && a?.app == "Safari")
        a = first("open spotify")
        check("open spotify → app when installed, else web player",
              a?.action == "open_app" || (a?.action == "open_url" && a?.url?.contains("spotify") == true))
        a = first("pause the music")
        check("pause the music → music_control pause", a?.action == "music_control" && a?.command == "pause")
        a = first("next track")
        check("next track → music_control next", a?.action == "music_control" && a?.command == "next")
        a = first("set the volume to 40")
        check("set the volume to 40 → set_volume 40", a?.action == "set_volume" && a?.level == 40)
        a = first("mute")
        check("mute → set_volume muted", a?.action == "set_volume" && a?.mute == true)

        // Music routing: names copied verbatim, service only when spoken.
        a = first("play blinding lights by the weeknd")
        check("play <song> by <artist>", a?.action == "play_music"
              && a?.song == "Blinding Lights" && a?.artist == "The Weeknd" && a?.service == nil)
        a = first("play some coldplay songs on spotify")
        check("named service reaches the action", a?.action == "play_music"
              && a?.artist == "Coldplay" && a?.service == "spotify")
        a = first("play some jazz on apple music")
        check("apple music by name", a?.action == "play_music" && a?.service == "apple music")
        a = first("play my gym playlist")
        check("play my gym playlist → playlist Gym", a?.action == "play_music" && a?.playlist == "Gym")

        // Navigation and questions.
        a = first("navigate to the airport")
        check("navigate to X → drive directions", a?.action == "navigate" && a?.transport == "drive")
        a = first("walk me to the station")
        check("walk me to X → walking directions", a?.action == "navigate" && a?.transport == "walk")
        a = first("what's the weather in paris")
        check("question → web_answer", a?.action == "web_answer")
        a = first("make this shorter")
        check("make this shorter → edit_text", a?.action == "edit_text")

        // Must-defer: ambiguity belongs to the LLM, never guessed here.
        check("multi-intent defers to LLM", CommandFastPath.parse("open notes and play some jazz") == nil)
        check("messaging defers to LLM", CommandFastPath.parse("text sarah i'm on my way") == nil)
        check("close the tab is not close_app", CommandFastPath.parse("close the tab") == nil)

        // Must-confirm: the gates around anything that leaves this Mac.
        let email = ZeldaFlowAction(action: "send_email", to: "sam@example.com")
        check("send_email gated when confirmation is on",
              ActionGate.confirmationLabel(for: email, confirmBeforeSending: true) != nil)
        check("send_email ungated when user turned it off",
              ActionGate.confirmationLabel(for: email, confirmBeforeSending: false) == nil)
        check("draft_email never gated (nothing is sent)",
              ActionGate.confirmationLabel(for: ZeldaFlowAction(action: "draft_email", to: "sam"),
                                           confirmBeforeSending: true) == nil)
        check("send_message gated",
              ActionGate.confirmationLabel(for: ZeldaFlowAction(action: "send_message", to: "Sarah"),
                                           confirmBeforeSending: true) != nil)
        check("agent_task ALWAYS gated, regardless of settings",
              ActionGate.alwaysConfirmLabel(for: ZeldaFlowAction(action: "agent_task", task: "tidy downloads")) != nil)

        // Must-not-paste: the decoder reciting its own prompt, or looping on
        // one segment, must never reach the user's document.
        let dictPrompt = "This is a carefully punctuated dictated note. Glossary: Manu, zeldaFlow, Anthropic."
        func scrub(_ s: String) -> String { HallucinationFilter.scrubFinal(s, prompt: dictPrompt) }
        check("bare \"Glossary.\" echo dropped", scrub("Glossary.").isEmpty)
        check("repetition loop collapses away",
              scrub(String(repeating: "Glossary. ", count: 150)).isEmpty)
        check("emphatic repetition is capped, not erased",
              scrub(String(repeating: "No. ", count: 20)) == "No. No. No.")
        check("real dictation survives byte-identical",
              scrub("Ship the build today. Then tell Sam.") == "Ship the build today. Then tell Sam.")
        check("a genuine spoken glossary keeps its words",
              scrub("Glossary: API, SDK, REST.") == "Glossary: API, SDK, REST.")

        // Command mode doesn't paste what it hears — it *executes* it, so an
        // echo there is a different class of failure. Real case, 2026-08-04:
        // background noise decoded as "Glossary, Manushresth." and ran a web
        // search for the user's own name. Two holes let it through: the
        // command path never ran this filter at all, and a one-word glossary
        // echo slipped the ≥2-body-word rule anyway.
        let cmdPrompt = "This is a spoken command to a computer assistant. "
            + "Glossary: Manushresth, zeldaFlow, Anthropic."
        func scrubCmd(_ s: String) -> String {
            HallucinationFilter.scrubFinal(s, prompt: cmdPrompt)
        }
        check("one-word glossary echo dropped", scrubCmd("Glossary, Manushresth.").isEmpty)
        check("a real command survives", scrubCmd("Open Safari.") == "Open Safari.")
        check("a command naming a glossary word survives",
              scrubCmd("Open zeldaFlow settings.") == "Open zeldaFlow settings.")

        // Real case, 2026-08-08 (first Meet call): the decoder echoed the
        // glossary with a MISSPELLED term and looped it inside one comma-run
        // — "ZeldaWoo" is not a word we supplied and commas never end a
        // sentence, so both the echo rule and the sentence-run cap missed it.
        check("misspelled glossary loop dropped entirely",
              scrubCmd("Glossary, Manushresth, "
                       + String(repeating: "ZeldaWoo, ", count: 35) + "Ze").isEmpty)
        check("scaffold-less glossary recitation with a repeat dropped",
              scrubCmd("Manushresth, zeldaFlow, Manushresth.").isEmpty)
        check("a single glossary mention is kept (could be real speech)",
              scrubCmd("zeldaFlow.") == "zeldaFlow.")
        check("intra-sentence word loop capped, surrounding words kept",
              scrubCmd("Open zeldaFlow now now now now please.")
              == "Open zeldaFlow now now now please.")

        // Round two, same night: the echo came back TRUNCATED ("Zelda" for
        // "zeldaFlow" — 5 chars, under the old ≥6 fuzzy floor) and silence
        // decoded to a bare "." segment.
        check("truncated glossary echo dropped (Zelda ≈ zeldaFlow)",
              scrubCmd("Glossary, Zelda, Zelda, Zelda,").isEmpty)
        check("bare punctuation output drops to empty", scrub(".").isEmpty)
        check("meeting system scrub drops bare punctuation",
              HallucinationFilter.scrubMeetingSystem(".", prompt: dictPrompt).isEmpty)
        // Stronger than "no glossary": the far side is decoded with NO
        // prompt whatsoever, so there is nothing for whisper to recite back
        // into other people's speech (ADR 34).
        check("far-side decode carries no prompt at all",
              MeetingTranscriber.decodePrompt(for: .them).isEmpty)
        check("the user's own channel keeps its glossary prompt",
              MeetingTranscriber.decodePrompt(for: .you).contains("punctuated"))

        print(failures == 0 ? "OK — all pins hold" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }
}
