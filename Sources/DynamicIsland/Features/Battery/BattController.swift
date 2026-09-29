import AppKit
import Foundation

/// Drives the `batt` command line tool (github.com/charlie0129/batt), which limits charging on
/// Apple Silicon MacBooks. Commands go through batt's daemon, so they need no password as long as
/// its config allows non-root access; installing and removing the daemon ask for one.
///
/// The state is read from batt's config file and a few of its commands rather than `batt status`,
/// which fails on some Macs ("key has no data").
@MainActor
final class BattController: ObservableObject {
    struct Config: Equatable {
        /// 100 means no limit.
        var limit = 100
        /// Charging starts again this many percent below the limit.
        var lowerLimitDelta = 2
        var preventIdleSleep = false
        var disableChargingPreSleep = false
        var preventSystemSleep = false
        var magSafeLED = MagSafeLED.disabled
        /// Calibration discharges to this percentage first.
        var dischargeThreshold = 15
        /// Calibration holds the battery at 100% this long.
        var holdMinutes = 120
        /// Cron expression of the calibration schedule, if one is set.
        var scheduleCron: String?
    }

    enum MagSafeLED: String, CaseIterable, Identifiable {
        /// batt leaves the LED alone.
        case disabled
        /// Green when the limit is reached, orange while charging.
        case enabled
        case alwaysOff

        var id: String { rawValue }

        var command: String {
            switch self {
            case .disabled: "disable"
            case .enabled: "enable"
            case .alwaysOff: "always-off"
            }
        }

        var title: String {
            switch self {
            case .disabled: L("Не трогать", "Off")
            case .enabled: L("По статусу", "Status")
            case .alwaysOff: L("Всегда выкл.", "Always off")
            }
        }

        init(configValue: String?) {
            let value = configValue?.lowercased() ?? ""
            if value.contains("always") {
                self = .alwaysOff
            } else if value.hasPrefix("enable") {
                self = .enabled
            } else {
                self = .disabled
            }
        }
    }

    struct Calibration: Equatable {
        var phase = "Idle"
        var isPaused = false
        var canPause = false
        var canCancel = false

        var isRunning: Bool { phase.lowercased() != "idle" }
    }

    enum Toggle {
        case preventIdleSleep, disableChargingPreSleep, preventSystemSleep

        var command: String {
            switch self {
            case .preventIdleSleep: "prevent-idle-sleep"
            case .disableChargingPreSleep: "disable-charging-pre-sleep"
            case .preventSystemSleep: "prevent-system-sleep"
            }
        }

        var keyPath: WritableKeyPath<Config, Bool> {
            switch self {
            case .preventIdleSleep: \.preventIdleSleep
            case .disableChargingPreSleep: \.disableChargingPreSleep
            case .preventSystemSleep: \.preventSystemSleep
            }
        }
    }

    @Published private(set) var config = Config()
    /// Nil until read, or if the command failed.
    @Published private(set) var isAdapterEnabled: Bool?
    @Published private(set) var calibration = Calibration()
    /// `batt schedule show` as is, e.g. when the next run is.
    @Published private(set) var scheduleDescription: String?
    @Published private(set) var version: String?
    @Published private(set) var battery: BatteryStatus?
    @Published private(set) var isPluggedIn = false
    /// The last command's error, shown until the next one succeeds.
    @Published private(set) var lastError: String?
    @Published private(set) var isRunningCommand = false

    private static let candidates = ["/usr/local/bin/batt", "/opt/homebrew/bin/batt"]
    private static let configURL = URL(filePath: "/etc/batt.json")
    private static let socketPath = "/var/run/batt.sock"

