import AppKit
import SwiftUI

// The animated first-launch experience: a night-sky arrival, the name
// "composer" field with a conic-gradient border, permission cards, and a
// finale. All continuous motion is a pure function of time inside one
// TimelineView (this toolchain's @State is broken); staged reveals live in
// an ObservableObject advanced by timers.

// MARK: - Palette

private extension Color {
    init(hex: UInt32, _ alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

/// Ink on paper. The brand film draws a black mark onto a white ground, so
/// the first run does the same — the old night-sky treatment fought the logo.
/// Token names are kept from that era so every call site follows the flip:
/// `inkHi` is simply the strongest ink now, and `night*` is the paper stack.
private enum Pal {
    // zeldaLabs violet — an accent for interactive moments only. The mark
    // itself is never tinted.
    static let brandDeep = Color(hex: 0x4C1D95)
    static let brandCore = Color(hex: 0x6D28D9)
    static let brandSoft = Color(hex: 0x7C3AED)
    static let brandPale = Color(hex: 0xA78BFA)
    // Ink
    static let inkHi = Color(hex: 0x15130F)
    static let inkMid = Color(hex: 0x4B463D)
    static let inkLow = Color(hex: 0x8D8579)
    // Paper
    static let nightTop = Color(hex: 0xFDFCFA)
    static let nightMid = Color(hex: 0xF8F6F2)
    static let nightBase = Color(hex: 0xF1EEE8)
    static let indigo = Color(hex: 0x4F46E5)
    static let cyan = Color(hex: 0x0E7490)
    static let magenta = Color(hex: 0xA21CAF)
    static let success = Color(hex: 0x15803D)
}

// MARK: - Easing (MD3 emphasized, as a pure time ramp)

private struct UnitBezier {
    let ax, bx, cx, ay, by, cy: Double
    init(_ p1x: Double, _ p1y: Double, _ p2x: Double, _ p2y: Double) {
        cx = 3 * p1x; bx = 3 * (p2x - p1x) - cx; ax = 1 - cx - bx
        cy = 3 * p1y; by = 3 * (p2y - p1y) - cy; ay = 1 - cy - by
    }
    private func sampleX(_ t: Double) -> Double { ((ax * t + bx) * t + cx) * t }
    private func sampleY(_ t: Double) -> Double { ((ay * t + by) * t + cy) * t }
    func solve(_ x: Double) -> Double {
        var t = x
        for _ in 0..<6 {
            let d = 3 * ax * t * t + 2 * bx * t + cx
            guard abs(d) > 1e-6 else { break }
            t -= (sampleX(t) - x) / d
        }
        return sampleY(min(max(t, 0), 1))
    }
}

private let emphasized = UnitBezier(0.2, 0, 0, 1)

/// 0→1 progress along the emphasized curve for a beat starting at `start`.
private func ramp(_ elapsed: Double, start: Double, dur: Double) -> Double {
    emphasized.solve(min(max((elapsed - start) / dur, 0), 1))
}

private func emph(_ d: Double) -> Animation { .timingCurve(0.2, 0, 0, 1, duration: d) }

// MARK: - Model

final class OnboardingModel: ObservableObject {
    enum Stage: Int { case arrival, name, permissions, warmup, finale }

    @Published var stage: Stage = .arrival
    @Published var stageEnteredAt = Date()
    @Published var revealStep = 0
    @Published var name = AppSettings.shared.userName
    @Published var micGranted = Permissions.micGranted
    @Published var axGranted = Permissions.accessibilityTrusted
    @Published var micGrantedAt: Date?
    @Published var axGrantedAt: Date?
    @Published var statusWordIndex = 0

    private var timerGeneration = 0

    func advance(to next: Stage) {
        timerGeneration += 1
        stageEnteredAt = Date()
        withAnimation(emph(0.55)) {
            stage = next
            revealStep = 0
        }
        scheduleReveals()
        if next == .warmup { cycleStatusWords() }
    }

    func after(_ delay: TimeInterval, _ block: @escaping () -> Void) {
        let gen = timerGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.timerGeneration == gen else { return }
            block()
        }
    }

    private func scheduleReveals() {
        for step in 1...4 {
            after(0.10 + Double(step - 1) * 0.14) {
                withAnimation(emph(0.45)) { self.revealStep = step }
            }
        }
    }

    private func cycleStatusWords() {
        after(0.72) {
            withAnimation(.easeOut(duration: 0.32)) { self.statusWordIndex += 1 }
            self.cycleStatusWords()
        }
    }
}

// MARK: - Root

struct OnboardingCinematicView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var model = OnboardingModel()

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private static let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: Self.reduceMotion ? 10 : 1.0 / 60.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            // Reduce Motion samples every 10 s, which would hold every
            // elapsed-driven fade at its start (opacity 0) — show everything
            // settled instead of animating it in.
            let elapsed = Self.reduceMotion
                ? 1000 : timeline.date.timeIntervalSince(model.stageEnteredAt)
            ZStack {
                Ambient(t: Self.reduceMotion ? 0 : t)

                Group {
                    switch model.stage {
                    case .arrival: ArrivalScene(t: t, elapsed: elapsed, model: model)
                    case .name: NameScene(t: t, model: model, onContinue: continueFromName)
                    case .permissions: PermissionsScene(t: t, model: model, state: state)
                    case .warmup: WarmupScene(t: t, model: model, problem: state.setupProblem)
                    case .finale: FinaleScene(t: t, onStart: finish)
                    }
                }
                .frame(width: 440)
                .transition(.opacity.combined(with: .offset(y: -14)))

                // Escape hatch, always available.
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button("skip") { finish() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(Pal.inkLow.opacity(0.7))
                            .padding(14)
                    }
                }

