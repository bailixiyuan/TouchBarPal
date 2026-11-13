import Foundation

/// Login item backed by a per-user LaunchAgent. Like KeepAwake, this avoids
/// SMAppService so an ad-hoc signed, locally built bundle works without a
/// Developer ID.
final class LoginItem {
    static let label = "com.local.touchbarpal"

    private var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Self.label).plist")
    }

    var isEnabled: Bool {
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return false }
        let result = Shell.run("/bin/launchctl", ["print", "gui/\(getuid())/\(Self.label)"])
        return result.status == 0
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        enabled ? enable() : disable()
    }

    private func enable() -> Bool {
        guard let executable = Bundle.main.executablePath else { return false }

        let directory = plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let contents: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [executable, "--background"],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": "/tmp/touchbarpal.out.log",
            "StandardErrorPath": "/tmp/touchbarpal.err.log"
        ]

        do {
            let data = try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            return false
        }

        _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(Self.label)"])
        let result = Shell.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
        return result.status == 0
    }

    private func disable() -> Bool {
        _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(Self.label)"])
        try? FileManager.default.removeItem(at: plistURL)
        return true
    }
}
