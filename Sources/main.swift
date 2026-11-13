import AppKit

// A `pkill` (SIGTERM) skips -applicationWillTerminate:, which would leave a
// stale system-modal Touch Bar registered with the Touch Bar server. Turning
// termination signals into a normal -terminate: keeps the bar cleanly
// dismissed and the next launch able to present it again.
private var terminationSources: [DispatchSourceSignal] = []

private func installTerminationHandlers() {
    for number in [SIGTERM, SIGINT, SIGHUP] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler {
            NSApp.terminate(nil)
        }
        source.resume()
        terminationSources.append(source)
    }
}

// Headless paste check: `--paste "some text"` writes the pasteboard and posts
// ⌘V to the frontmost app (used to verify the paste path end to end).
// Ask the already-running instance to paste (exercises the live target logic).
if let index = CommandLine.arguments.firstIndex(of: "--paste-remote"),
   index + 1 < CommandLine.arguments.count {
    DistributedNotificationCenter.default().postNotificationName(
        .init("com.local.touchbarpal.pasteRemote"),
        object: CommandLine.arguments[index + 1],
        userInfo: nil,
        deliverImmediately: true
    )
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--paste"),
   index + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    let text = CommandLine.arguments[index + 1]
    ClipboardStore.shared.paste(ClipItem(text: text, date: Date()))
    RunLoop.main.run(until: Date().addingTimeInterval(1.2))
    exit(0)
}

// Headless import check: `--import-pet <folder>` installs a pet and prints id.
if let index = CommandLine.arguments.firstIndex(of: "--import-pet"),
   index + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    do {
        let pet = try PetLibrary.shared.importPackage(
            from: URL(fileURLWithPath: CommandLine.arguments[index + 1])
        )
        print(pet.id)
        exit(0)
    } catch {
        FileHandle.standardError.write((error.localizedDescription + "\n").data(using: .utf8) ?? Data())
        exit(1)
    }
}

// Headless shortcut dump: `--dump-shortcuts <bundleID|pid>` prints the menu
// shortcuts Accessibility can see for that app. Used to measure coverage.
if let index = CommandLine.arguments.firstIndex(of: "--dump-shortcuts"),
   index + 1 < CommandLine.arguments.count {
    let argument = CommandLine.arguments[index + 1]
    let app: NSRunningApplication?
    if let pid = pid_t(argument) {
        app = NSRunningApplication(processIdentifier: pid)
    } else {
        app = NSRunningApplication.runningApplications(withBundleIdentifier: argument).first
    }
    guard let app else {
        FileHandle.standardError.write("app not running\n".data(using: .utf8) ?? Data())
        exit(1)
    }
    guard ShortcutReader.isTrusted else {
        FileHandle.standardError.write("accessibility not granted\n".data(using: .utf8) ?? Data())
        exit(2)
    }
    let list = ShortcutReader.shortcuts(for: app)
    for item in list {
        print("\(item.menu)\t\(item.display)\t\(item.title)")
    }
    FileHandle.standardError.write("count=\(list.count)\n".data(using: .utf8) ?? Data())
    exit(0)
}

// Headless press check: `--press-shortcut <bundleID> <title>` presses the
// first matching menu shortcut, verifying the Accessibility execution path.
if let index = CommandLine.arguments.firstIndex(of: "--press-shortcut"),
   index + 2 < CommandLine.arguments.count {
    let bundle = CommandLine.arguments[index + 1]
    let title = CommandLine.arguments[index + 2]
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
        FileHandle.standardError.write("app not running\n".data(using: .utf8) ?? Data())
        exit(1)
    }
    guard let match = ShortcutReader.shortcuts(for: app).first(where: { $0.title.contains(title) }) else {
        FileHandle.standardError.write("no matching shortcut\n".data(using: .utf8) ?? Data())
        exit(1)
    }
    let ok = ShortcutReader.perform(match, in: app)
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    print(ok ? "pressed \(match.display) \(match.title)" : "failed")
    exit(ok ? 0 : 1)
}

// Headless sanity check for the clipboard store and app scanner.
// Run the built binary with --selftest.
if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
    exit(0)
}

// No storyboard: the settings window is built in code and the Touch Bar bar is
// managed by TouchBarController. The delegate switches to a regular (Dock) app.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)

installTerminationHandlers()
application.run()