                // The maker's mark, quietly present through every scene.
                VStack {
                    Spacer()
                    BrandMark()
                        .padding(.bottom, 15)
                }
            }
        }
        .frame(width: 520, height: 640)
        .background(Pal.nightTop)
        .onAppear {
            model.stageEnteredAt = Date()
            model.after(Self.reduceMotion ? 1.2 : 6.3) {
                if model.stage == .arrival { model.advance(to: .name) }
            }
        }
        .onReceive(poll) { _ in
            let mic = Permissions.micGranted
            let ax = Permissions.accessibilityTrusted
            if mic, !model.micGranted { grantPop { model.micGranted = true; model.micGrantedAt = Date() } }
            if ax, !model.axGranted {
                grantPop { model.axGranted = true; model.axGrantedAt = Date() }
                state.installHotkeyIfPossible()
            }
            if model.stage == .permissions, model.micGranted, model.axGranted {
                model.after(0.8) {
                    guard model.stage == .permissions else { return }
                    model.advance(to: state.whisperReady ? .finale : .warmup)
                }
            }
            if model.stage == .warmup, state.whisperReady {
                model.advance(to: .finale)
            }
        }
    }

    private func grantPop(_ change: @escaping () -> Void) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.62)) { change() }
    }

    private func continueFromName() {
        model.advance(to: .permissions)
    }

    private func finish() {
        let name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            state.settings.userName = name
            let first = String(name.split(separator: " ").first ?? "")
            for word in [name, first] where word.count >= 3 && !state.settings.dictionaryWords.contains(word) {
                state.settings.dictionaryWords.append(word)
            }
        }
        state.settings.onboardingCompleted = true
        state.installHotkeyIfPossible()
        OnboardingWindowController.shared.close()
    }
}

// MARK: - zeldaLabs wordmark

/// Text-only wordmark (canonical casing: one word, lowercase z) — the brief
/// is explicit that no logo exists, so none is invented.
private struct BrandMark: View {
    var body: some View {
        (Text("zelda").foregroundColor(Pal.inkLow)
            + Text("Labs").foregroundColor(Pal.brandSoft))
            .font(.system(size: 12, weight: .medium, design: .serif))
            .kerning(0.8)
            .opacity(0.85)
    }
}

// MARK: - Ambient paper ground

/// Warm paper with a faint field of the brand's own waves drifting beneath —
/// enough texture that the ground doesn't read as flat white, never enough to
/// compete with the mark.
private struct Ambient: View {
    let t: Double

