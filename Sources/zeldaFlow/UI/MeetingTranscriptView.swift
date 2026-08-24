import SwiftUI

// Two-sided chat rendering of a meeting transcript — the port of OpenWhispr's
// MeetingTranscriptChat, restyled onto the Zelda violet system. You (mic) sits
// left in primary; Them (system audio) sits right on a card. Works for both a
// live session (MeetingCenter.liveSession.segments) and a stored one.

/// View-local state. @State is unavailable on this beta CLT (missing
/// SwiftUIMacros plugin), so everything lives here behind @StateObject.
fileprivate final class TranscriptModel: ObservableObject {
    /// Windowing insurance for multi-hour meetings — flipping this prepends
    /// the hidden head of the transcript.
    @Published var windowExpanded = false

    /// Deliberately NOT @Published: onPreferenceChange writes this on every
    /// scroll tick, and a published write there would invalidate the view per
    /// frame — scroll → publish → re-layout → new preference, a render loop.
    /// Nothing needs to redraw when stickiness flips; it is only *read* the
    /// next time a segment arrives.
    var stickToBottom: Bool

    init(stickToBottom: Bool) { self.stickToBottom = stickToBottom }
}

/// Bottom edge of the transcript content in the scroll view's coordinate
/// space — the spike-validated way to observe scroll position on this
/// toolchain (no scroll-offset API to be had).
fileprivate struct BottomEdgeKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// One bubble plus its precomputed grouping flag and resolved speaker label.
/// Grouping is a pure pass up front so row bodies stay index-free —
/// LazyVStack must not reach into neighbours during layout.
struct TranscriptRow: Identifiable {
    let segment: MeetingSegment
    let isGroupStart: Bool
    /// Resolved at grouping time: "You", "Them", "Speaker N" or a rename.
    let label: String
    var id: UUID { segment.id }
}

struct MeetingTranscriptView: View {
    let segments: [MeetingSegment]
    let isLive: Bool
    /// Per-meeting renames, cluster index → display name (ADR 31).
    var speakerNames: [Int: String] = [:]
    /// Presents the rename flow for a cluster; nil hides the context menu
    /// (live view, previews).
    var onRenameSpeaker: ((Int) -> Void)?
    @StateObject private var model: TranscriptModel

    /// Above this count the view stops trusting LazyVStack alone…
    private static let windowThreshold = 3000
    /// …and shows only this many trailing segments until asked for the rest.
    private static let windowSize = 2000

    private static let scrollSpace = "meeting-transcript"

    init(segments: [MeetingSegment], isLive: Bool,
         speakerNames: [Int: String] = [:],
         onRenameSpeaker: ((Int) -> Void)? = nil) {
        self.segments = segments
        self.isLive = isLive
        self.speakerNames = speakerNames
        self.onRenameSpeaker = onRenameSpeaker
        // Live transcripts follow the tail; a finished one opens at rest and
        // only sticks after the user scrolls to the bottom themselves.
        _model = StateObject(wrappedValue: TranscriptModel(stickToBottom: isLive))
    }

    var body: some View {
        if segments.isEmpty {
            Text(isLive ? "Conversation will appear here as people speak."
                        : "No transcript was captured.")
                .font(.system(size: 12))
                .foregroundStyle(Zelda.mutedFg.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            chat
        }
    }

    private var chat: some View {
        let truncated = !model.windowExpanded && segments.count > Self.windowThreshold
        let windowed = truncated ? Array(segments.suffix(Self.windowSize)) : segments
        // Whisper now emits one span per SENTENCE with real timestamps
        // (ADR 34), which is right for storage, diarization and export — but
        // a wall of one-sentence bubbles is what "the transcript is just
        // single lines" meant. Merge a speaker's consecutive sentences back
        // into a paragraph for reading, using the exporter's rule so the
        // page and the exported file agree.
        let visible = MeetingExporter.mergeSegments(windowed)
        let rows = Self.groupRows(visible, names: speakerNames)

        // GeometryReader wraps the ScrollView only to learn the viewport
        // height — stickiness is "content bottom within 80 pt of the viewport
        // bottom", and the preference alone reports content coordinates.
        return GeometryReader { viewport in
            ScrollView {
                ScrollViewReader { proxy in
                    LazyVStack(spacing: 0) {
                        if truncated {
                            Button("Show earlier conversation") {
                                model.windowExpanded = true
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Zelda.primary)
                            .padding(.vertical, 6)
                        }

                        // No entry animations here, on purpose: a transcript
                        // holds thousands of finalized bubbles, and thousands
                        // of implicit animations is exactly the load this
                        // toolchain doesn't need. Segments are finals-only
                        // (no partials), so nothing ever mutates in place.
                        ForEach(rows) { row in
                            BubbleRow(row: row, onRenameSpeaker: onRenameSpeaker)
                                .padding(.top, row.isGroupStart ? 10 : 2)
                        }

                        Color.clear.frame(height: 1).id("bottom-anchor")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: BottomEdgeKey.self,
                                value: geo.frame(in: .named(Self.scrollSpace)).maxY
                            )
                        }
                    )
                    .onChange(of: segments.count) {
                        if model.stickToBottom {
                            proxy.scrollTo("bottom-anchor", anchor: .bottom)
                        }
                    }
                    .onAppear {
                        // A live transcript opened mid-meeting should land on
                        // the tail immediately, not wait for the next segment.
                        if isLive {
                            proxy.scrollTo("bottom-anchor", anchor: .bottom)
                        }
                    }
                }
            }
            .coordinateSpace(name: Self.scrollSpace)
            .onPreferenceChange(BottomEdgeKey.self) { maxY in
                // 80 pt of slack so a bubble landing under the cursor doesn't
                // silently disarm follow mode.
                model.stickToBottom = maxY - viewport.size.height < 80
            }
        }
    }

    /// The grouping key: a section breaks on the channel OR on the diarized
    /// speaker within the Them channel (ADR 31). `speaker` is always nil on
    /// .you, so pre-diarization transcripts group exactly as before.
    struct GroupKey: Equatable {
        let source: MeetingSegment.Source
        let speaker: Int?
    }

    /// Pure grouping pass: a row starts a group when the previous visible
    /// segment came from another (channel, speaker) pair, or there is none.
    /// Internal, not private — MeetingEvals pins this.
    static func groupRows(_ segments: [MeetingSegment],
                          names: [Int: String] = [:]) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        rows.reserveCapacity(segments.count)
        var previous: GroupKey?
        for segment in segments {
            let key = GroupKey(source: segment.source, speaker: segment.speaker)
            rows.append(TranscriptRow(segment: segment,
                                      isGroupStart: key != previous,
                                      label: segment.displayLabel(names: names)))
            previous = key
        }
        return rows
    }
}

