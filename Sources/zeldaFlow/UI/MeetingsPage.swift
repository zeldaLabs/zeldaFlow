import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Hub's Meetings page (ADR 0027): day-grouped meeting list with search,
/// a pinned live-recording card, and the empty states that walk a new user
/// through the system-audio grant. Selecting a meeting swaps the whole page
/// for MeetingDetailView — MeetingNav.shared is the seam, because deep-link
/// sources (pill chip, menu bar, banner) live outside this view tree.

// @State is unavailable on this beta CLT (missing SwiftUIMacros plugin);
// small @StateObject models replace it throughout this file.
private final class MeetingsPageModel: ObservableObject {
    @Published var query = ""
    /// Permissions.systemAudio is a UserDefaults-backed static, not a
    /// publisher — the empty state bumps this after a probe so the page
    /// re-evaluates the permission instead of showing a stale CTA.
    @Published var permissionEpoch = 0
}

struct MeetingsPage: View {
    @StateObject private var model = MeetingsPageModel()
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var center = MeetingCenter.shared
    @ObservedObject private var nav = MeetingNav.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        if let id = nav.openMeetingID {
            MeetingDetailView(recordID: id, onBack: { MeetingNav.shared.openMeetingID = nil })
        } else {
            listBody
        }
    }

    // MARK: - List page

    private var listBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Meetings")
            countSearchRow
            if liveActivity {
                liveCard
                    .padding(.horizontal, 28)
                    .padding(.bottom, 8)
            }
            if store.records.isEmpty && !liveActivity {
                Spacer()
                emptyState
                Spacer()
            } else if filtered.isEmpty && !trimmedQuery.isEmpty {
                Spacer()
                Text("No meetings match “\(trimmedQuery)”")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 4, pinnedViews: .sectionHeaders) {
                        ForEach(dayGroups) { group in
                            Section {
                                ForEach(group.records) { record in
                                    MeetingRow(record: record)
                                }
                            } header: {
                                Text(group.label.uppercased())
                                    .font(.system(size: 11, weight: .semibold))
                                    .kerning(0.5)
                                    .foregroundStyle(Zelda.mutedFg)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 10)
                                    .padding(.bottom, 4)
                                    // Opaque page-color fill so rows scrolling
                                    // under the pinned header disappear behind
                                    // it instead of bleeding through.
                                    .background(Zelda.background)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
            }
        }
    }

    // MARK: - Count + search row

    private var countSearchRow: some View {
        HStack {
            Text("\(store.records.count) meetings · \(totalRecordedText) recorded")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Zelda.mutedFg)
                // The default (bezeled) AppKitTextField style: both borderless
                // presets hardcode inks for other surfaces (white for the type
                // bar, paper ink for onboarding) and would go illegible here in
                // one appearance — the bezeled field is the only adaptive one.
                AppKitTextField(placeholder: "Search meetings",
                                text: model.query,
                                onChange: { model.query = $0 },
                                onEscape: { model.query = "" })
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: Zelda.radiusSm).fill(Zelda.surface2))
            .frame(width: 260)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
    }

    private var totalRecordedText: String {
        let total = Int(store.records.reduce(0) { $0 + $1.durationSeconds })
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private var trimmedQuery: String {
        model.query.trimmingCharacters(in: .whitespaces)
    }

    private var filtered: [MeetingRecord] {
        let q = trimmedQuery
        guard !q.isEmpty else { return store.records }
        // Title + app name only in v1: transcripts load lazily per meeting
        // from per-meeting files, and grepping them on every keystroke is the
        // wrong v1 cost. displayTitle rather than raw title, so untitled
        // meetings match the "Meeting · 3:04 PM" text the row actually shows.
        return store.records.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(q)
                || $0.appName.localizedCaseInsensitiveContains(q)
        }
    }

    // MeetingDayGroup.grouped returns labeled tuples, and Swift key paths
    // can't refer to tuple elements — so ForEach gets a real Identifiable.
    // Labels are unique per grouping (records arrive date-sorted, so a day
    // never re-appears), which makes the label a valid identity.
    private var dayGroups: [DayGroup] {
        MeetingDayGroup.grouped(filtered).map { DayGroup(label: $0.label, records: $0.records) }
    }

    // MARK: - Live card

    private var liveActivity: Bool {
        switch center.uiPhase {
        case .recording, .processing: return true
        default: return false
        }
    }

    @ViewBuilder private var liveCard: some View {
        switch center.uiPhase {
        case .recording(let started, _):
            HStack(spacing: 10) {
                PulsingDot()
                Text("Recording now")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Zelda.onPrimaryContainer)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(elapsedText(from: started, to: ctx.date))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(Zelda.onPrimaryContainer.opacity(0.7))
                }
                Spacer()
                Button("Stop") { MeetingCenter.shared.stopManually() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: Zelda.radiusMd).fill(Zelda.primaryContainer))
            .contentShape(Rectangle())
            .onTapGesture {
                if let session = MeetingCenter.shared.liveSession {
                    MeetingNav.shared.openMeetingID = session.id
                }
            }
        case .processing(let step):
            // No Stop here: liveSession is already nil once processing starts,
            // so stopManually() is a guaranteed no-op — offering the button
            // would promise a cancel the pipeline doesn't have. Not tappable
            // either: the record may still be auto-discarded as a blip.
            HStack(spacing: 10) {
                PulsingDot()
                Text(step)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Zelda.onPrimaryContainer)
                Spacer()
                ProgressView()
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: Zelda.radiusMd).fill(Zelda.primaryContainer))
        default:
            EmptyView()
        }
    }

    // MARK: - Empty states

    @ViewBuilder private var emptyState: some View {
        // The bump in permissionEpoch is what re-runs this check post-probe.
        let _ = model.permissionEpoch
        VStack(spacing: 14) {
            if Permissions.systemAudio != .granted {
                Image(systemName: "speaker.wave.2.circle")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Zelda.mutedFg.opacity(0.6))
                Text("zeldaFlow needs system-audio access to hear the other side of your calls.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                Button("Enable system audio") {
                    // The probe itself is what makes macOS show the consent
                    // dialog; only a hard denial needs the Settings pane.
                    MeetingCenter.shared.probeSystemAudioAndRearm { status in
                        if status == .denied { Permissions.openSystemAudioPane() }
                        model.permissionEpoch += 1
                    }
                }
                .buttonStyle(.borderedProminent)
            } else {
                WaveMark(size: 72, ink: Zelda.mutedFg.opacity(0.45), animated: false)
                Text("Join a call — zeldaFlow records and writes the notes automatically. They'll appear here.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Text(settings.meetingAutoRecord
                     ? "Auto-record is on · change in Settings"
                     : "Auto-record is off — turn it on in Settings")
                    .font(.caption)
                    .foregroundStyle(Zelda.mutedFg)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct DayGroup: Identifiable {
    let label: String
    let records: [MeetingRecord]
    var id: String { label }
}

// MARK: - Row

/// CopyFlag's pattern (MainWindow.swift): a tiny ObservableObject standing in
/// for the unavailable @State.
private final class HoverFlag: ObservableObject {
    @Published var on = false
}

private struct MeetingRow: View {
    let record: MeetingRecord
    @StateObject private var hover = HoverFlag()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Zelda.foreground)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Zelda.mutedFg)
            }
            Spacer(minLength: 12)
            stateChip
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: Zelda.radiusSm)
            .fill(hover.on ? Zelda.surface2 : .clear))
        .onHover { hover.on = $0 }
        .onTapGesture { MeetingNav.shared.openMeetingID = record.id }
        .contextMenu {
            Button("Copy Notes") { copyNotes() }
            Button("Export Transcript…") { exportTranscript() }
            Divider()
            Button("Delete") { confirmDelete() }
        }
    }

    private var subtitle: String {
        var parts = [Self.timeFormatter.string(from: record.date),
                     durationText(record.durationSeconds)]
        if !record.appName.isEmpty { parts.append(record.appName) }
        return parts.joined(separator: " · ")
    }

    /// Staleness (notes older than the transcript) is deliberately not shown
    /// here: computing it needs the transcript hash, i.e. a full segment load
    /// per visible row. The detail view owns staleness; the list stays cheap.
    @ViewBuilder private var stateChip: some View {
        switch record.noteState {
        case .done:
            chip("Notes", fg: Zelda.onPrimaryContainer, bg: Zelda.primaryContainer)
        case .generating:
            HStack(spacing: 5) {
                PulsingDot(size: 5)
                Text("Writing notes…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Zelda.mutedFg)
            }
        case .none:
            chip("Transcript", fg: Zelda.mutedFg, bg: Zelda.surface2)
        case .failed:
            chip("Notes failed", fg: Zelda.amber, bg: Zelda.amberContainer)
        }
    }

    private func chip(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(bg))
    }

    // MARK: Context-menu actions

    private func copyNotes() {
        let id = record.id
        // loadNotes is a queue.sync read — keep even that off the main thread
        // so a busy store queue can't hitch the click.
        Task.detached {
            guard let notes = MeetingStore.shared.loadNotes(id) else { return }
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(notes, forType: .string)
            }
        }
    }

    private func exportTranscript() {
        let record = self.record
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        // ":" renders as "/" in Finder; keep the suggested name literal.
        panel.nameFieldStringValue = record.displayTitle
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: ".") + ".txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // Segment load off main (store guidance); the write rides along.
            Task.detached {
                let segments = MeetingStore.shared.loadSegments(record.id)
                let text = MeetingExporter.txt(record: record, segments: segments)
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    private func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = "Delete “\(record.displayTitle)”?"
        alert.informativeText = "The transcript and notes are removed permanently."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            MeetingStore.shared.delete(record.id)
        }
    }
}

// MARK: - Shared bits

/// 1 Hz breathing dot — motion as a pure function of the TimelineView clock,
/// because @State is unavailable on this toolchain.
private struct PulsingDot: View {
    var size: CGFloat = 7

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let on = Int(ctx.date.timeIntervalSinceReferenceDate) % 2 == 0
            Circle()
                .fill(Zelda.primary)
                .frame(width: size, height: size)
                .opacity(on ? 1 : 0.35)
                .animation(.easeInOut(duration: 0.6), value: on)
        }
    }
}

private func elapsedText(from start: Date, to now: Date) -> String {
    let s = max(0, Int(now.timeIntervalSince(start)))
    if s >= 3600 {
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
    return String(format: "%d:%02d", s / 60, s % 60)
}

private func durationText(_ seconds: Double) -> String {
    let m = max(1, Int((seconds / 60).rounded()))
    if m >= 60 { return "\(m / 60) h \(m % 60) min" }
    return "\(m) min"
}
