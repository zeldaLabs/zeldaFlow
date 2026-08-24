import SwiftUI

/// The floating pill: waveform while recording, pulsing dots while
/// processing, checkmark on success, short message on notice.
// @State is unavailable on this beta CLT — tiny models instead.
private final class HoverModel: ObservableObject {
    @Published var hovering = false
}

private final class TypeBarModel: ObservableObject {
    @Published var text = ""
}

struct PillView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var meetings = MeetingCenter.shared
    @StateObject private var hover = HoverModel()
    @StateObject private var typeBar = TypeBarModel()
    @StateObject private var chatComposer = TypeBarModel()

    var body: some View {
        Group {
            if case .idle = state.phase {
                // Meeting surfaces take the idle slot: banner first (transient,
                // most informative), then the ambient recording chip. The
                // dictation pill always outranks both when a session is live.
                // Both meeting surfaces are content-only (MeetingPillChip.swift)
                // — the capsule they sit on is drawn here, like every other
                // pill phase. Without it the chip is white-on-nothing and
                // disappears on a light desktop.
                if meetings.banner != nil {
                    MeetingBannerView()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(glassCapsule)
                } else if meetingActive {
                    MeetingChipView()
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(glassCapsule)
                } else if settings.showIdlePill {
                    miniPill
                }
            } else if case .typing = state.phase {
                typeBarView
            } else if case .chat = state.phase {
                chatNoteView
            } else {
                // The capsule morphs with the outer spring; the content inside
                // cross-fades per phase instead of swapping in one frame.
                ZStack {
                    content
                        .id(phaseKey)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.88)).combined(with: .offset(y: 5)),
                            removal: .opacity.combined(with: .scale(scale: 0.96))))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(glassCapsule)
                // Persistent consent cue: dictating mid-meeting must never
                // hide that the meeting is still being recorded (ADR 0027).
                .overlay(alignment: .leading) {
                    if meetingActive {
                        Circle()
                            .fill(Color(red: 0.77, green: 0.71, blue: 0.99))
                            .frame(width: 7, height: 7)
                            .padding(.leading, 9)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: state.phase)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: meetings.banner)
    }

    private var meetingActive: Bool {
        if case .idle = meetings.uiPhase { return false }
        return true
    }

    /// The pill's black-glass surface, shared by every phase that shows one.
    private var glassCapsule: some View {
        Capsule(style: .continuous)
            .fill(.black.opacity(0.82))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
    }

    /// One identity per visual phase, so SwiftUI runs an insert/remove
    /// transition on phase changes (distinct notices share one identity —
    /// their text just updates).
    private var phaseKey: String {
        switch state.phase {
        case .idle: return "idle"
        case .typing: return "typing"
        case .recording: return "recording"
        case .processing: return "processing"
        case .confirming: return "confirming"
        case .success: return "success"
        case .notice: return "notice"
        case .answer: return "answer"
        case .chat: return "chat"
        }
    }

    /// Wispr-style always-on miniature: a slim nub that grows its waveform
    /// on hover and opens the type-anything bar on click. One capsule that
    /// morphs with a spring — never a sudden view swap.
    private var miniPill: some View {
        ZStack {
            if hover.hovering {
                HStack(spacing: 2.5) {
                    ForEach(0..<9, id: \.self) { i in
                        Capsule()
                            .fill(.white.opacity(0.9))
                            .frame(width: 2.5, height: [6, 10, 15, 9, 17, 9, 14, 10, 6][i])
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.5)))
            }
        }
        .frame(width: hover.hovering ? 118 : 46, height: hover.hovering ? 28 : 9)
        .background(
            Capsule(style: .continuous)
                .fill(.black.opacity(hover.hovering ? 0.75 : 0.45))
                .overlay(Capsule(style: .continuous)
                    .strokeBorder(.white.opacity(hover.hovering ? 0.22 : 0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.32), radius: hover.hovering ? 8 : 5, y: 2)
        )
        .contentShape(Capsule(style: .continuous))
        .onHover { hover.hovering = $0 }
        .onTapGesture { state.openTypeBar() }
        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: hover.hovering)
        .padding(.bottom, 2)
    }

    /// Click-to-type: Spotlight-style bar feeding the same command pipeline
    /// as voice. Return runs it, Esc dismisses.
    private var typeBarView: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Zelda.primary)
            AppKitTextField(placeholder: "Ask zeldaFlow anything…",
                            text: typeBar.text,
                            onChange: { typeBar.text = $0 },
                            onSubmit: {
                                let text = typeBar.text
                                typeBar.text = ""
                                state.submitTypedCommand(text)
                            },
                            onEscape: {
                                typeBar.text = ""
                                state.closeTypeBar()
                            },
                            darkStyle: true, autofocus: true)
                .frame(width: 360)
            Text("esc")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4)
                    .stroke(.white.opacity(0.25), lineWidth: 1))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(
            Capsule(style: .continuous)
                .fill(.black.opacity(0.85))
                .overlay(Capsule(style: .continuous)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
        )
    }

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .recording(let mode):
            VStack(spacing: 7) {
                HStack(spacing: 8) {
                    switch mode {
                    case .handsFree:
                        Image(systemName: "infinity")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.orange)
                    case .command:
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.purple)
                    case .pushToTalk:
                        EmptyView()
                    }
                    Waveform(levels: state.levels)
                        .frame(height: 20)
                }
                // Streaming preview: latest words while you're still talking.
                if !state.liveTranscript.isEmpty {
                    Text(state.liveTranscript)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(2)
                        .truncationMode(.head)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                        .animation(.easeOut(duration: 0.15), value: state.liveTranscript)
                }
            }
        case .processing:
            ProcessingDots()
        case .confirming(let label):
            HStack(spacing: 8) {
                ConfirmBadge()
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
        case .success:
            SuccessCheck()
        case .notice(let message):
            Text(inlineStyled(message))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(4)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 470)
        case .answer(let message):
            // Looks exactly like a notice; the only difference is the click,
            // which grows the pill into the chat note.
            Text(inlineStyled(message))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(4)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 470)
                .contentShape(Rectangle())
                .onTapGesture { state.expandChat() }
        case .idle, .typing, .chat:
            EmptyView()   // all handled directly in body
        }
    }

    /// The pill grown into a rectangular note: the thread so far, thinking
    /// dots while a follow-up is in flight, and a composer that feeds
    /// AppState.submitChatMessage. Esc or clicking anywhere else closes it.
    private var chatNoteView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Zelda.primary)
                Text("zeldaFlow")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text("esc")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4)
                        .stroke(.white.opacity(0.25), lineWidth: 1))
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(state.chatMessages) { message in
                            ChatBubble(message: message)
                        }
                        if state.chatBusy {
                            ProcessingDots()
                                .padding(.vertical, 2)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: state.chatMessages.count) { _, _ in
                    if let last = state.chatMessages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Rectangle()
                .fill(.white.opacity(0.1))
                .frame(height: 1)
            AppKitTextField(placeholder: "Ask a follow-up…",
                            text: chatComposer.text,
                            onChange: { chatComposer.text = $0 },
                            onSubmit: {
                                let text = chatComposer.text
                                chatComposer.text = ""
                                state.submitChatMessage(text)
                            },
                            onEscape: {
                                chatComposer.text = ""
                                state.closeChat()
                            },
                            darkStyle: true, autofocus: true)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
        }
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.black.opacity(0.85))
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        )
        .padding(12)   // breathing room so the shadow isn't clipped by the panel
    }
}