// MARK: - Bubble

fileprivate struct BubbleRow: View {
    let row: TranscriptRow
    var onRenameSpeaker: ((Int) -> Void)?

    /// Speaker-dot palette cycled by cluster index. Bubble geometry stays
    /// channel-based (You left/primary, Them right/card) — the dot + label
    /// are the whole per-speaker treatment.
    private static let dotPalette = [Zelda.blue, Zelda.green, Zelda.amber, Zelda.tertiary]

    var body: some View {
        let isYou = row.segment.source == .you
        let shape = bubbleShape(isYou: isYou, isGroupStart: row.isGroupStart)

        HStack(spacing: 0) {
            if !isYou { Spacer(minLength: 40) }
            VStack(alignment: isYou ? .leading : .trailing, spacing: 3) {
                if row.isGroupStart {
                    speakerLabel(isYou: isYou)
                }
                // (bubble below)
                Text(row.segment.text)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .foregroundStyle(isYou ? Zelda.onPrimary : Zelda.foreground)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(shape.fill(isYou ? Zelda.primary : Zelda.card))
                    .overlay(shape.strokeBorder(isYou ? Color.clear : Zelda.border,
                                                lineWidth: 1))
                    .help(Self.timestamp(row.segment.start))
            }
            // Fixed cap instead of a per-row GeometryReader: a hard 480 keeps
            // paragraph-length segments readable at any window width without
            // paying layout feedback on thousands of rows.
            .frame(maxWidth: 480, alignment: isYou ? .leading : .trailing)
            // The rename menu hangs off the WHOLE row, not the 11 pt label —
            // right-clicking a one-line caption was a bullseye nobody hits.
            .contextMenu {
                if let key = row.segment.renameKey, let onRenameSpeaker {
                    Button(renameMenuTitle) { onRenameSpeaker(key) }
                }
            }
            if isYou { Spacer(minLength: 40) }
        }
    }

    private var renameMenuTitle: String {
        row.segment.speaker == nil ? "Name this speaker…" : "Rename \(row.label)…"
    }

    /// The speaker caption above a group. For the far side the WHOLE caption
    /// is a button with a visible pencil: the right-click menu proved
    /// unreliable on this toolchain, and an affordance you have to guess at
    /// is not an affordance.
    @ViewBuilder private func speakerLabel(isYou: Bool) -> some View {
        let caption = HStack(spacing: 4) {
            if !isYou, let cluster = row.segment.speaker {
                Circle()
                    .fill(Self.dotPalette[cluster % Self.dotPalette.count])
                    .frame(width: 6, height: 6)
            }
            Text(row.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Zelda.mutedFg)
            if row.segment.renameKey != nil, onRenameSpeaker != nil {
                Image(systemName: "pencil")
                    .font(.system(size: 9))
                    .foregroundStyle(Zelda.mutedFg.opacity(0.7))
            }
        }
        if let key = row.segment.renameKey, let onRenameSpeaker {
            Button { onRenameSpeaker(key) } label: { caption.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help("Name this speaker")
        } else {
            caption
        }
    }

    /// Base radius 10 with the speaker-side corner tightened to 4 — the
    /// tightened corner points *into* the run of bubbles: a group start
    /// tightens the bottom (continuations hang below it), a continuation
    /// tightens the top (it hangs off the bubble above).
    private func bubbleShape(isYou: Bool, isGroupStart: Bool) -> UnevenRoundedRectangle {
        let tightTop = !isGroupStart
        return UnevenRoundedRectangle(
            topLeadingRadius:     isYou && tightTop  ? 4 : 10,
            bottomLeadingRadius:  isYou && !tightTop ? 4 : 10,
            bottomTrailingRadius: !isYou && !tightTop ? 4 : 10,
            topTrailingRadius:    !isYou && tightTop  ? 4 : 10
        )
    }

    /// mm:ss from meeting start for the hover tooltip.
    private static func timestamp(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
