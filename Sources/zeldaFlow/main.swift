import AppKit
import Foundation

// CLI modes (no UI): --selftest <wav> transcribes a file end-to-end,
// --evalcommands pins the command parser and confirmation gates,
// --evalactions executes real app-control actions and restores state,
// --evalui drives a real app through its own menus (needs Accessibility),
// --evalfiles exercises the file/folder actions in a scratch folder,
// --evaltask checks the multi-step task loop (safety, termination, pruning),
// --evalhotkey times the tap callback and pins the press/hold/tap gestures,
// --insert-test types text after a delay. Used for automated verification.
let args = CommandLine.arguments
if args.count >= 2, args[1] == "--selftest" {
    exit(SelfTest.run(wavPath: args.count >= 3 ? args[2] : nil))
}
if args.count >= 2, args[1] == "--evalcommands" {
    exit(CommandEvals.run())
}
if args.count >= 2, args[1] == "--evalui" {
    exit(UIEvals.run())
}
if args.count >= 3, args[1] == "--runtask" {
    exit(TaskEvals.runLive(goal: args[2]))
}
if args.count >= 2, args[1] == "--evalaudio" {
    exit(AudioEvals.run())
}
if args.count >= 2, args[1] == "--evalpill" {
    exit(PillEvals.run())
}
if args.count >= 2, args[1] == "--evalhotkey" {
    exit(HotkeyEvals.run())
}
if args.count >= 2, args[1] == "--evalmeeting" {
    exit(MeetingEvals.run())
}
if args.count >= 2, args[1] == "--evaltask" {
    exit(TaskEvals.run())
}
if args.count >= 2, args[1] == "--evalfiles" {
    exit(FileEvals.run())
}
if args.count >= 2, args[1] == "--evaldictionary" {
    exit(DictionaryEvals.run())
}
if args.count >= 2, args[1] == "--evalactions" {
    exit(ActionEvals.run())
}
if args.count >= 3, args[1] == "--insert-test" {
    Thread.sleep(forTimeInterval: 3)
    let sem = DispatchSemaphore(value: 0)
    Task {
        let result = await TextInserter.insert(args[2], expectedFrontmost: nil)
        print("insert result: \(result)")
        sem.signal()
    }
    while sem.wait(timeout: .now()) == .timedOut {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