/// Inline markdown (bold/italic/code) for pill messages: models style even
/// short answers, and raw ** markers read as noise. Block markdown belongs
/// to the chat note's full renderer, not the one-glance pill.
private func inlineStyled(_ message: String) -> AttributedString {
    (try? AttributedString(
        markdown: message,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(message)
}

/// Width one chat turn renders at: the note's 640 (PillController.layout row)
/// minus its 12pt outer padding and the thread's 18pt horizontal padding.
private let chatTurnWidth: CGFloat = 640 - 2 * 12 - 2 * 18

/// One thread turn: the user's messages sit right in a subtle bubble; the
/// assistant's render as real markdown — headings, bold, bullets — through
/// the same MarkdownRenderer the meeting notes use.
private struct ChatBubble: View {
    let message: AppState.ChatMessage

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(.white.opacity(0.14)))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            let rendered = Self.rendered(message.text)
            MarkdownTurnView(text: rendered)
                .frame(width: chatTurnWidth,
                       height: Self.height(of: rendered, width: chatTurnWidth),
                       alignment: .topLeading)
        }
    }

    /// Themed render, minus the renderer's trailing newline — it would
    /// otherwise bill every turn for one empty line of height.
    private static func rendered(_ text: String) -> NSAttributedString {
        var out = MarkdownRenderer.render(
            text.trimmingCharacters(in: .whitespacesAndNewlines),
            ink: NSColor(white: 1, alpha: 0.92),
            muted: NSColor(white: 1, alpha: 0.6))
        while out.string.hasSuffix("\n") {
            out = out.attributedSubstring(from: NSRange(location: 0, length: out.length - 1))
        }
        return out
    }

    private static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(text.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }
}