    /// Where batt is installed; nil if it isn't.
    static var executable: URL? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(filePath: $0) }
    }

    static var isInstalled: Bool { executable != nil }

    /// The daemon's socket exists: batt is installed system-wide and running.
    var isDaemonRunning: Bool {
        FileManager.default.fileExists(atPath: Self.socketPath)
    }

    // MARK: - Reading

    func refresh() async {
        if let (status, pluggedIn) = PowerMonitor.read() {
            battery = status
            isPluggedIn = pluggedIn
        }
        config = Self.readConfig()
        guard Self.executable != nil else { return }

        async let adapter = run(["adapter", "status"])
        async let calibrationOutput = run(["calibration", "status"])
        async let schedule = run(["schedule", "show"])
        async let versionOutput = version == nil ? run(["version"]) : nil

        if let output = await adapter?.output.lowercased() {
            isAdapterEnabled = output.contains("disabled") ? false : output.contains("enabled") ? true : nil
        }
        if let output = await calibrationOutput?.output {
            calibration = Self.parseCalibration(output)
        }
        if let output = await schedule?.output.trimmingCharacters(in: .whitespacesAndNewlines) {
            scheduleDescription = output.lowercased().contains("not set") ? nil : output
        }
        if let output = await versionOutput?.output {
            // "Client: v0.7.3\nDaemon: v0.7.3"
            version = output.split(separator: "\n").first.map { $0.replacingOccurrences(of: "Client:", with: "").trimmingCharacters(in: .whitespaces) }
        }
    }

    private static func readConfig() -> Config {
        var config = Config()
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return config }

        // Fields left at their default are missing from the file (omitempty).
        if let limit = json["limit"] as? Int, limit > 0 { config.limit = limit }
        if let delta = json["lowerLimitDelta"] as? Int, delta > 0 { config.lowerLimitDelta = delta }
        config.preventIdleSleep = json["preventIdleSleep"] as? Bool ?? false
        config.disableChargingPreSleep = json["disableChargingPreSleep"] as? Bool ?? false
        config.preventSystemSleep = json["preventSystemSleep"] as? Bool ?? false
        config.magSafeLED = MagSafeLED(configValue: json["controlMagSafeLED"] as? String)
        if let threshold = json["calibrationDischargeThreshold"] as? Int, threshold > 0 { config.dischargeThreshold = threshold }
        if let hold = json["calibrationHoldDurationMinutes"] as? Int, hold > 0 { config.holdMinutes = hold }
        let schedule = json["schedule"] as? [String: Any]
        let cron = (schedule?["cron"] as? String) ?? (json["cron"] as? String)
        config.scheduleCron = cron?.isEmpty == false ? cron : nil
        return config
    }

    /// "Phase: Idle\nCharge: 80%\n...\nPaused: false\nCan Pause: false  Can Cancel: false"
    private static func parseCalibration(_ output: String) -> Calibration {
        var result = Calibration()
        let text = output.replacingOccurrences(of: "  ", with: "\n")
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "phase": result.phase = parts[1]
            case "paused": result.isPaused = parts[1] == "true"
            case "can pause": result.canPause = parts[1] == "true"
            case "can cancel": result.canCancel = parts[1] == "true"
            default: break
            }
        }
        return result
    }

    // MARK: - Commands

    /// 10...100; 100 turns the limit off (same as `batt disable`).
    func setLimit(_ percent: Int) {
        config.limit = percent
        perform(["limit", "\(percent)"])
    }

    func disableLimit() {
        config.limit = 100
        perform(["disable"])
    }

    func setLowerLimitDelta(_ delta: Int) {
        config.lowerLimitDelta = delta
        perform(["lower-limit-delta", "\(delta)"])
    }

    /// Cuts or restores power from the charger without unplugging it.
    func setAdapter(_ enabled: Bool) {
        isAdapterEnabled = enabled
        perform(["adapter", enabled ? "enable" : "disable"])
    }

    func set(_ toggle: Toggle, _ enabled: Bool) {
        config[keyPath: toggle.keyPath] = enabled
        perform([toggle.command, enabled ? "enable" : "disable"])
    }

    func setMagSafeLED(_ mode: MagSafeLED) {
        config.magSafeLED = mode
        perform(["magsafe-led", mode.command])
    }

    func startCalibration() { perform(["calibration", "start"]) }
    func pauseCalibration() { perform(["calibration", "pause"]) }
    func resumeCalibration() { perform(["calibration", "resume"]) }
    func cancelCalibration() { perform(["calibration", "cancel"]) }

    /// 10...50 percent.
    func setDischargeThreshold(_ percent: Int) {
        config.dischargeThreshold = percent
        perform(["calibration", "discharge-threshold", "\(percent)"])
    }

    /// 10...1440 minutes.
    func setHoldMinutes(_ minutes: Int) {
        config.holdMinutes = minutes
        perform(["calibration", "hold-duration", "\(minutes)"])
    }

    /// A cron expression such as "0 10 1 * *" (10:00 on the 1st of every month).
    func setSchedule(_ cron: String) {
        config.scheduleCron = cron
        perform(["schedule", cron])
    }

    func disableSchedule() {
        config.scheduleCron = nil
        perform(["schedule", "disable"])
    }

    func postponeSchedule(_ duration: String = "1h") { perform(["schedule", "postpone", duration]) }
    func skipSchedule() { perform(["schedule", "skip"]) }

    /// Installs the daemon system-wide; macOS asks for the administrator password.
    func installDaemon() { performAsAdministrator("install") }

    /// Removes the daemon (the command itself stays); macOS asks for the administrator password.
    func uninstallDaemon() { performAsAdministrator("uninstall") }

    // MARK: - Running

    private struct Output {
        let output: String
        let succeeded: Bool
    }

    /// Runs a command, then re-reads the state (also undoing an optimistic change that failed).
    private func perform(_ arguments: [String]) {
        Task {
            isRunningCommand = true
            let result = await run(arguments)
            isRunningCommand = false
            if let result, !result.succeeded {
                lastError = Self.errorMessage(result.output)
            } else if result != nil {
                lastError = nil
            }
            await refresh()
        }
    }

    private func performAsAdministrator(_ command: String) {
        guard let executable = Self.executable else { return }
        let source = "do shell script quoted form of \"\(executable.path)\" & \" \(command)\" with administrator privileges"
        isRunningCommand = true
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            let message = (error?[NSAppleScript.errorMessage] as? String)
            // -128: the password prompt was cancelled.
            let cancelled = error?[NSAppleScript.errorNumber] as? Int == -128
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isRunningCommand = false
                    self.lastError = cancelled ? nil : message.map(Self.errorMessage)
                    Task { await self.refresh() }
                }
            }
        }
    }

    /// Nil if batt isn't installed or couldn't be started.
    private func run(_ arguments: [String]) async -> Output? {
        guard let executable = Self.executable else { return nil }
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { process in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(decoding: data, as: UTF8.self)
                continuation.resume(returning: Output(output: output, succeeded: process.terminationStatus == 0))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    /// batt's last line without the "Error:" prefix and log decorations.
    private static func errorMessage(_ output: String) -> String {
        let line = output.split(separator: "\n").last.map(String.init) ?? output
        var message = line.replacingOccurrences(of: "Error: ", with: "")
        if let range = message.range(of: "msg=\"") {
            message = String(message[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return message.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
