import Foundation

/// Map-reduce meeting notes on the resident Gemma E2B server (ADR 0027).
///
/// Why map-reduce at all: an hour of meeting is ~45-60 k chars of "You:/Them:"
/// transcript, and CleanupService's measured budget is ~4,500 input chars in
/// the 4,096-token context (past that llama-server truncates silently — found
/// by the 12-minute dictation stress test). So the transcript is chunked to
/// <= 3,800 chars (headroom for the ~1,000-char map system prompt plus the
/// 1,200-token reply), each chunk is mapped to schema-constrained JSON facts,
/// the facts are merged deterministically, and the model only ever writes
/// prose again for the 1-2 sentence opening summary, an optional polish pass,
/// and the title. 12-16 map calls per hour of meeting.
///
/// Adaptation source — OpenWhispr's single-shot prompt (actionProcessingStore.ts,
/// MEETING_SYSTEM_PROMPT), quoted so the ported rules are auditable. Their
/// cloud models take the whole transcript at once; our 4,096-token context
/// cannot, which is why its FORMAT RULES moved into the renderer (a format the
/// model never controls cannot be violated) and its CONTENT RULES moved into
/// the map prompt below:
///
///   You are a professional meeting notes assistant. You will receive a
///   dual-speaker transcript where "You:" marks the user's speech and "Them:"
///   marks the other participant(s), along with any manual notes the user took.
///
///   Your job is to produce clean, actionable meeting notes in markdown.
///   Follow these rules:
///
///   FORMAT RULES (strict):
///   - Do NOT include any preamble: no title, no "# Meeting Notes", no
///     date/time/location, no attendee list, no topic header. Start directly
///     with the summary.
///   - Do NOT use tables, horizontal rules, or block quotes.
///   - Do NOT list or guess participant names/roles.
///   - Start with a concise 1–2 sentence summary of what the meeting was about.
///   - Use clear section headings: ## Key Discussion Points, ## Decisions Made,
///     ## Action Items, ## Follow-ups (omit any section that has no content).
///   - Under Action Items, use checkboxes (`- [ ]`) and attribute each item to
///     "You" or "Them" where clear.
///
///   CONTENT RULES:
///   - Preserve important quotes or specific commitments verbatim when they
///     carry meaning.
///   - Remove filler, small talk, false starts, and repeated/redundant content.
///   - Where speakers refer to the same topic across multiple turns,
///     consolidate into a coherent point rather than listing every utterance.
///   - If the user included manual notes alongside the transcript, integrate
///     them — they represent the user's emphasis on what matters most.
///   - Keep the tone professional and concise. Bias toward brevity.
///
/// @MainActor for publication only (ObservableObject); the heavy string work
/// — chunking a 4 h transcript, the O(n²) bullet dedup — hops to detached
/// tasks, and the actor merely sequences model calls and progress callbacks.
@MainActor
final class MeetingNotesGenerator: ObservableObject {

    struct Result {
        let markdown: String
        let title: String
    }

    // MARK: - Shapes the model is forced into

    /// One action item. `owner` is grammar-constrained to "You|Them|Unclear"
    /// — the tokens simply cannot form anything else, so the renderer never
    /// meets a fourth speaker.
    struct ActionItem: Codable, Equatable {
        let owner: String
        let text: String
    }

    /// What one map call must produce for its chunk.
    struct MapOutput: Codable, Equatable {
        let summary: String
        let discussion: [String]
        let decisions: [String]
        let actions: [ActionItem]
        let followups: [String]
    }

    /// The four bullet sections — the merge result and the polish shape
    /// (MapOutput minus the per-chunk summary).
    struct Sections: Codable, Equatable {
        var discussion: [String]
        var decisions: [String]
        var actions: [ActionItem]
        var followups: [String]
    }

    // MARK: - Budgets

    /// Transcript chars per map chunk. CleanupService's measured context
    /// budget is ~4,500 chars; 3,800 leaves room for the ~1,000-char map
    /// system prompt and the 1,200-token reply in the same 4,096-token
    /// window (measured: the full map prompt evals at ~1,310 tokens, so
    /// prompt + reply peaks near 2,500 of 4,096).
    nonisolated static let chunkCharBudget = 3_800

