import Foundation
import IOKit.ps

struct BatteryStatus: Equatable {
    /// Percent, 0...100.
    let level: Int
    let isCharging: Bool
}

/// Something worth a flash on the notch.
enum BatteryEvent: Equatable {
    /// The charger got connected.
    case pluggedIn(BatteryStatus)
    /// On battery, the charge dropped to one of `PowerMonitor.lowLevels`.
    case low(BatteryStatus)

    var status: BatteryStatus {
        switch self {
        case .pluggedIn(let status), .low(let status): status
        }
    }
}

/// Watches the power source and reports when the charger gets connected, like the iPhone's
/// charging animation, and when the battery runs low. Macs without a battery never report anything.
@MainActor
final class PowerMonitor {
    /// Warn once at each of these levels while discharging.
    static let lowLevels = [20, 10]

    private let onEvent: (BatteryEvent) -> Void
    private var runLoopSource: CFRunLoopSource?
    private var wasPluggedIn: Bool
    /// The lowest of `lowLevels` already warned about since the charger was last connected.
    private var warnedLevel: Int?

    init(onEvent: @escaping (BatteryEvent) -> Void) {
        self.onEvent = onEvent
        let current = Self.read()
        wasPluggedIn = current?.pluggedIn ?? true
        // Launching with a low battery doesn't warn; the next level down will.
        if let current, !current.pluggedIn { warnedLevel = Self.lowLevel(for: current.status.level) }

        // IOKit calls this on the run loop it's added to: the main one.
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.powerSourceChanged() }
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, Unmanaged.passUnretained(self).toOpaque())?
            .takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
    }

    deinit {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
    }

    private func powerSourceChanged() {
        guard let (status, pluggedIn) = Self.read() else { return }
        defer { wasPluggedIn = pluggedIn }
        if pluggedIn {
            warnedLevel = nil
            if !wasPluggedIn { onEvent(.pluggedIn(status)) }
            return
        }
        guard let level = Self.lowLevel(for: status.level), level < warnedLevel ?? .max else { return }
        warnedLevel = level
        onEvent(.low(status))
    }

    /// The lowest warning level the charge is at or below.
    private static func lowLevel(for charge: Int) -> Int? {
        lowLevels.filter { charge <= $0 }.min()
    }

    /// The internal battery's charge and whether the Mac runs on the adapter; nil without a battery.
    static func read() -> (status: BatteryStatus, pluggedIn: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            let status = BatteryStatus(
                level: min(100, current * 100 / max),
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false
            )
            let pluggedIn = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return (status, pluggedIn)
        }
        return nil
    }
}
