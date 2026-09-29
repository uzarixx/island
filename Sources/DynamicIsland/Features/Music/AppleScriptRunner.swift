import AppKit

/// Runs AppleScript on a serial background queue so a slow reply from Spotify
/// never blocks the main thread (and with it the notch animation).
final class AppleScriptRunner: @unchecked Sendable {
    enum Outcome: Sendable {
        case success(String?)
        /// -1743: the user hasn't allowed us to control the app (Privacy → Automation).
        case notPermitted
        case failed
    }

    private let queue = DispatchQueue(label: "DynamicIsland.AppleScript", qos: .userInitiated)
    /// Only touched on `queue`.
    private var compiled: [String: NSAppleScript] = [:]

    /// - Parameter targetBundleID: the script is skipped if this app isn't running by the time it
    ///   gets to run: `tell application` would otherwise launch it.
    func run(_ source: String, cache: Bool, targetBundleID: String) async -> Outcome {
        await withCheckedContinuation { continuation in
            queue.async {
                guard !NSRunningApplication.runningApplications(withBundleIdentifier: targetBundleID).isEmpty else {
                    continuation.resume(returning: .failed)
                    return
                }
                continuation.resume(returning: self.execute(source, cache: cache))
            }
        }
    }

    /// For a script whose result is data rather than text, such as a cover picture; not cached.
    func runForData(_ source: String, targetBundleID: String) async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard !NSRunningApplication.runningApplications(withBundleIdentifier: targetBundleID).isEmpty,
                      let script = NSAppleScript(source: source)
                else {
                    continuation.resume(returning: nil)
                    return
                }
                var error: NSDictionary?
                let result = script.executeAndReturnError(&error)
                continuation.resume(returning: error == nil && !result.data.isEmpty ? result.data : nil)
            }
        }
    }

    private func execute(_ source: String, cache: Bool) -> Outcome {
        let script: NSAppleScript
        if let cached = compiled[source] {
            script = cached
        } else {
            guard let created = NSAppleScript(source: source) else { return .failed }
            if cache { compiled[source] = created }
            script = created
        }

        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            if error[NSAppleScript.errorNumber] as? Int == -1743 { return .notPermitted }
            NSLog("AppleScript error: \(error)")
            return .failed
        }
        return .success(result.stringValue)
    }
}