    /// Past 75% of the budget, prefer to break at a speaker turn so an
    /// exchange (question + answer) lands in one chunk — a map call that sees
    /// only the question invents the answer's owner.
    nonisolated static let turnBreakThreshold = 2_850

    // MARK: - Prompts (static constants, NOTHING interpolated)

    /// CleanupService's KV-cache rule: cache_prompt only pays when the system
    /// prompt is byte-identical each call (measured 370/375 tokens cached on
    /// the planner) — so no "part N of M", no chunk counts, nothing varying.
    static let mapSystemPrompt = """
    You extract structured facts from one portion of a longer meeting transcript. "You:" marks the user's speech and "Them:" marks the other participant(s). Other portions are processed separately, so extract only what THIS text supports.

    Reply with JSON only, matching the schema you are given.

    CONTENT RULES:
    - "summary": one sentence stating what this portion of the meeting was about.
    - "discussion": the substantive points discussed. Where speakers return to the same topic across multiple turns, consolidate into one coherent point rather than listing every utterance.
    - "decisions": only things explicitly agreed, approved, or settled in this portion.
    - "actions": concrete commitments to do something. Set "owner" to "You" when the user committed, "Them" when the other participant(s) did, "Unclear" otherwise. Preserve specific commitments verbatim when the wording carries meaning.
    - "followups": open questions, deferred topics, or things to revisit later.
    - Remove filler, small talk, false starts, and repeated or redundant content.
    - Do NOT list or guess participant names or roles.
    - Leave any array empty when this portion has nothing for it. Keep each item to one concise sentence.
    """

    static let summarySystemPrompt = """
    You write the opening of meeting notes. You are given one-sentence summaries of consecutive portions of a single meeting, in order. Reply with a concise 1-2 sentence summary of what the whole meeting was about — plain text only, no preamble, no headings, no quotes.
    """

    static let polishSystemPrompt = """
    You tighten meeting notes. You are given draft bullet lists for the sections of one meeting's notes. Merge bullets that describe the same point, keep concrete details and verbatim commitments, and bias toward brevity. Do not invent content. Do not guess participant names or roles. Reply with JSON only, matching the schema you are given.
    """

    /// ported: generateTitle.ts TITLE_SYSTEM_PROMPT, verbatim.
    static let titleSystemPrompt = "Generate a concise 3-8 word title for these notes. Return ONLY the title text, nothing else — no quotes, no prefix, no explanation."

    // MARK: - Schemas

    static let mapSchema = notesSchema(includeSummary: true)
    static let polishSchema = notesSchema(includeSummary: false)