    var body: some View {
        ZStack {
            LinearGradient(colors: [Pal.nightTop, Pal.nightMid, Pal.nightBase],
                           startPoint: .top, endPoint: .bottom)

            // Two barely-there violet washes; on paper these warm the corners
            // instead of glowing (a .screen blend would vanish here).
            Ellipse()
                .fill(Pal.brandPale.opacity(0.15))
                .frame(width: 340, height: 400)
                .blur(radius: 80)
                .offset(x: -150 + 20 * sin(t * 2 * .pi / 46), y: -230)
            Ellipse()
                .fill(Pal.indigo.opacity(0.08))
                .frame(width: 320, height: 380)
                .blur(radius: 80)
                .offset(x: 165 - 18 * sin(t * 2 * .pi / 56), y: 250)

            Canvas { ctx, size in
                for i in 0..<7 {
                    let baseY = size.height * (0.15 + 0.115 * Double(i))
                    let drift = t * 0.10 + Double(i) * 0.7
                    var path = Path()
                    let steps = 64
                    for s in 0...steps {
                        let f = Double(s) / Double(steps)
                        let y = baseY + 15 * sin(f * 2.1 * 2 * .pi + drift)
                        let pt = CGPoint(x: size.width * f, y: y)
                        if s == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                    }
                    ctx.stroke(path, with: .color(Pal.inkHi.opacity(0.05)),
                               style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
                }
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Logo mark (the wave, drawn live)

/// The real mark, flowing. `reveal` drives a draw-on so the first thing the
/// user sees is the logo being written — the brand film's opening move.
private struct LogoMark: View {
    let t: Double
    var size: CGFloat = 168
    var reveal: Double = 1

    var body: some View {
        WaveMark(t: t, size: size, ink: Pal.inkHi, progress: reveal)
    }
}

// MARK: - Scene 0: Arrival

private struct ArrivalScene: View {
    let t: Double
    let elapsed: Double
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 22) {
            // The mark writes itself on, left to right, then keeps flowing.
            LogoMark(t: t, reveal: ramp(elapsed, start: 0.45, dur: 1.6))
                .opacity(ramp(elapsed, start: 0.35, dur: 0.5))

            // The wordmark follows the same stroke direction rather than
            // fading — it should feel written, not switched on.
            Text("zeldaFlow")
                .font(.system(size: 36, weight: .regular))
                .kerning(0.5)
                .foregroundStyle(Pal.inkHi)
                .mask(Wipe(progress: ramp(elapsed, start: 1.7, dur: 0.85)))

            VStack(spacing: 6) {
                (Text("speak, and it's ").foregroundColor(Pal.inkMid)
                    + Text("written").italic().foregroundColor(Pal.brandSoft))
                    .font(.system(size: 19, design: .serif))
                InkUnderline(progress: ramp(elapsed, start: 2.9, dur: 0.8))
                    .frame(width: 86, height: 6)
            }
            .opacity(ramp(elapsed, start: 2.3, dur: 0.7))
            .offset(y: 14 * (1 - ramp(elapsed, start: 2.3, dur: 0.7)))

            Text("local · private · yours")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Pal.inkLow)
                .padding(.top, 8)
                .opacity(ramp(elapsed, start: 3.2, dur: 0.4))
        }
        .contentShape(Rectangle())
        .onTapGesture { model.advance(to: .name) }
    }
}

/// Left-to-right reveal with a soft leading edge, so text appears to be
/// written rather than faded in.
private struct Wipe: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let edge = min(0.18, max(0.001, progress))
            LinearGradient(
                stops: [.init(color: .white, location: 0),
                        .init(color: .white, location: max(0, progress - edge)),
                        .init(color: .clear, location: min(1, progress))],
                startPoint: .leading, endPoint: .trailing)
                .frame(width: w)
        }
    }
}

private struct InkUnderline: View {
    let progress: Double
    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: 4))
            p.addCurve(to: CGPoint(x: 30, y: 3),
                       control1: CGPoint(x: 10, y: 0), control2: CGPoint(x: 20, y: 6))
            p.addCurve(to: CGPoint(x: 60, y: 4),
                       control1: CGPoint(x: 40, y: 0), control2: CGPoint(x: 50, y: 6))
            p.addCurve(to: CGPoint(x: 86, y: 3),
                       control1: CGPoint(x: 70, y: 1), control2: CGPoint(x: 80, y: 5))
        }
        .trim(from: 0, to: progress)
        .stroke(Pal.brandCore.opacity(0.5),
                style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
    }
}

// MARK: - Scene 1: Name (composer field)

