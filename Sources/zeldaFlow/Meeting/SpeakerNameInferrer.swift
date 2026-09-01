import Foundation

/// Infers participants' real names from the transcript itself (ADR 38):
/// people say each other's names — "Thanks, Priya", "this is Marcus from
/// infra" — and diarization already split the far side into speakers, so one
/// schema-constrained Gemma call over selected evidence lines can propose
/// {speaker → name}. Everything the model claims is then re-verified by pure
/// Swift: a name survives only when it literally appears in the transcript
/// AND the quoted evidence line does too. Ambiguity keeps "Speaker N" — a
/// wrong name in someone's meeting notes is worse than no name, and a user
/// rename (which always wins) fixes a miss in one click.
///
/// Fail-closed throughout: a dead server, a garbled reply, or zero accepted
/// proposals changes nothing and notes still run.
enum SpeakerNameInferrer {

    struct Proposal: Codable, Equatable {
        let label: String     // a pre-inference roster label ("Speaker 1", "Them")
        let name: String
        let evidence: String  // the transcript line that proves it, near-verbatim
    }

    private struct Reply: Codable {
        let speakers: [Proposal]
    }

    static let systemPrompt = """
    You identify meeting participants' real names from a transcript. Each line begins with a speaker label and a colon. "You" is the user; the other labels are the other participants. People sometimes say each other's names ("Thanks, Priya", "this is Marcus from infra"). A name spoken by one speaker usually addresses a DIFFERENT speaker — most often the previous one. "This is X", "I'm X", or "my name is X" names the CURRENT speaker.

    Reply with JSON only, matching the schema you are given. For each label you can name with confidence, give the name exactly as it appears in the transcript and quote the line that proves it. Skip any speaker you are not sure about. Never guess and never invent names.
    """

    // MARK: - Evidence selection (pure; pinned by the evals)

    private static let evidenceHeadBudget = 3_000
    private static let evidenceTotalBudget = 3_500
    private static let maxPatternLines = 10

    /// Vocatives and self-introductions — the two places names actually get
    /// said. Case-sensitive capital start keeps "thanks, everyone" out.
    static let vocativePattern = try! NSRegularExpression(
        pattern: "\\b(?i:thanks|thank you|hi|hey|hello|welcome|go ahead|over to you|good point|agreed),?\\s+([A-Z][\\p{L}'-]+)")
    static let selfIntroPattern = try! NSRegularExpression(
        pattern: "\\b(?i:this is|i'?m|i am|my name is)\\s+([A-Z][\\p{L}'-]+)")

    /// The head of the transcript (introductions live at the start) plus up
    /// to ten later lines matching a name pattern — each such line preceded
    /// by the line before it, because a vocative usually addresses the
    /// previous speaker and the model needs to see who that was.
    static func evidenceExcerpt(transcript: String) -> String {
        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        var head = ""
        var headCount = 0
        for line in lines {
            guard head.count + line.count + 1 <= evidenceHeadBudget else { break }
            head += head.isEmpty ? line : "\n" + line
            headCount += 1
        }
        var extras: [String] = []
        var extraLines = 0
        for (i, line) in lines.enumerated() where i >= headCount {
            guard extraLines < maxPatternLines else { break }
            let range = NSRange(line.startIndex..., in: line)
            let hasName = vocativePattern.firstMatch(in: line, range: range) != nil
                || selfIntroPattern.firstMatch(in: line, range: range) != nil
            guard hasName else { continue }
            var piece = i > 0 ? lines[i - 1] + "\n" + line : line
            if head.count + extras.joined().count + piece.count > evidenceTotalBudget {
                piece = line
            }
            extras.append(piece)
            extraLines += 1
        }
        var out = head
        for extra in extras where out.count + extra.count + 2 <= evidenceTotalBudget {
            out += "\n" + extra
        }
        return out
    }

    // MARK: - Acceptance gate (pure; pinned by the evals)

    /// Words that match the name shape but are conversation furniture.
    static let nameStoplist: Set<String> = [
        "okay", "yeah", "right", "thanks", "hello", "hey", "hi", "sorry",
        "sure", "great", "everyone", "guys", "folks", "team", "all", "sir",
        "madam", "monday", "tuesday", "wednesday", "thursday", "friday",
        "saturday", "sunday", "january", "february", "march", "april", "may",
        "june", "july", "august", "september", "october", "november",
        "december", "today", "tomorrow", "yesterday", "god",
    ]

    private static let nameShape = try! NSRegularExpression(
        pattern: "^[A-Z][\\p{L}'-]{1,19}( [A-Z][\\p{L}'-]{1,19})?$")

