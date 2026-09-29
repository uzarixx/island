import SwiftUI

/// Compact form pieces styled for the dark notch.

struct NotchTextField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(.white.opacity(0.35)))
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .notchGlass(in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// Row label in a form grid, right-aligned like in macOS settings forms.
struct NotchFormLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.5))
            .gridColumnAlignment(.trailing)
    }
}

/// Segmented control in the macOS 26 style: the selected segment is a lighter pill and the
/// text stays white (not the iOS-like white pill with black text).
struct NotchSegmented<Option: Hashable>: View {
    let options: [Option]
    let title: (Option) -> String
    @Binding var selection: Option

    /// How far the glass pill is stretched while it travels; 0 at rest.
    @State private var stretch: CGFloat = 0
    /// The selection pill slides between options.
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let isSelected = selection == option
                Button {
                    select(option)
                } label: {
                    // The bold version sizes every option, so selecting one doesn't shift the others.
                    Text(title(option))
                        .font(.system(size: 12, weight: .semibold))
                        .hidden()
                        .overlay {
                            Text(title(option))
                                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                                .foregroundStyle(.white.opacity(isSelected ? 1 : 0.7))
                        }
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 11)
                        .frame(height: 24)
                        .background {
                            if isSelected {
                                Color.clear
                                    .notchGlass(in: Capsule(), tint: .white.opacity(0.12), fallback: .white.opacity(0.2))
                                    .scaleEffect(x: 1 + stretch, y: 1 - stretch * 0.3)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .notchGlass(in: Capsule())
    }

    /// Like the tab bar's lens: the pill stretches along its way, then wobbles back into shape.
    private func select(_ option: Option) {
        guard option != selection else { return }
        let from = options.firstIndex(of: selection) ?? 0
        let to = options.firstIndex(of: option) ?? 0
        // A longer jump stretches it more.
        let amount = min(0.12 + 0.08 * CGFloat(abs(to - from)), 0.4)

        withAnimation(.easeOut(duration: 0.1)) { stretch = amount }
        withAnimation(.spring(duration: 0.45, bounce: 0.3)) { selection = option }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.spring(duration: 0.4, bounce: 0.55)) { stretch = 0 }
        }
    }
}

/// Time you can type ("930", "10:30", "10.30"), with a macOS-style stepper next to it.
/// The stepper and the ↑ / ↓ keys move it by 15 minutes.
struct NotchTimeInput: View {
    @Binding var hour: Int
    @Binding var minute: Int

    @State private var text = ""
    @State private var isValid = true
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $text, prompt: Text("10:00").foregroundStyle(.white.opacity(0.3)))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(size: 15, weight: .medium).monospacedDigit())
                .foregroundStyle(isValid ? .white : .red)
                .frame(width: 64, height: 30)
                .notchGlass(
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous),
                    tint: isValid ? nil : .red.opacity(0.35)
                )
                .focused($isFocused)
                .onKeyPress(.upArrow) { shift(by: 15); return .handled }
                .onKeyPress(.downArrow) { shift(by: -15); return .handled }
                .onChange(of: text) {
                    // Insert the colon as you type; setting `text` re-runs this once, then it's a no-op.
                    let masked = Self.mask(text)
                    if masked != text {
                        text = masked
                        return
                    }
                    // Apply as you type; the text itself is tidied up when you leave the field.
                    if let (h, m) = Self.parse(text) {
                        hour = h
                        minute = m
                        isValid = true
                    } else {
                        isValid = text.isEmpty
                    }
                }
                .onChange(of: isFocused) { if !isFocused { text = formatted } }

            // Like NSStepper: a narrow capsule with ▲ over ▼.
            VStack(spacing: 0) {
                stepButton("chevron.up") { shift(by: 15) }
                stepButton("chevron.down") { shift(by: -15) }
            }
            .frame(width: 18, height: 30)
            .notchGlass(in: Capsule())
        }
        .onAppear { text = formatted }
    }

    private var formatted: String {
        String(format: "%02d:%02d", hour, minute)
    }

    private func stepButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 18, height: 15)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Moves to the previous/next multiple of `step`, wrapping around midnight.
    private func shift(by step: Int) {
        let total = hour * 60 + minute
        let size = abs(step)
        var next: Int
        if step > 0 {
            next = (total / size + 1) * size
        } else {
            next = total % size == 0 ? total - size : total - total % size
        }
        next = (next % 1440 + 1440) % 1440
        hour = next / 60
        minute = next % 60
        text = formatted
        isValid = true
    }

    /// What the field shows while typing: "183" → "18:3", "1830" → "18:30", "930" → "9:30".
    /// A separator typed by hand ("7:5", "10.30") is kept, as a colon. At most 4 digits.
    static func mask(_ string: String) -> String {
        if let separator = string.firstIndex(where: { !$0.isNumber }) {
            let hours = string[..<separator].filter(\.isNumber).prefix(2)
            let minutes = string[string.index(after: separator)...].filter(\.isNumber).prefix(2)
            return "\(hours):\(minutes)"
        }
        let digits = String(string.filter(\.isNumber).prefix(4))
        switch digits.count {
        case 2 where Int(digits)! > 23:
            // "93" can't be an hour: it's 9:3…
            return "\(digits.prefix(1)):\(digits.suffix(1))"
        case 3:
            // "183" → 18:3, but "930" → 9:30 since 93 can't be an hour.
            let splitAfter = Int(digits.prefix(2))! <= 23 ? 2 : 1
            return "\(digits.prefix(splitAfter)):\(digits.dropFirst(splitAfter))"
        case 4:
            return "\(digits.prefix(2)):\(digits.suffix(2))"
        default:
            return digits
        }
    }

    /// "9" → 9:00, "930" → 9:30, "1030" → 10:30, "10:30" / "10.30" / "10 30" → 10:30.
    static func parse(_ string: String) -> (Int, Int)? {
        let parts = string.split { !$0.isNumber }.map(String.init)
        let h: Int?, m: Int?
        if parts.count >= 2 {
            h = Int(parts[0]); m = Int(parts[1])
        } else if let digits = parts.first {
            switch digits.count {
            case 1, 2: h = Int(digits); m = 0
            case 3: h = Int(digits.prefix(1)); m = Int(digits.suffix(2))
            case 4: h = Int(digits.prefix(2)); m = Int(digits.suffix(2))
            default: return nil
            }
        } else {
            return nil
        }
        guard let h, let m, (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return (h, m)
    }
}