private struct NameScene: View {
    let t: Double
    @ObservedObject var model: OnboardingModel
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 26) {
            if model.revealStep >= 1 {
                (Text("what should zeldaFlow call ").foregroundColor(Pal.inkHi)
                    + Text("you").italic().foregroundColor(Pal.brandSoft)
                    + Text("?").foregroundColor(Pal.inkHi))
                    .font(.system(size: 26, design: .serif))
                    .transition(.opacity.combined(with: .offset(y: 14)))
            }

            if model.revealStep >= 2 {
                ZStack {
                    // A paper field, not the old dark slab. The border keeps a
                    // slow shimmer for life, but within the violet family —
                    // the previous rainbow conic fought the ink identity.
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.white)
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(AngularGradient(stops: [
                            .init(color: Pal.brandPale, location: 0.00),
                            .init(color: Pal.brandCore, location: 0.30),
                            .init(color: Pal.brandPale, location: 0.55),
                            .init(color: Pal.brandSoft, location: 0.80),
                            .init(color: Pal.brandPale, location: 1.00),
                        ], center: .center,
                           angle: .degrees(t.truncatingRemainder(dividingBy: 9) / 9 * 360)),
                        lineWidth: 1.5)
                    AppKitTextField(placeholder: "your name",
                                    text: model.name,
                                    onChange: { model.name = $0 },
                                    onSubmit: onContinue,
                                    paperStyle: true, autofocus: true)
                        .frame(width: 300)
                }
                .frame(width: 340, height: 54)
                .shadow(color: Pal.brandCore.opacity(0.10), radius: 10, y: 3)
                .transition(.opacity.combined(with: .offset(y: 14)))
            }

            if model.revealStep >= 3 {
                ZStack {
                    if !model.name.isEmpty {
                        let p = emphasized.solve(t.truncatingRemainder(dividingBy: 2.4) / 2.4)
                        Capsule()
                            .stroke(Pal.brandCore.opacity(0.20 * (1 - p)), lineWidth: 3 * (1 - p))
                            .frame(width: 158, height: 40)
                            .scaleEffect(1 + 0.14 * p)
                    }
                    Button(action: onContinue) {
                        Text("continue")
                            // White on violet: `inkHi` is near-black now, so
                            // the old pairing was unreadable on paper.
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 34)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(Pal.brandCore))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }
                .frame(height: 44)
                // Dimmed to read as "not yet", but not so far that the label
                // greys out into the paper.
                .opacity(model.name.isEmpty ? 0.62 : 1)
                .transition(.opacity.combined(with: .offset(y: 14)))
            }
        }
    }
}

// MARK: - Scene 2: Permissions

private struct PermissionsScene: View {
    let t: Double
    @ObservedObject var model: OnboardingModel
    let state: AppState

    var body: some View {
        VStack(spacing: 18) {
            if model.revealStep >= 1 {
                VStack(spacing: 6) {
                    Text("zeldaFlow needs two keys")
                        .font(.system(size: 22, design: .serif))
                        .foregroundStyle(Pal.inkHi)
                    Text("both stay between you and this Mac")
                        .font(.system(size: 13))
                        .foregroundStyle(Pal.inkLow)
                }
                .transition(.opacity.combined(with: .offset(y: 14)))
            }

            if model.revealStep >= 2 {
                PermissionCard(
                    t: t, granted: model.micGranted, grantedAt: model.micGrantedAt,
                    title: "microphone", caption: "so zeldaFlow can hear you",
                    icon: { MiniWave(t: t, active: model.micGranted) },
                    buttonTitle: Permissions.micDenied ? "open settings" : "grant"
                ) {
                    if Permissions.micDenied {
                        Permissions.openMicrophonePane()
                    } else {
                        Permissions.requestMic { _ in }
                    }
                }
                .transition(.opacity.combined(with: .offset(y: 14)))
            }

            if model.revealStep >= 3 {
                PermissionCard(
                    t: t, granted: model.axGranted, grantedAt: model.axGrantedAt,
                    title: "accessibility", caption: "so zeldaFlow can type where your cursor is",
                    icon: {
                        HStack(spacing: 3) {
                            Image(systemName: "keyboard.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(Pal.brandPale)
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Pal.brandSoft)
                                .frame(width: 1.5, height: 14)
                                .opacity(t.truncatingRemainder(dividingBy: 1.1) < 0.55 ? 1 : 0)
                        }
                    },
                    buttonTitle: "grant"
                ) {
                    Permissions.requestAccessibility()
                    Permissions.openAccessibilityPane()
                }
                .transition(.opacity.combined(with: .offset(y: 14)))
            }
        }
    }
}

private struct PermissionCard<Icon: View>: View {
    let t: Double
    let granted: Bool
    let grantedAt: Date?
    let title: String
    let caption: String
    @ViewBuilder let icon: () -> Icon
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        let sinceGrant = grantedAt.map { Date().timeIntervalSince($0) } ?? 99
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Pal.brandCore.opacity(0.12))
                    .frame(width: 44, height: 44)
                if granted {
                    CheckMark(progress: ramp(sinceGrant, start: 0, dur: 0.55))
                        .frame(width: 20, height: 20)
                } else {
                    icon()
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Pal.inkHi)
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(Pal.inkLow)
            }
            Spacer()
            if granted {
                Text("granted")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Pal.success)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Pal.success.opacity(0.15)))
            } else {
                Button(action: action) {
                    Text(buttonTitle)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Pal.brandCore))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: Pal.inkHi.opacity(0.06), radius: 8, y: 2)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Pal.inkLow.opacity(0.22), lineWidth: 1)
                if granted, sinceGrant < 0.7 {
                    let p = ramp(sinceGrant, start: 0, dur: 0.7)
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Pal.brandDeep.opacity(0.2 * (1 - p)), lineWidth: 6 * (1 - p) + 1)
                        .scaleEffect(1 + 0.03 * p)
                }
            }
        )
        .scaleEffect(granted && sinceGrant < 0.5 ? 1.02 : 1)
    }
}

