import SwiftUI

/// The clock as a slider over the whole range with its value beside it.
/// Not a menu: a hundred rows is no way to pick a number. The slider takes
/// no `step`, because AppKit draws a tick per step and a hundred of them
/// read as a line; the binding rounds to the setting's step instead.
struct ClockSpeedControl: View {
    @Binding var percent: Int

    private static let range = Double(CpuOverclockSetting.choices.first!)...Double(CpuOverclockSetting.choices.last!)

    var body: some View {
        HStack(spacing: 12) {
            Slider(value: sliderValue, in: Self.range) {
                Text(SettingsCopy.cpuOverclockPercent.title)
            }
            .labelsHidden()
            .frame(minWidth: 180)
            .accessibilityValue("\(percent) percent")

            Text("\(percent)%")
                .monospacedDigit()
                .frame(minWidth: 48, alignment: .trailing)
        }
    }

    private var sliderValue: Binding<Double> {
        Binding(get: { Double(percent) }, set: { percent = Int(($0 / 10).rounded()) * 10 })
    }
}
