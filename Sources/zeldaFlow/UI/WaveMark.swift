import SwiftUI

/// The zeldaFlow mark, drawn live: three stacked double-stroke waves that
/// flow horizontally. Vector rather than the source PNG so it stays crisp at
/// any size and can animate — the logo reveal in the brand film is a draw-on,
/// which `progress` reproduces.
///
/// All motion is a pure function of `t` (seconds), because this toolchain's
/// `@State` is unavailable — callers pass time in from a `TimelineView`.

// MARK: - One wave stroke

private struct WaveLine: Shape {
    /// Horizontal phase in radians; advancing it makes the wave travel.
    var phase: Double
    /// Peak deflection as a fraction of the rect height.
    var amplitude: Double
    /// Full sine cycles across the width.
    var cycles: Double

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let steps = 72
        for i in 0...steps {
            let f = Double(i) / Double(steps)
            let x = rect.minX + rect.width * f
            let y = rect.midY + rect.height * amplitude * sin(f * cycles * 2 * .pi + phase)
            let pt = CGPoint(x: x, y: y)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

// MARK: - The mark

struct WaveMark: View {
    /// Animation clock in seconds.
    var t: Double = 0
    /// Overall width; height follows the logo's proportions.
    var size: CGFloat = 120
    /// Ink color. The brand is black-on-paper — never tint the mark itself.
    var ink: Color = .black
    /// 0…1 draw-on progress for the reveal. 1 = fully drawn.
    var progress: Double = 1
    /// Set false to freeze the flow (Reduce Motion, or a static context).
    var animated: Bool = true

    /// Three rows, each two strokes — matching the supplied mark.
    private let rows = 3
    private var lineWidth: CGFloat { max(1.2, size * 0.030) }
    private var rowHeight: CGFloat { size * 0.150 }
    private var rowGap: CGFloat { size * 0.105 }

    var body: some View {
        VStack(spacing: rowGap) {
            ForEach(0..<rows, id: \.self) { row in
                waveRow(row)
            }
        }
        .frame(width: size)
    }

    private func waveRow(_ row: Int) -> some View {
        // Each row trails the one above, so the stack undulates instead of
        // sliding as a rigid block.
        let rowPhase = Double(row) * 0.55
        let travel = animated ? t * 1.15 : 0
        // The two strokes of a row are the same wave a hair apart, which is
        // what gives the mark its ribbon feel.
        return ZStack {
            ForEach(0..<2, id: \.self) { line in
                WaveLine(phase: travel + rowPhase + Double(line) * 0.30,
                         amplitude: 0.42,
                         cycles: 1.55)
                    .trim(from: 0, to: progress)
                    .stroke(ink, style: StrokeStyle(lineWidth: lineWidth,
                                                    lineCap: .round,
                                                    lineJoin: .round))
                    .offset(y: CGFloat(line) * lineWidth * 1.55 - lineWidth * 0.78)
            }
        }
        .frame(height: rowHeight)
    }
}

// MARK: - Loading state

/// The wave mark used as a progress indicator: it keeps flowing, and a
/// travelling highlight sweeps through it so "working" reads without a
/// spinner. Used on the warm-up screen while the speech model loads.
struct WaveLoader: View {
    var t: Double
    var size: CGFloat = 132
    var ink: Color
    var accent: Color
    var animated: Bool = true

    var body: some View {
        ZStack {
            WaveMark(t: t, size: size, ink: ink.opacity(0.22), animated: animated)
            WaveMark(t: t, size: size, ink: accent, animated: animated)
                .mask(sweep)
        }
    }

    /// A soft band travelling left→right on a 2.2 s loop.
    private var sweep: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let cycle = 2.2
            let p = animated ? (t.truncatingRemainder(dividingBy: cycle)) / cycle : 0.5
            LinearGradient(
                stops: [.init(color: .clear, location: 0),
                        .init(color: .white, location: 0.5),
                        .init(color: .clear, location: 1)],
                startPoint: .leading, endPoint: .trailing)
                .frame(width: w * 0.55)
                .offset(x: -w * 0.55 + (w * 1.55) * p)
        }
    }
}