/// Hosts one rendered turn. SwiftUI's Text ignores AppKit attributes and
/// AttributedTextView is an NSScrollView (a scroll inside the thread's
/// scroll is wrong) — so this is a bare NSTextView that the ChatBubble
/// sizes explicitly from the measured text height.
private struct MarkdownTurnView: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSTextView {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        return tv
    }

    func updateNSView(_ tv: NSTextView, context: Context) {
        tv.textStorage?.setAttributedString(text)
    }
}

private struct Waveform: View {
    let levels: [Float]
    private let barCount = 26

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<barCount, id: \.self) { i in
                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(width: 3, height: barHeight(i))
            }
        }
        .animation(.linear(duration: 0.08), value: levels)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let pad = barCount - levels.count
        guard index >= pad else { return 3 }
        let level = CGFloat(levels[index - pad])
        return max(3, min(20, 3 + level * 17))
    }
}

private struct ProcessingDots: View {
    // NOTE: @State is unusable on this beta CLT (missing SwiftUIMacros
    // plugin), so drive the pulse from a TimelineView clock instead.
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = sin((t * 4) - Double(i) * 0.9)
                    Circle()
                        .fill(.white.opacity(0.9))
                        .frame(width: 6, height: 6)
                        .scaleEffect(0.72 + 0.28 * phase)
                }
            }
        }
    }
}

/// Creation-time anchor for draw-on effects (@State replacement).
private final class BornAt: ObservableObject {
    let date = Date()
}

/// Checkmark that draws itself on over ~0.35 s with a soft ring behind it.
private struct SuccessCheck: View {
    @StateObject private var born = BornAt()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
            let t = context.date.timeIntervalSince(born.date)
            let p = min(1, max(0, t / 0.35))
            let eased = 1 - pow(1 - p, 3)
            ZStack {
                Circle()
                    .fill(.green.opacity(0.22))
                    .frame(width: 24, height: 24)
                    .scaleEffect(0.5 + 0.5 * eased)
                CheckPath(progress: eased)
                    .stroke(.green, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                    .frame(width: 13, height: 11)
            }
        }
    }
}

private struct CheckPath: Shape {
    let progress: Double
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: rect.height * 0.55))
        p.addLine(to: CGPoint(x: rect.width * 0.36, y: rect.height))
        p.addLine(to: CGPoint(x: rect.width, y: 0))
        return p.trimmedPath(from: 0, to: CGFloat(progress))
    }
}

/// The armed-gate shield breathes gently so a waiting confirmation never
/// reads as a frozen pill.
private struct ConfirmBadge: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.yellow)
                .scaleEffect(1 + 0.07 * sin(t * 2 * .pi / 1.2))
        }
    }
}