    /// A proposal survives only when: the name has a name's shape, appears as
    /// a whole word in the transcript, isn't furniture, its evidence line
    /// exists near-verbatim (the hallucination tripwire), the label maps to a
    /// far-side roster key, and no other speaker already took the name.
    /// First by evidence position wins a collision.
    static func accept(proposals: [Proposal], transcript: String,
                       roster: MeetingRoster) -> [String: String] {
        let normalizedTranscript = normalize(transcript)
        var byKey: [String: String] = [:]
        var takenNames: Set<String> = []
        let ordered = proposals.sorted {
            (position(of: $0.evidence, in: normalizedTranscript) ?? .max)
                < (position(of: $1.evidence, in: normalizedTranscript) ?? .max)
        }
        for proposal in ordered {
            let name = proposal.name.trimmingCharacters(in: .whitespaces)
            guard let key = roster.key(forLabel: proposal.label), key != "you",
                  byKey[key] == nil,
                  nameShape.firstMatch(in: name,
                      range: NSRange(name.startIndex..., in: name)) != nil,
                  !nameStoplist.contains(name.lowercased()),
                  !takenNames.contains(name.lowercased()),
                  appearsAsWord(name, in: transcript),
                  position(of: proposal.evidence, in: normalizedTranscript) != nil
            else { continue }
            byKey[key] = name
            takenNames.insert(name.lowercased())
        }
        return byKey
    }

    private static func appearsAsWord(_ name: String, in transcript: String) -> Bool {
        let pattern = "(?i)\\b" + NSRegularExpression.escapedPattern(for: name) + "\\b"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        return re.firstMatch(in: transcript,
                             range: NSRange(transcript.startIndex..., in: transcript)) != nil
    }

    /// Whitespace/punctuation-insensitive containment — the model re-quotes
    /// lines with drifting commas, but invented evidence never survives.
    private static func position(of evidence: String, in normalizedHaystack: String) -> Int? {
        let needle = normalize(evidence)
        guard needle.count >= 8 else { return nil }
        guard let range = normalizedHaystack.range(of: needle) else { return nil }
        return normalizedHaystack.distance(from: normalizedHaystack.startIndex,
                                           to: range.lowerBound)
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - The one model call

    static func schema(labels: [String]) -> CleanupService.JSONValue {
        typealias J = CleanupService.JSONValue
        return .object([
            "type": .string("object"),
            "properties": .object([
                "speakers": .object([
                    "type": .string("array"),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "label": .object([
                                "type": .string("string"),
                                "enum": .array(labels.map { .string($0) }),
                            ]),
                            "name": .object(["type": .string("string")]),
                            "evidence": .object(["type": .string("string")]),
                        ]),
                        "required": .array([.string("label"), .string("name"),
                                            .string("evidence")]),
                        "additionalProperties": .bool(false),
                    ]),
                ]),
            ]),
            "required": .array([.string("speakers")]),
            "additionalProperties": .bool(false),
        ])
    }

    /// nil = nothing learned (server down, both attempts garbled, or no
    /// proposal survived the gate) — the caller changes nothing.
    static func infer(segments: [MeetingSegment], roster: MeetingRoster,
                      cleanup: CleanupService,
                      dictationActive: @escaping () -> Bool) async -> [String: String]? {
        let farLabels = roster.farSideEntries.map(\.label)
        guard !farLabels.isEmpty else { return nil }
        let transcript = segments.speakerTranscriptText(roster: roster)
        let excerpt = evidenceExcerpt(transcript: transcript)
        guard !excerpt.isEmpty else { return nil }
        let callSchema = schema(labels: farLabels)

        for attemptNumber in 1...2 {
            while dictationActive() {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            if let reply = await cleanup.structured(
                    system: systemPrompt, user: excerpt, maxTokens: 300,
                    schema: callSchema, schemaName: "speakers"),
               let start = reply.firstIndex(of: "{"),
               let end = reply.lastIndex(of: "}"), start < end,
               let decoded = try? JSONDecoder().decode(
                    Reply.self, from: Data(String(reply[start...end]).utf8)) {
                let accepted = accept(proposals: decoded.speakers,
                                      transcript: transcript, roster: roster)
                Log.info("SpeakerNameInferrer: \(decoded.speakers.count) proposed, " +
                         "\(accepted.count) accepted")
                return accepted.isEmpty ? nil : accepted
            }
            Log.error("SpeakerNameInferrer: call failed (attempt \(attemptNumber)/2)")
        }
        return nil
    }
}
