import SwiftUI

/// The meeting notetaker's presence on the pill surface (ADR 0027): the
/// ambient recording chip and the started/finished/mic-only banners. PillView
/// switches these in; the panel supplies the capsule and the size (232×44
/// chip, 420×56 banner) — these views only shape the content, in the pill's
/// black-glass idiom: white text on .black.opacity(0.82), hairline stroke.

// @State is unavailable on this beta CLT (missing SwiftUIMacros plugin) —
// tiny ObservableObject models instead, PillView's pattern.
private final class HoverModel: ObservableObject {
    @Published var hovering = false
}

/// Zelda.primary (#6D28D9) is tuned for paper surfaces and sinks into the
/// capsule's 82 % black; this is the dark-appearance lavender lifted a step
/// so a 7 pt dot and 3 pt bars still read on black glass.
private let glassViolet = Color(red: 0.77, green: 0.71, blue: 0.99)

// MARK: - Recording chip (content for 232×44)

/// The ambient chip: proof-of-recording at a glance — pulse, elapsed clock,
/// live mic level — plus the one control that must never be more than a
/// click away: Stop. Tapping anywhere else opens the meeting in the Hub.
struct MeetingChipView: View {
    @ObservedObject private var center = MeetingCenter.shared

    var body: some View {
        switch center.uiPhase {
        case .recording(let started, let micHealthy):
            HStack(spacing: 8) {
                PulseDot(color: glassViolet)
                ElapsedClock(started: started)
                ChipLevelBars(level: center.micLevel, healthy: micHealthy)
                Spacer(minLength: 6)
                // Stop is here; Discard deliberately is NOT. A destructive
                // one-click on an ambient surface invites accidents — Discard
                // lives in the menu bar, the finished banner, and the meeting
                // detail, where the click is deliberate.
                ChipStopButton()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                MainWindowController.shared.showMeetings(meeting: center.liveSession?.id)
            }
        case .processing(let step):
            statusRow(step)
        case .starting:
            // Sub-second phase, but the panel already shows the capsule — a
            // blank flash reads as a glitch, so name the moment.
            statusRow("Starting…")
        case .idle:
            EmptyView()
        }
    }

    private func statusRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            PulseDot(color: glassViolet)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // liveSession is already nil while processing — this lands on the
            // Meetings list, where the finishing meeting appears on top.
            MainWindowController.shared.showMeetings(meeting: center.liveSession?.id)
        }
    }
}

/// Recording indicator that breathes (~1.6 s cycle) — a static dot could be
/// a stale frame; motion is the proof the chip is live.
private struct PulseDot: View {
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = 0.5 + 0.5 * sin(t * 2 * .pi / 1.6)
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .opacity(0.55 + 0.45 * pulse)
                .scaleEffect(0.88 + 0.16 * pulse)
        }
    }
}

/// mm:ss since the meeting started. The periodic schedule is anchored to the
/// start date so the digit roll lands exactly on each elapsed-second boundary.
private struct ElapsedClock: View {
    let started: Date

    var body: some View {
        TimelineView(.periodic(from: started, by: 1)) { context in
            let s = max(0, Int(context.date.timeIntervalSince(started)))
            Text(String(format: "%02d:%02d", s / 60, s % 60))
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
        }
    }
}

/// Four bars driven by the live mic level. The mapping is ported verbatim
/// from OpenWhispr's MeetingRecordingPill.tsx so both apps' chips move the
/// same way: a fixed per-bar phase (the *level* is the motion, not a clock)
/// and a sqrt curve that keeps quiet rooms visibly alive above a 12.5 % floor.
private struct ChipLevelBars: View {
    let level: Float
    /// false while dictation holds the mic stream or the mic is reconnecting
    /// — amber is the chip's honesty channel: "not hearing you right now".
    let healthy: Bool
    private let track: CGFloat = 16

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<4, id: \.self) { i in
                let phase = 0.7 + 0.3 * sin(Double(i) * 1.7)
                let fraction = min(max(sqrt(Double(level)) * 1.8 * phase, 0.125), 1.0)
                Capsule()
                    .fill(healthy ? glassViolet : Color.orange)
                    .frame(width: 3, height: track * CGFloat(fraction))
            }
        }
        .frame(height: track)
        .animation(.linear(duration: 0.08), value: level)
    }
}

