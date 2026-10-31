import SwiftUI

/// The clock as a slider over the whole range with a stepper beside it for
/// one step at a time and the exact value, as the HIG pairs them for a wide
/// range. Not a menu: a hundred rows is no way to pick a number.
struct ClockSpeedControl: View {
    @Binding var percent: Int

    private static let range = Double(CpuOverclockSetting.choices.first!)...Double(CpuOverclockSetting.choices.last!)

    var body: some View {
        HStack(spacing: 12) {
            Slider(value: sliderValue, in: Self.range, step: 10) {
                Text(SettingsCopy.cpuOverclockPercent.title)
            } minimumValueLabel: {
                Text("10%")
            } maximumValueLabel: {
                Text("1000%")
            }
            .labelsHidden()
            .frame(minWidth: 180)

            Stepper(value: $percent, in: CpuOverclockSetting.choices.first!...CpuOverclockSetting.choices.last!, step: 10) {
                Text("\(percent)%")
                    .monospacedDigit()
                    .frame(minWidth: 44, alignment: .trailing)
            }
            .accessibilityValue("\(percent) percent")
        }
    }

    private var sliderValue: Binding<Double> {
        Binding(get: { Double(percent) }, set: { percent = Int(($0 / 10).rounded()) * 10 })
    }
}
