import Foundation

/// Routes an interpreted action to the handler that performs it. Deep app
/// control goes through hand-written AppleScript templates (see the Actions+*
/// files) — the LLM only ever fills in parameters and never writes code. The
/// one exception with real terminal access is agent_task, which always sits
/// behind a mandatory Fn-tap confirmation (see ActionGate).
enum ActionExecutor {
    @MainActor
    static func run(_ a: ZeldaFlowAction, context: CommandContext) async -> ActionOutcome {
        switch a.action {
        case "open_app":      return await BasicActions.openApp(a)
        case "close_app":     return await BasicActions.closeApp(a)
        case "open_url":      return BasicActions.openURL(a)
        case "navigate":      return BasicActions.navigate(a)
        case "type_text":     return await BasicActions.typeText(a, context: context)
        // Drive the frontmost app through its own menus — the general
        // "do anything in any app" path.
        case "create_folder": return await FileActions.createFolder(a)
        case "create_file":   return await FileActions.createFile(a)
        case "delete_file":   return await FileActions.delete(a)
        case "move_file":     return await FileActions.move(a)
        case "list_files":    return await FileActions.list(a)
        case "reveal_file":   return await FileActions.reveal(a)
        case "ui_command":    return await UIActions.runMenuCommand(a, context: context)
        case "ui_click":      return await UIActions.click(a, context: context)
        case "ui_type":       return await UIActions.type(a, context: context)
        case "press_key":     return await UIActions.pressKey(a, context: context)
        case "edit_text":     return await EditActions.editSelection(a, context: context)
        case "play_music":    return await BasicActions.playMusic(a)
        case "music_control": return await BasicActions.musicControl(a)
        case "set_volume":    return await BasicActions.setVolume(a)
        case "add_reminder":  return await BasicActions.addReminder(a)
        case "create_note":   return await BasicActions.createNote(a)
        case "create_event":  return await BasicActions.createEvent(a)
        case "web_answer":    return await WebAnswer.run(a)
        case "send_email":    return await CommsActions.email(a, send: true)
        case "draft_email":   return await CommsActions.email(a, send: false)
        case "send_message":  return await CommsActions.sendMessage(a)
        case "analyze_screen": return await AgentActions.analyzeScreen(a)
        case "agent_task":    return await AgentActions.agentTask(a)
        case "cancel_agent":  return AgentActions.cancelAgent()
        case "ask_claude":    return await AgentActions.askClaude(a)
        default:
            return ActionOutcome(ok: false, summary: "[not understood]",
                                 pillMessage: a.reason ?? "Didn't understand that command")
        }
    }
}