private struct ChipStopButton: View {
    @StateObject private var hover = HoverModel()

    var body: some View {
        Button {
            MeetingCenter.shared.stopManually()
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(glassViolet.opacity(hover.hovering ? 0.45 : 0.28)))
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hover.hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hover.hovering)
        .help("Stop and save this meeting")
    }
}

// MARK: - Banner (content for 420×56)

/// Started / finished / mic-only banner. Started exists for consent
/// visibility — the user must always know a recording began; finished is the
/// save receipt, shown in the short window when Open and Discard are most
/// wanted; mic-only is the honest downgrade when the system-audio tap failed.
struct MeetingBannerView: View {
    @ObservedObject private var center = MeetingCenter.shared

    var body: some View {
        if let banner = center.banner {
            switch banner {
            case .started(let app): started(app: app)
            case .finished(let title): finished(title: title)
            case .micOnly: micOnly
            }
        }
    }

    private func started(app: String) -> some View {
        HStack(spacing: 10) {
            PulseDot(color: glassViolet)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Recording this meeting")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white)
                    if !app.isEmpty {
                        Text(app)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule(style: .continuous).fill(.white.opacity(0.12)))
                    }
                }
                caption("Notes will be ready when you hang up · manage in Meetings")
            }
            Spacer(minLength: 8)
            GhostButton(label: "Stop") { MeetingCenter.shared.stopManually() }
            BannerDismissButton()   // hides the banner only — recording continues
        }
    }

    private func finished(title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                caption("Writing notes… they'll be in Meetings")
            }
            Spacer(minLength: 8)
            GhostButton(label: "Open") {
                MainWindowController.shared.showMeetings(meeting: nil)
                MeetingCenter.shared.dismissBanner()
            }
            // One-click Discard with no confirmation — on purpose. This is
            // the moment the discard promise matters most ("that was nothing,
            // delete it"). By banner time the meeting has already stopped and
            // saved, so discarding means deleting the record this banner
            // announces — which, newest-first, is records.first.
            GhostButton(label: "Discard", tint: Color(red: 1.0, green: 0.62, blue: 0.6)) {
                if let newest = MeetingStore.shared.records.first {
                    MeetingStore.shared.delete(newest.id)
                }
                MeetingCenter.shared.dismissBanner()
            }
        }
    }

    private var micOnly: some View {
        HStack(spacing: 10) {
            PulseDot(color: .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recording your side only")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white)
                caption("Enable system audio to hear the other side")
            }
            Spacer(minLength: 8)
            GhostButton(label: "Settings") { Permissions.openSystemAudioPane() }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(1)
    }
}

/// Text-only capsule button on glass: hairline stroke, brightens on hover.
private struct GhostButton: View {
    let label: String
    var tint: Color = .white
    let action: () -> Void
    @StateObject private var hover = HoverModel()

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint.opacity(hover.hovering ? 1 : 0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(.white.opacity(hover.hovering ? 0.10 : 0))
                        .overlay(Capsule(style: .continuous)
                            .strokeBorder(tint.opacity(hover.hovering ? 0.5 : 0.28),
                                          lineWidth: 1)))
        }
        .buttonStyle(.plain)
        .contentShape(Capsule(style: .continuous))
        .onHover { hover.hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hover.hovering)
    }
}

/// ✕ on the started banner: hides the notice, nothing else. Dismissing a
/// consent notice must never be the thing that silently stops the capture.
private struct BannerDismissButton: View {
    @StateObject private var hover = HoverModel()

    var body: some View {
        Button {
            MeetingCenter.shared.dismissBanner()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.white.opacity(hover.hovering ? 0.95 : 0.5))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hover.hovering)
        .help("Hide — recording continues")
    }
}