private struct MiniWave: View {
    let t: Double
    let active: Bool
    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<7, id: \.self) { i in
                Capsule()
                    .fill(LinearGradient(colors: [Pal.brandSoft, Pal.brandSoft.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 2.5,
                           height: 4 + 14 * (0.5 + 0.5 * sin(t * 2 * .pi / 0.9 + Double(i) * 0.63)))
            }
        }
        .opacity(0.85)
    }
}

private struct CheckMark: View {
    let progress: Double
    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: 1, y: 11))
            p.addLine(to: CGPoint(x: 7, y: 17))
            p.addLine(to: CGPoint(x: 19, y: 3))
        }
        .trim(from: 0, to: progress)
        .stroke(Pal.success, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
    }
}

// MARK: - Scene 3: Warm-up (only when the model isn't ready yet)

private struct WarmupScene: View {
    let t: Double
    @ObservedObject var model: OnboardingModel
    var problem: String?
    // Honest words: nothing is downloaded here — the local model is being
    // mapped into memory and its Metal kernels compiled.
    private static let words = ["waking up", "mapping memory", "compiling shaders",
                                "warming up", "tuning", "flowing"]

    var body: some View {
        if let problem {
            // The model never becomes ready without help (e.g. a fresh clone
            // that skipped scripts/install.sh) — an endless spinner would lie.
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 26))
                    .foregroundStyle(Pal.brandSoft)
                Text("something's missing")
                    .font(.system(size: 22, design: .serif))
                    .foregroundStyle(Pal.inkHi)
                Text(problem)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Pal.inkLow)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
        } else {
            warmingUp
        }
    }

    private var warmingUp: some View {
        VStack(spacing: 26) {
            // The mark *is* the progress indicator — a sweep travels through
            // the waves instead of a generic bar sitting under them.
            WaveLoader(t: t, size: 156, ink: Pal.inkHi, accent: Pal.brandCore)
                .padding(.bottom, 4)

            (Text("warming up zeldaFlow's ").foregroundColor(Pal.inkHi)
                + Text("brain").italic().foregroundColor(Pal.brandSoft))
                .font(.system(size: 22, design: .serif))
            Text("whisper large-v3-turbo · runs fully on-device")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Pal.inkLow)

            HStack(spacing: 8) {
                Text(Self.words[model.statusWordIndex % Self.words.count])
                    .font(.system(size: 12))
                    .foregroundStyle(Pal.inkLow)
                    .id(model.statusWordIndex)
                    .transition(.opacity.combined(with: .offset(y: 4)))
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(Pal.brandSoft.opacity(0.7))
                            .frame(width: 4, height: 4)
                            .offset(y: -3 * max(0, sin(t * 2 * .pi / 0.9 + Double(i) * 0.4)))
                    }
                }
            }
        }
    }
}

// MARK: - Scene 4: Finale

private struct FinaleScene: View {
    let t: Double
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            LogoMark(t: t, size: 64)
            (Text("hold ").foregroundColor(Pal.inkHi)
                + Text("fn").foregroundColor(Pal.brandSoft)
                + Text(" and just talk").foregroundColor(Pal.inkHi))
                .font(.system(size: 24, design: .serif))
            Text("release to see your words land at the cursor.\ntriple-tap fn and zeldaFlow becomes your assistant.")
                .font(.system(size: 13))
                .foregroundStyle(Pal.inkLow)
                .multilineTextAlignment(.center)

            ZStack {
                let p = emphasized.solve(t.truncatingRemainder(dividingBy: 2.4) / 2.4)
                Capsule()
                    .stroke(Pal.brandCore.opacity(0.20 * (1 - p)), lineWidth: 3 * (1 - p))
                    .frame(width: 188, height: 44)
                    .scaleEffect(1 + 0.14 * p)
                Button(action: onStart) {
                    Text("start dictating")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 34)
                        .padding(.vertical, 11)
                        .background(Capsule().fill(Pal.brandCore))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .frame(height: 48)
            .padding(.top, 6)
        }
    }
}
