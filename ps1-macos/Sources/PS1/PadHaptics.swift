import CoreHaptics
import GameController

/// What the two motors should be doing, in Core Haptics' terms.
struct MotorDrive: Equatable {
    /// The large (left) motor, 0...1.
    var large: Float
    /// The small (right) motor: one speed, on or off.
    var small: Bool

    static let stopped = MotorDrive(large: 0, small: false)

    init(large: Float, small: Bool) {
        self.large = large
        self.small = small
    }

    /// `allowed` folds in every reason to keep still: Vibration off, the game
    /// paused, a dialog up, the app in the background. A motor left on with
    /// the emulator stopped would vibrate forever.
    init(status: PadStatus, allowed: Bool) {
        guard allowed else { self = .stopped; return }
        self.init(large: Float(status.large) / 255, small: status.small != 0)
    }

    /// For a controller with one actuator group: whichever motor is stronger.
    var combined: Float { max(large, small ? 1 : 0) }
}

/// The game's rumble on the controller that last sent input.
///
/// Two engines, one per handle, laid out as the original DualShock is: the
/// large motor in the left grip, the small one in the right. Each plays one
/// looping continuous event, and a motor's level reaches it as the dynamic
/// intensity, sent only when it changes. A controller without both handles
/// gets one engine over `.handles`; one without haptics, nothing.
@MainActor
final class PadHaptics {
    private enum Role { case large, small, combined }

    private struct Channel {
        let role: Role
        let engine: CHHapticEngine
        let player: CHHapticAdvancedPatternPlayer
        var level: Float = 0
    }

    private var target: ObjectIdentifier?
    private var channels: [Channel] = []
    private var built = false
    private var applied = MotorDrive.stopped

    /// Switching controllers stops the old one before the new one is used.
    func noteInput(from id: ObjectIdentifier) {
        guard id != target else { return }
        tearDown()
        target = id
    }

    func drive(_ d: MotorDrive) {
        guard d != applied else { return }
        if !built { build() }
        for i in channels.indices {
            set(&channels[i], to: level(of: channels[i].role, in: d))
        }
        applied = d
    }

    /// Stills the motors and keeps the engines for the next drive.
    func stop() { drive(.stopped) }

    /// Stills the motors and lets the engines go: the game is closing.
    func release() { tearDown() }

    /// Only the controller being driven matters: a second pad going to sleep
    /// must not cut the active one's rumble. A departure that names no
    /// controller is taken to be the active one. Returns whether it was.
    @discardableResult
    func controllerDisconnected(_ id: ObjectIdentifier?) -> Bool {
        guard id == nil || id == target else { return false }
        tearDown()
        target = nil
        return true
    }

    #if DEBUG
    var driveForTesting: MotorDrive { applied }
    #endif

    private func level(of role: Role, in d: MotorDrive) -> Float {
        switch role {
        case .large: return d.large
        case .small: return d.small ? 1 : 0
        case .combined: return d.combined
        }
    }

    /// A stopped player, not a silent one, at zero: a running continuous
    /// event at zero intensity still keeps the actuator powered.
    private func set(_ c: inout Channel, to level: Float) {
        guard level != c.level else { return }
        if level == 0 {
            try? c.player.stop(atTime: CHHapticTimeImmediate)
        } else {
            if c.level == 0 { try? c.player.start(atTime: CHHapticTimeImmediate) }
            try? c.player.sendParameters(
                [CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: level, relativeTime: 0)],
                atTime: CHHapticTimeImmediate)
        }
        c.level = level
    }

    private func build() {
        built = true
        guard let id = target,
              let controller = GCController.controllers().first(where: { ObjectIdentifier($0) == id }),
              let haptics = controller.haptics else { return }
        let localities = haptics.supportedLocalities
        if localities.contains(.leftHandle), localities.contains(.rightHandle),
           let large = channel(.large, haptics, .leftHandle, sharpness: 0.2),
           let small = channel(.small, haptics, .rightHandle, sharpness: 0.9) {
            channels = [large, small]
        } else if let one = channel(.combined, haptics, .handles, sharpness: 0.5) {
            channels = [one]
        }
    }

    private func channel(_ role: Role, _ haptics: GCDeviceHaptics,
                         _ locality: GCHapticsLocality, sharpness: Float) -> Channel? {
        guard let engine = haptics.createEngine(withLocality: locality) else { return nil }
        do {
            // A continuous event lasts at most 30 s; the player loops it.
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ], relativeTime: 0, duration: 30)
            let player = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
            player.loopEnabled = true
            // The server reset the engine: rebuild and replay what was asked.
            engine.resetHandler = { [weak self] in
                Task { @MainActor in self?.rebuild() }
            }
            // Stopped from outside (the controller slept, the system took
            // it): forget it, so the next change builds afresh.
            engine.stoppedHandler = { [weak self] _ in
                Task { @MainActor in self?.tearDown() }
            }
            try engine.start()
            return Channel(role: role, engine: engine, player: player)
        } catch {
            return nil
        }
    }

    private func rebuild() {
        let wanted = applied
        tearDown()
        drive(wanted)
    }

    private func tearDown() {
        for c in channels {
            // Detached first: a handler queued by this very stop would
            // otherwise land after a rebuild and tear the new engines down.
            c.engine.resetHandler = {}
            c.engine.stoppedHandler = { _ in }
            try? c.player.stop(atTime: CHHapticTimeImmediate)
            c.engine.stop()
        }
        channels = []
        built = false
        applied = .stopped
    }
}
