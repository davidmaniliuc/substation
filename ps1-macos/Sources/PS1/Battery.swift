import IOKit.ps

/// The internal battery, for the fullscreen title strip: fullscreen hides
/// the menu bar and with it the system's own battery readout.
struct Battery: Equatable {
    let percent: Int
    let charging: Bool

    /// The SF Symbol for the charge, in the system's quarter steps.
    var symbol: String {
        if charging { return "battery.100percent.bolt" }
        return "battery.\(percent >= 100 ? 100 : max(0, percent) / 25 * 25)percent"
    }

    /// Nil on a Mac with no internal battery, which then shows none.
    static func current() -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let now = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            return Battery(percent: now * 100 / max, charging: d[kIOPSIsChargingKey] as? Bool ?? false)
        }
        return nil
    }
}
