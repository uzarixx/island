import SwiftUI

/// Every setting and command of the `batt` tool, laid out like a settings form.
struct BatteryView: View {
    @ObservedObject var batt: BattController
    /// Shared with the notch: typing a custom schedule keeps it open and takes the keyboard.
    @Binding var isEditing: Bool

    /// Follows the slider while dragging; the limit is applied on release.
    @State private var draftLimit: Double?
    @State private var customCron = ""
    @FocusState private var isCronFocused: Bool
    /// "Удалить демон" asks again before doing it.
    @State private var confirmUninstall = false

    /// Calibration schedules offered as one click, in cron form.
    private static let schedulePresets: [(title: String, cron: String)] = [
        (L("Раз в месяц", "Monthly"), "0 10 1 * *"),
        (L("Раз в 2 мес.", "Every 2 mo."), "0 10 1 */2 *"),
        (L("Раз в 3 мес.", "Every 3 mo."), "0 10 1 */3 *"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if batt.isDaemonRunning {
                ScrollView {
                    form
                        .padding(.bottom, 4)
                }
                .scrollIndicators(.never)
            } else {
                MessageView(icon: "bolt.slash", text: L("Служба batt не установлена в системе", "The batt service isn’t installed"), action: L("Установить", "Install")) {
                    batt.installDaemon()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Keeps the state fresh while the tab is open, e.g. calibration moving through its phases.
        .task {
            while !Task.isCancelled {
                await batt.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .onChange(of: isCronFocused) { if isCronFocused { isEditing = true } }
        .onChange(of: isEditing) { if !isEditing { isCronFocused = false } }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(L("Батарея", "Battery"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            if let battery = batt.battery {
                Text("\(battery.level)% · \(batt.isPluggedIn ? (battery.isCharging ? L("заряжается", "charging") : L("от сети, не заряжается", "plugged in, not charging")) : L("от батареи", "on battery"))")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
            }
            if batt.isRunningCommand {
                ProgressView().controlSize(.mini)
            }
            Spacer(minLength: 8)
            if let error = batt.lastError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(error)
            } else if let version = batt.version {
                Text("batt \(version)")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Form

    private var form: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            limitRows
            Divider().overlay(.white.opacity(0.08))
            sleepRows
            Divider().overlay(.white.opacity(0.08))
            calibrationRows
            Divider().overlay(.white.opacity(0.08))
            GridRow {
                NotchFormLabel(L("Служба", "Service"))
                HStack(spacing: 8) {
                    Text(L("Работает", "Running"))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer(minLength: 0)
                    NotchFormButton(title: confirmUninstall ? L("Точно удалить?", "Really remove?") : L("Удалить службу batt", "Remove batt service")) {
                        if confirmUninstall {
                            confirmUninstall = false
                            batt.uninstallDaemon()
                        } else {
                            confirmUninstall = true
                        }
                    }
                    .help(L("batt uninstall — спросит пароль администратора", "batt uninstall — asks for an administrator password"))
                }
            }
        }
    }

    @ViewBuilder
    private var limitRows: some View {
        let limit = Int(draftLimit ?? Double(batt.config.limit))
        GridRow {
            NotchFormLabel(L("Лимит заряда", "Charge limit"))
            HStack(spacing: 8) {
                Slider(
                    value: Binding(get: { draftLimit ?? Double(batt.config.limit) }, set: { draftLimit = $0 }),
                    in: 10...100,
                    step: 5
                ) { editing in
                    if !editing, let draftLimit {
                        batt.setLimit(Int(draftLimit))
                        self.draftLimit = nil
                    }
                }
                .controlSize(.small)
                .tint(.green)
                .frame(width: 220)
                Text(limit >= 100 ? L("без лимита", "no limit") : "\(limit)%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 76, alignment: .leading)
                Spacer(minLength: 0)
                if batt.config.limit < 100 {
                    NotchFormButton(title: L("Заряжать до 100%", "Charge to 100%"), action: batt.disableLimit)
                        .help("batt disable")
                }
            }
        }
        GridRow {
            NotchFormLabel(L("Снова заряжать", "Recharge"))
            HStack(spacing: 8) {
                NotchStepper(
                    value: batt.config.lowerLimitDelta,
                    range: 1...20,
                    step: 1,
                    format: { L("на \($0)% ниже", "\($0)% below") },
                    set: batt.setLowerLimitDelta
                )
                if batt.config.limit < 100 {
                    Text(L("с \(max(batt.config.limit - batt.config.lowerLimitDelta, 0))%", "at \(max(batt.config.limit - batt.config.lowerLimitDelta, 0))%"))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        GridRow {
            NotchFormLabel(L("Адаптер", "Adapter"))
            NotchSwitch(
                title: L("Брать питание от зарядки", "Use power from charger"),
                help: L("Выключи, чтобы Mac разряжался, не вынимая кабель", "Turn off to drain the battery without unplugging"),
                isOn: batt.isAdapterEnabled ?? true,
                set: batt.setAdapter
            )
        }
    }

    @ViewBuilder
    private var sleepRows: some View {
        GridRow {
            NotchFormLabel(L("Сон", "Sleep"))
            NotchSwitch(
                title: L("Не засыпать, пока идёт зарядка", "Stay awake while charging"),
                help: L("Иначе во сне batt не может остановить зарядку на лимите", "Otherwise batt can’t stop charging at the limit during sleep"),
                isOn: batt.config.preventIdleSleep,
                set: { batt.set(.preventIdleSleep, $0) }
            )
        }
        GridRow {
            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            NotchSwitch(
                title: L("Выключать зарядку перед сном", "Stop charging before sleep"),
                help: L("Чтобы при закрытой крышке батарея не зарядилась до 100%", "So the battery doesn’t charge to 100% with the lid closed"),
                isOn: batt.config.disableChargingPreSleep,
                set: { batt.set(.disableChargingPreSleep, $0) }
            )
        }
        GridRow {
            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            NotchSwitch(
                title: L("Запрещать любой сон при зарядке (экспериментально)", "Prevent all sleep while charging (experimental)"),
                help: L("С этим выключи два пункта выше", "Turn off the two options above with this"),
                isOn: batt.config.preventSystemSleep,
                set: { batt.set(.preventSystemSleep, $0) }
            )
        }
        GridRow {
            NotchFormLabel("MagSafe")
            HStack(spacing: 8) {
                NotchSegmented(
                    options: BattController.MagSafeLED.allCases,
                    title: \.title,
                    selection: Binding(get: { batt.config.magSafeLED }, set: batt.setMagSafeLED)
                )
                Text(L("«По статусу»: зелёный — лимит, оранжевый — заряжается", "“Status”: green — at limit, orange — charging"))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var calibrationRows: some View {
        let calibration = batt.calibration
        GridRow {
            NotchFormLabel(L("Калибровка", "Calibration"))
            HStack(spacing: 6) {
                Text(Self.phaseTitle(calibration))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(calibration.isRunning ? .green : .white.opacity(0.6))
                Spacer(minLength: 4)
                if !calibration.isRunning {
                    NotchFormButton(title: L("Начать", "Start"), isPrimary: true, action: batt.startCalibration)
                        .help(L("Разрядка → зарядка до 100% → удержание → возврат к лимиту", "Discharge → charge to 100% → hold → back to limit"))
                }
                if calibration.canPause {
                    NotchFormButton(title: L("Пауза", "Pause"), action: batt.pauseCalibration)
                }
                if calibration.isPaused {
                    NotchFormButton(title: L("Продолжить", "Resume"), isPrimary: true, action: batt.resumeCalibration)
                }
                if calibration.canCancel {
                    NotchFormButton(title: L("Отменить", "Cancel"), action: batt.cancelCalibration)
                }
            }
        }
        GridRow {
            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    Text(L("Разрядить до", "Discharge to"))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                    NotchStepper(value: batt.config.dischargeThreshold, range: 10...50, step: 5, format: { "\($0)%" }, set: batt.setDischargeThreshold)
                }
                HStack(spacing: 6) {
                    Text(L("Держать 100%", "Hold 100%"))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                    NotchStepper(value: batt.config.holdMinutes, range: 10...1440, step: 30, format: Self.duration, set: batt.setHoldMinutes)
                }
            }
        }
        GridRow {
            NotchFormLabel(L("Расписание", "Schedule"))
            HStack(spacing: 6) {
                NotchSegmented(
                    options: Self.schedulePresets.map(\.cron) + [""],
                    title: { cron in Self.schedulePresets.first { $0.cron == cron }?.title ?? L("Выкл.", "Off") },
                    selection: Binding(
                        get: { batt.config.scheduleCron.flatMap { cron in Self.schedulePresets.contains { $0.cron == cron } ? cron : nil } ?? (batt.config.scheduleCron == nil ? "" : "custom") },
                        set: { cron in cron.isEmpty ? batt.disableSchedule() : batt.setSchedule(cron) }
                    )
                )
                NotchTextField(placeholder: batt.config.scheduleCron ?? L("свой cron: 0 10 * * 0", "custom cron: 0 10 * * 0"), text: $customCron)
                    .focused($isCronFocused)
                    .frame(width: 130)
                    .onSubmit {
                        let cron = customCron.trimmingCharacters(in: .whitespaces)
                        guard !cron.isEmpty else { return }
                        batt.setSchedule(cron)
                        customCron = ""
                        isEditing = false
                    }
                    .help(L("Минута час день месяц день-недели, например 0 10 * * 0 — по воскресеньям в 10:00", "Minute hour day month weekday, e.g. 0 10 * * 0 — Sundays at 10:00"))
            }
        }
        if batt.config.scheduleCron != nil || batt.scheduleDescription != nil {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                HStack(spacing: 6) {
                    if let description = batt.scheduleDescription {
                        Text(description)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(description)
                    }
                    Spacer(minLength: 4)
                    NotchFormButton(title: L("Отложить на час", "Postpone 1 hour")) { batt.postponeSchedule() }
                    NotchFormButton(title: L("Пропустить", "Skip"), action: batt.skipSchedule)
                }
            }
        }
    }

    private static func phaseTitle(_ calibration: BattController.Calibration) -> String {
        let phase: String = switch calibration.phase.lowercased() {
        case "idle": L("не идёт", "not running")
        case let value where value.contains("post"): L("разрядка после удержания", "discharging after hold")
        case let value where value.contains("discharg"): L("разрядка", "discharging")
        case let value where value.contains("charg"): L("зарядка до 100%", "charging to 100%")
        case let value where value.contains("hold"): L("удержание 100%", "holding 100%")
        case let value where value.contains("restor"): L("возврат к лимиту", "returning to limit")
        default: calibration.phase
        }
        return calibration.isPaused ? L("\(phase), на паузе", "\(phase), paused") : phase
    }

    /// "30 мин", "2 ч", "2 ч 30 мин".
    private static func duration(_ minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return L("\(rest) мин", "\(rest) min") }
        return rest == 0 ? L("\(hours) ч", "\(hours) h") : L("\(hours) ч \(rest) мин", "\(hours) h \(rest) min")
    }
}

/// A switch with a label, styled for the dark notch.
private struct NotchSwitch: View {
    let title: String
    let help: String
    let isOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: set)) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.85))
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(.green)
        .help(help)
    }
}

/// − value + in a glass capsule; each click is applied right away.
private struct NotchStepper: View {
    let value: Int
    let range: ClosedRange<Int>
    let step: Int
    let format: (Int) -> String
    let set: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            button("minus", enabled: value > range.lowerBound) { set(max(value - step, range.lowerBound)) }
            Text(format(value))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(minWidth: 44)
            button("plus", enabled: value < range.upperBound) { set(min(value + step, range.upperBound)) }
        }
        .padding(.horizontal, 2)
        .frame(height: 22)
        .notchGlass(in: Capsule())
    }

    private func button(_ systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(enabled ? 0.8 : 0.25))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
