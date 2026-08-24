import Foundation
import AppKit

/// Speak-to-Edit: the user selects text anywhere, triple-taps Fn and says
/// "make this shorter" / "fix the grammar" / "translate this to French".
/// We copy the selection (⌘C), rewrite it with the local LLM, and paste the
/// result back over the selection — fully on-device.
enum EditActions {
    @MainActor
    static func editSelection(_ a: ZeldaFlowAction, context: CommandContext) async -> ActionOutcome {
        let instruction = (a.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else {
            return ActionOutcome(ok: false, summary: "[edit: no instruction]",
                                 pillMessage: "Edit it how?")
        }
        let selected = await TextInserter.copySelection()
        guard let selected, !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ActionOutcome(ok: false, summary: "[edit: no selection]",
                                 pillMessage: "Select some text first, then ask again")
        }
        guard selected.count <= 12_000 else {
            return ActionOutcome(ok: false, summary: "[edit: selection too long]",
                                 pillMessage: "That selection is too long to edit")
        }

        let cleanup = AppState.shared.cleanup
        guard await cleanup.ensureReady(timeoutSeconds: 20) else {
            return ActionOutcome(ok: false, summary: "[edit: llm unavailable]",
                                 pillMessage: "AI engine isn't running — see Settings → AI cleanup")
        }
        guard let rewritten = await cleanup.rewrite(text: selected, instruction: instruction),
              rewritten != selected else {
            return ActionOutcome(ok: false, summary: "[edit: no rewrite]",
                                 pillMessage: "Couldn't rewrite that — try rephrasing")
        }
        Log.info("editSelection: \(selected.count) → \(rewritten.count) chars (\(instruction))")

        let result = await TextInserter.insert(rewritten, expectedFrontmost: context.expectedFrontmost)
        switch result {
        case .pasted:
            return ActionOutcome(ok: true, summary: "[edited: \(instruction)]",
                                 pillMessage: "✏️ Done — \(instruction)")
        case .leftOnClipboard(let reason):
            return ActionOutcome(ok: false, summary: "[edit: paste blocked]", pillMessage: reason)
        }
    }
}