/// One-click days: "Сегодня", "Завтра", "Ср 30", … for the next two weeks.
struct NotchDayPicker: View {
    @Binding var day: Date

    private var days: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var days = (0..<14).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        // Keep an already chosen day that's outside the range (editing an older or distant meeting).
        let selected = calendar.startOfDay(for: day)
        if !days.contains(selected) { days.insert(selected, at: selected < today ? 0 : days.count) }
        return days
    }

    var body: some View {
        // Same control as the other choices, just scrollable: two weeks don't fit the width.
        ScrollView(.horizontal) {
            NotchSegmented(options: days, title: label(for:), selection: selectedDay)
        }
        .scrollIndicators(.never)
    }

    private var selectedDay: Binding<Date> {
        Binding(
            get: { Calendar.current.startOfDay(for: day) },
            set: { day = $0 }
        )
    }

    private func label(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return L("Сегодня", "Today") }
        if calendar.isDateInTomorrow(date) { return L("Завтра", "Tomorrow") }
        return date.formatted(.dateTime.weekday(.abbreviated).day().locale(.app))
    }
}

struct NotchFormButton: View {
    let title: String
    var isPrimary = false
    var isEnabled = true
    /// Overrides the system accent color of a primary button.
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: isPrimary ? .semibold : .regular))
                // Like macOS push buttons: the default one is accent-colored with white text,
                // and a disabled one is plain gray rather than a dim accent.
                .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.35))
                .padding(.horizontal, 16)
                .frame(height: 30)
                .frame(minWidth: 84)
                .notchGlass(
                    in: Capsule(),
                    tint: isPrimary && isEnabled ? (tint ?? .accentColor) : nil,
                    interactive: isEnabled,
                    fallback: .white.opacity(0.1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

/// Title row, fields, then a hint on the left and Cancel / Add on the right.
struct NotchFormLayout<Fields: View>: View {
    /// nil leaves more room for the fields.
    let title: String?
    var submitTitle = L("Добавить", "Add")
    let hint: Text?
    let canSubmit: Bool
    let submit: () -> Void
    let cancel: () -> Void
    @ViewBuilder let fields: () -> Fields

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            fields()
            // The buttons sit at the bottom of the notch, like in a macOS sheet.
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                hint?
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                NotchFormButton(title: L("Отмена", "Cancel"), action: cancel)
                NotchFormButton(title: submitTitle, isPrimary: true, isEnabled: canSubmit, action: submit)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onExitCommand(perform: cancel)
    }
}
