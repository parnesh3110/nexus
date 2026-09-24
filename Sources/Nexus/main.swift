import AppKit

// Objective-C exceptions (AppKit / AVFoundation misuse) get logged before the process dies.
// Swift runtime traps (force unwrap, index out of range) can't be caught here; for those,
// the last lines of the log file show what was happening right before the crash.
NSSetUncaughtExceptionHandler { exception in
    logError("app", "uncaught_exception", [
        "name": exception.name.rawValue,
        "reason": exception.reason ?? "",
        "stack": Array(exception.callStackSymbols.prefix(20)),
    ])
    Log.shared.flush()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
app.run()