    nonisolated static func notesSchema(includeSummary: Bool) -> CleanupService.JSONValue {
        typealias J = CleanupService.JSONValue
        let stringArray: J = .object([
            "type": .string("array"),
            "items": .object(["type": .string("string")]),
        ])
        var props: [String: J] = [
            "discussion": stringArray,
            "decisions": stringArray,
            "actions": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "owner": .object([
                            "type": .string("string"),
                            "enum": .array([.string("You"), .string("Them"), .string("Unclear")]),
                        ]),
                        "text": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("owner"), .string("text")]),
                    "additionalProperties": .bool(false),
                ]),
            ]),
            "followups": stringArray,
        ]
        var required: [J] = [.string("discussion"), .string("decisions"),
                             .string("actions"), .string("followups")]
        if includeSummary {
            props["summary"] = .object(["type": .string("string")])
            required.insert(.string("summary"), at: 0)
        }
        return .object([
            "type": .string("object"),
            "properties": .object(props),
            "required": .array(required),
            "additionalProperties": .bool(false),
        ])
    }

    // MARK: - Chunker (pure; internal for the eval suite)

    /// Greedy fill by chars, never splitting a segment; past 75% of the
    /// budget a speaker turn (source change) is taken as the break point.
    /// Sorted by `start`, not insertion order — holdback releases commit out
    /// of spoken order (same rule as orderedTranscriptText, the port of
    /// OpenWhispr's buildOrderedTranscriptText).
    nonisolated static func chunk(_ segments: [MeetingSegment]) -> [String] {
        let ordered = segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
        var chunks: [String] = []
        var current = ""
        var lastSource: MeetingSegment.Source?
        for seg in ordered {
            let line = "\(seg.source == .you ? "You" : "Them"): \(seg.text)"
            let addition = current.isEmpty ? line.count : line.count + 1
            let wouldOverflow = current.count + addition > chunkCharBudget
            let turnBreak = current.count >= turnBreakThreshold && seg.source != lastSource
            if !current.isEmpty && (wouldOverflow || turnBreak) {
                chunks.append(current)
                current = ""
            }
            current += current.isEmpty ? line : "\n" + line
            lastSource = seg.source
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: - Deterministic merge (pure; internal for the eval suite)

    /// Concatenate in chunk order, then drop near-identical bullets with the
    /// same matcher that catches cross-channel echo — cross-chunk repetition
    /// is the same problem: one fact, transcribed twice, worded almost alike
    /// (a topic straddling a chunk boundary gets extracted by both maps).
    nonisolated static func merge(_ outputs: [MapOutput]) -> Sections {
        func dedup(_ items: [String]) -> [String] {
            var kept: [String] = []
            for item in items {
                let text = item.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                guard !kept.contains(where: { TranscriptMatcher.overlaps($0, text) }) else { continue }
                kept.append(text)
            }
            return kept
        }
        var actions: [ActionItem] = []
        for item in outputs.flatMap({ $0.actions }) {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let i = actions.firstIndex(where: { TranscriptMatcher.overlaps($0.text, text) }) {
                // First wording wins, but a duplicate that knows the owner
                // upgrades an "Unclear" — the commitment and its attribution
                // can land in different chunks.
                if actions[i].owner == "Unclear" && item.owner != "Unclear" {
                    actions[i] = ActionItem(owner: item.owner, text: actions[i].text)
                }
                continue
            }
            actions.append(ActionItem(owner: item.owner, text: text))
        }
        return Sections(discussion: dedup(outputs.flatMap { $0.discussion }),
                        decisions: dedup(outputs.flatMap { $0.decisions }),
                        actions: actions,
                        followups: dedup(outputs.flatMap { $0.followups }))
    }

    // MARK: - Renderer (pure; internal for the eval suite)

    /// Assembles OpenWhispr's exact note shape — summary paragraph, then the
    /// four "##" sections with `- [ ]` action checkboxes, empty sections
    /// omitted. Their FORMAT RULES are enforced by construction: a 2B model
    /// cannot violate a format it never controls, so no preamble, no tables,
    /// no invented attendee list — the model only ever supplied the bullets.
    nonisolated static func render(summary: String, sections: Sections) -> String {
        var parts: [String] = []
        let opening = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !opening.isEmpty { parts.append(opening) }
        if !sections.discussion.isEmpty {
            parts.append("## Key Discussion Points\n"
                + sections.discussion.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !sections.decisions.isEmpty {
            parts.append("## Decisions Made\n"
                + sections.decisions.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !sections.actions.isEmpty {
            parts.append("## Action Items\n" + sections.actions.map { item in
                // Owner prefix only when it says something; "Unclear" would
                // read as a person's name in a checklist.
                let prefix = (item.owner == "You" || item.owner == "Them") ? "\(item.owner): " : ""
                return "- [ ] \(prefix)\(item.text)"
            }.joined(separator: "\n"))
        }
        if !sections.followups.isEmpty {
            parts.append("## Follow-ups\n"
                + sections.followups.map { "- \($0)" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - JSON decoding (grammar makes malformed output rare, not impossible)

    nonisolated static func decodeMap(_ reply: String) -> MapOutput? {
        decodeJSON(reply, as: MapOutput.self)
    }

    nonisolated static func decodeSections(_ reply: String) -> Sections? {
        decodeJSON(reply, as: Sections.self)
    }

    /// Extract the outermost JSON object before decoding — same salvage as
    /// interpretCommand: grammar constrains the tokens, but a truncated reply
    /// (max_tokens hit) still arrives as broken JSON and must count as a
    /// failed call, not a crash.
    private nonisolated static func decodeJSON<T: Decodable>(_ reply: String, as type: T.Type) -> T? {
        guard let start = reply.firstIndex(of: "{"),
              let end = reply.lastIndex(of: "}"), start < end else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(String(reply[start...end]).utf8))
    }

    // MARK: - Generation

    /// One call at a time; between calls polls dictationActive (500 ms) and
    /// pauses while true — a dictation cleanup only ever waits behind the
    /// in-flight call (<= ~15 s worst, map input capped at 3,800 chars).
    /// progress fires on main after every completed model call.
    /// total = maps + 1 (summary) + (1 polish when it will run) + 1 (title).
    func generate(segments: [MeetingSegment],
                  cleanup: CleanupService,
                  dictationActive: @escaping () -> Bool,
                  progress: @escaping (_ completed: Int, _ total: Int) -> Void) async -> Result? {
        guard await cleanup.ensureReady(timeoutSeconds: 120) else {
            Log.error("MeetingNotesGenerator: llama-server not ready — notes failed, transcript kept")
            return nil
        }

        let chunks = await Task.detached(priority: .userInitiated) {
            Self.chunk(segments)
        }.value
        guard !chunks.isEmpty else {
            Log.error("MeetingNotesGenerator: empty transcript — nothing to write notes about")
            return nil
        }

        // Optimistically count the polish pass: it runs whenever the merged
        // bullets fit the context (most meetings under ~30 min), and a total
        // that drops by one late beats one that grows mid-run.
        var completed = 0
        var total = chunks.count + 3   // maps + summary + polish + title
        Log.info("MeetingNotesGenerator: \(segments.count) segments → \(chunks.count) map chunks")

        // MAP: one schema-constrained call per chunk. A failed call retries
        // once, then the whole run fails — partial notes that silently omit
        // 20 minutes of the meeting are worse than a visible failure the
        // user can retry (the transcript is already on disk).
        var outputs: [MapOutput] = []
        for (index, chunkText) in chunks.enumerated() {
            guard let output = await attempt(label: "map \(index + 1)/\(chunks.count)",
                                             dictationActive: dictationActive, decode: Self.decodeMap,
                                             call: {
                // 1,200, not 400: a dense chunk's JSON legitimately runs past
                // 400 tokens (measured 465 on a real 34-minute meeting), and a
                // capped reply is truncated JSON that fails decode — at
                // temperature 0 the retry then truncates identically, so an
                // undersized cap fails the whole run deterministically.
                await cleanup.structured(system: Self.mapSystemPrompt, user: chunkText,
                                         maxTokens: 1200, schema: Self.mapSchema)
            }) else { return nil }
            outputs.append(output)
            completed += 1
            progress(completed, total)
        }

        let merged = await Task.detached(priority: .userInitiated) {
            Self.merge(outputs)
        }.value

        // SUMMARY: always, free text over the N chunk summaries in order.
        let summaryInput = outputs.map { $0.summary.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        var summary = ""
        if summaryInput.isEmpty {
            // Grammar guarantees the field, not its content; all-empty
            // summaries would make a nonsense call. The renderer just omits
            // the opening paragraph.
            total -= 1
        } else {
            // maxTokens is generous for two sentences because the budget is
            // shared with a chain-of-thought we cannot switch off (measured
            // ~470 CoT tokens on the planner's six-character answers).
            guard let reply = await attempt(label: "summary", dictationActive: dictationActive,
                                            decode: { $0 }, call: {
                await cleanup.structured(system: Self.summarySystemPrompt, user: summaryInput,
                                         maxTokens: 400)
            }) else { return nil }
            summary = Self.stripWrappingQuotes(reply.trimmingCharacters(in: .whitespacesAndNewlines))
            completed += 1
            progress(completed, total)
        }

        // POLISH: one consolidation pass when the merged bullets fit the same
        // 3,800-char input budget the maps ran under. When they don't, ship
        // the deterministic merge — degrade gracefully rather than truncate
        // (llama-server truncates silently past the context; the merge is
        // complete, just less consolidated).
        var sections = merged
        let polishInput = Self.polishPayload(merged)
        if polishInput.count <= Self.chunkCharBudget {
            let polished = await attempt(label: "polish", dictationActive: dictationActive,
                                         decode: Self.decodeSections, call: {
                // Output can approach input size (~950 tokens for a full
                // 3,800-char draft), so the cap sits well above it.
                await cleanup.structured(system: Self.polishSystemPrompt, user: polishInput,
                                         maxTokens: 1200, schema: Self.polishSchema)
            })
            completed += 1
            if let polished, Self.hasContent(polished) || !Self.hasContent(merged) {
                sections = polished
            } else {
                // Same spirit as cleanup's shrink sanity check: a polish that
                // returns nothing (or nothing parseable) for a non-empty
                // draft gave up — the deterministic merge is the safer notes.
                Log.error("MeetingNotesGenerator: polish pass unusable — keeping deterministic merge")
            }
            progress(completed, total)
        } else {
            total -= 1
            Log.info("MeetingNotesGenerator: merged bullets \(polishInput.count) chars " +
                     "exceed the polish budget — shipping deterministic merge")
        }

        let markdown = await Task.detached(priority: .userInitiated) {
            Self.render(summary: summary, sections: sections)
        }.value

        // TITLE: ported generateTitle.ts — input truncated to 2,000 chars,
        // temperature 0.3, wrapping quotes stripped, 0 < len < 100 accepted.
        // A dead server or an out-of-range reply falls back to a dated title
        // rather than failing the run: the notes exist, and the record is
        // renameable anyway.
        var title = ""
        if let reply = await attempt(label: "title", dictationActive: dictationActive,
                                     decode: { $0 }, call: {
            await cleanup.structured(system: Self.titleSystemPrompt,
                                     user: String(markdown.prefix(2000)),
                                     maxTokens: 200, temperature: 0.3)
        }) {
            // ported: generateTitle.ts — trim, then strip one leading and one
            // trailing quote of either kind (their /^["']|["']$/g).
            title = Self.stripWrappingQuotes(reply.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if title.isEmpty || title.count >= 100 {
            let f = DateFormatter()
            f.dateStyle = .medium
            title = "Meeting — \(f.string(from: Date()))"
        }
        completed += 1
        progress(completed, total)

        Log.info("MeetingNotesGenerator: notes done — \(markdown.count) chars, " +
                 "\(completed)/\(total) calls")
        return Result(markdown: markdown, title: title)
    }

    // MARK: - Call plumbing

    /// One model call with the dictation gate and the single retry. `decode`
    /// turns the raw reply into the caller's shape; a decode failure counts
    /// as a failed call (a truncated grammar reply is broken JSON, and
    /// retrying is what fixes it).
    private func attempt<T>(label: String,
                            dictationActive: () -> Bool,
                            decode: (String) -> T?,
                            call: () async -> String?) async -> T? {
        for attemptNumber in 1...2 {
            // Pause while the user dictates — the shared llama-server is the
            // dictation cleanup's too, and notes are the background job.
            while dictationActive() {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            if let reply = await call(), let value = decode(reply) { return value }
            Log.error("MeetingNotesGenerator: \(label) call failed (attempt \(attemptNumber)/2)")
        }
        return nil
    }

    private nonisolated static func stripWrappingQuotes(_ text: String) -> String {
        var t = text
        if let first = t.first, first == "\"" || first == "'" { t.removeFirst() }
        if let last = t.last, last == "\"" || last == "'" { t.removeLast() }
        return t
    }

    private nonisolated static func hasContent(_ s: Sections) -> Bool {
        !s.discussion.isEmpty || !s.decisions.isEmpty
            || !s.actions.isEmpty || !s.followups.isEmpty
    }

    /// The polish pass's user message: labeled draft lists, empty sections
    /// omitted. Its char count is also the go/no-go budget test.
    private nonisolated static func polishPayload(_ s: Sections) -> String {
        var parts: [String] = []
        if !s.discussion.isEmpty {
            parts.append("DISCUSSION POINTS:\n" + s.discussion.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !s.decisions.isEmpty {
            parts.append("DECISIONS:\n" + s.decisions.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !s.actions.isEmpty {
            parts.append("ACTION ITEMS:\n" + s.actions.map { "- \($0.owner): \($0.text)" }
                .joined(separator: "\n"))
        }
        if !s.followups.isEmpty {
            parts.append("FOLLOW-UPS:\n" + s.followups.map { "- \($0)" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }
}
