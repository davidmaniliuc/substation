import Foundation
import CPs1

/// Re-exported so a file that only passes a display descriptor around can
/// name it without importing CPs1.
typealias Ps1Display = CPs1.Ps1Display

/// Every failure the C ABI can report, as a Swift error.
enum Ps1Error: Error, Equatable {
    case createFailed
    case badBIOSSize
    case badCue
    case multiFileCue
    case outOfMemory
    case badSBI
    case badCHD
    case badMemcardSize
    case badSlot
    case stateBadMagic
    case stateVersion
    case stateBIOS
    case stateDisc
    case stateCorrupt
    case stateNoSpace
    case engineUnavailable
    case noSnapshot
    case noHistory
    case badPPF
    case ppfMismatch
    case statePatch
    /// The audio output would not start.
    case audio
    /// No Metal device to render with.
    case noMetal
    /// The session stopped with the request still waiting.
    case sessionStopped
    /// Too many requests of one kind already waiting.
    case busy
    /// A newer disc swap replaced this one before it went in.
    case superseded
    case unknown(Int32)

    static func from(_ code: Int32) -> Ps1Error? {
        switch code {
        case 0: return nil
        case -1: return .badBIOSSize
        case -2: return .badCue
        case -3: return .multiFileCue
        case -4: return .outOfMemory
        case -5: return .badSBI
        case -6: return .badMemcardSize
        case -7: return .badSlot
        case -8: return .stateBadMagic
        case -9: return .stateVersion
        case -10: return .stateBIOS
        case -11: return .stateDisc
        case -12: return .stateCorrupt
        case -13: return .stateNoSpace
        case -15: return .badCHD
        case -14: return .engineUnavailable
        case -16: return .noSnapshot
        case -17: return .noHistory
        case -18: return .badPPF
        case -19: return .ppfMismatch
        case -20: return .statePatch
        case -21: return .audio
        case -22: return .noMetal
        case -23: return .sessionStopped
        case -24: return .busy
        case -25: return .superseded
        default: return .unknown(code)
        }
    }
}

/// The machine handle (`ps1.h`), for whatever inspects a machine without
/// running it. A running game is a `Session` (`GameSession.swift`, over
/// `ps1_session.h`), which owns a machine of its own.
///
/// Not thread-safe by itself: one thread at a time may call it.
final class Ps1Core {
    private let handle: OpaquePointer

    /// `Disc` BORROWS its bytes: it holds a slice, it does not copy. Retaining
    /// the Data here is what keeps that slice valid for the handle's lifetime.
    private var discData: Data?

    init() throws {
        guard let h = ps1_create() else { throw Ps1Error.createFailed }
        self.handle = h
    }

    deinit {
        ps1_destroy(handle)
    }

    func loadBIOS(_ data: Data) throws {
        let code = data.withUnsafeBytes { raw in
            ps1_load_bios(handle, raw.bindMemory(to: UInt8.self).baseAddress, data.count)
        }
        if let e = Ps1Error.from(code) { throw e }
    }

    /// `bin` is retained for the handle's lifetime because the core borrows it.
    /// `cue` is parsed immediately and `sbi` is copied, so neither is retained.
    ///
    /// `sbi` is the disc's LibCrypt sidecar. Passing nil is right for any disc
    /// that has none (which is nearly all of them), but wrong for one that
    /// does: the protection check then never passes and the game loops on it
    /// behind a black screen. See `EmulatorViewModel.sidecar(forDisc:)`.
    ///
    /// `ppf` is a patch for the disc's sectors, applied by the core into its
    /// own memory, so it is not retained either. See
    /// `EmulatorViewModel.patch(forDisc:)`.
    func loadDisc(bin: Data, cue: Data?, sbi: Data?, ppf: Data? = nil) throws {
        // Retain BEFORE the call: the core starts reading these bytes the
        // moment the disc is attached.
        self.discData = bin

        // Nested rather than flattened because withUnsafeBytes only guarantees
        // its pointer for the duration of its own closure.
        let code: Int32 = bin.withUnsafeBytes { binRaw -> Int32 in
            let binPtr = binRaw.bindMemory(to: UInt8.self).baseAddress
            return Self.withOptionalBytes(cue) { cuePtr, cueLen in
                Self.withOptionalBytes(sbi) { sbiPtr, sbiLen in
                    Self.withOptionalBytes(ppf) { ppfPtr, ppfLen in
                        ps1_load_disc(handle, binPtr, bin.count, cuePtr, cueLen, sbiPtr, sbiLen, ppfPtr, ppfLen)
                    }
                }
            }
        }

        if let e = Ps1Error.from(code) {
            self.discData = nil
            throw e
        }
    }

    /// Exchanges the disc on a running machine: the tray opens, the disc goes
    /// in, and it closes an emulated second later, leaving the sticky status
    /// bit that tells the game to re-read the TOC.
    ///
    /// Called between frames, from the thread that runs the machine.
    ///
    /// The retain happens BEFORE the call and is rolled back on failure, the
    /// same shape `loadDisc` uses: the core starts reading these bytes the
    /// moment the disc is attached, and a rejected swap must leave the machine
    /// holding exactly what it held before, including the Data keeping the
    /// OUTGOING disc's slice alive.
    func swapDisc(bin: Data, cue: Data?, sbi: Data?, ppf: Data? = nil) throws {
        let previous = discData
        self.discData = bin

        let code: Int32 = bin.withUnsafeBytes { binRaw -> Int32 in
            let binPtr = binRaw.bindMemory(to: UInt8.self).baseAddress
            return Self.withOptionalBytes(cue) { cuePtr, cueLen in
                Self.withOptionalBytes(sbi) { sbiPtr, sbiLen in
                    Self.withOptionalBytes(ppf) { ppfPtr, ppfLen in
                        ps1_swap_disc(handle, binPtr, bin.count, cuePtr, cueLen, sbiPtr, sbiLen, ppfPtr, ppfLen)
                    }
                }
            }
        }

        if let e = Ps1Error.from(code) {
            self.discData = previous
            throw e
        }
    }

    var hasDisc: Bool { discData != nil }

    /// Runs `body` over the Data's bytes, or over the (NULL, 0) pair the ABI
    /// reads as "absent" when there is no Data at all.
    private static func withOptionalBytes<R>(
        _ data: Data?,
        _ body: (UnsafePointer<UInt8>?, Int) -> R
    ) -> R {
        guard let data else { return body(nil, 0) }
        return data.withUnsafeBytes { raw in
            body(raw.bindMemory(to: UInt8.self).baseAddress, data.count)
        }
    }

    func padStatus() -> PadStatus {
        var s = Ps1PadStatus()
        ps1_get_pad_status(handle, &s)
        return PadStatus(analog: s.analog != 0, small: s.small, large: s.large)
    }

    /// The choice survives `loadState`.
    func setCpuEngine(_ engine: CpuEngine) throws {
        if let e = Ps1Error.from(ps1_set_cpu_engine(handle, Int32(engine.rawValue))) { throw e }
    }

    /// The engine the machine is running on now.
    var cpuEngine: CpuEngine {
        CpuEngine(rawValue: Int(ps1_get_cpu_engine(handle))) ?? .interpreter
    }

    /// Whether this build has the engine: the recompiler is arm64 only.
    static func isCpuEngineAvailable(_ engine: CpuEngine) -> Bool {
        ps1_cpu_engine_available(Int32(engine.rawValue)) != 0
    }

    /// Installs a card image. The core COPIES the bytes, so nothing is
    /// retained here: unlike the disc `.bin`, which it borrows.
    func loadMemcard(_ data: Data, slot: Int) throws {
        let code = data.withUnsafeBytes { raw in
            ps1_load_memcard(handle, Int32(slot),
                             raw.bindMemory(to: UInt8.self).baseAddress, data.count)
        }
        if let e = Ps1Error.from(code) { throw e }
    }

    /// `nil` when the game has not written the card since the last call.
    ///
    /// `scratch` is the caller's buffer, reused across calls: this is polled
    /// once per loop iteration, and a fresh 128 KB allocation per frame to
    /// hold nothing would be absurd.
    func takeMemcard(slot: Int, into scratch: inout [UInt8]) -> Data? {
        // MemoryCardStore.bytes is a Swift-side mirror of PS1_MEMCARD_BYTES
        // with no compiler-checked link between the two: unlike the Zig
        // side, which ties them together with a @compileError guard. Without
        // this check a divergence would have the ABI write PS1_MEMCARD_BYTES
        // into a shorter buffer: a heap overflow, not a wrong number.
        precondition(scratch.count == Int(PS1_MEMCARD_BYTES),
                     "scratch must be exactly one card; the C ABI writes PS1_MEMCARD_BYTES into it")
        let took = scratch.withUnsafeMutableBufferPointer { buf in
            ps1_take_memcard(handle, Int32(slot), buf.baseAddress)
        }
        // A negative return is PS1_ERR_BAD_SLOT: `slot` came from outside the
        // 0..<MemoryCardStore.slots range the caller is responsible for
        // respecting. MemoryCardStore.slots mirrors PS1_MEMCARD_SLOTS with the
        // same unchecked Swift/C relationship the precondition above catches
        // for `bytes`: this is the other half of that same guard, so a
        // divergence there fails loudly instead of silently reading as "clean".
        //
        // This guards MemoryCardStore.slots drifting ABOVE PS1_MEMCARD_SLOTS:
        // the C side then reports PS1_ERR_BAD_SLOT for the extra index, and
        // `took` comes back negative here. It cannot catch the opposite
        // drift, MemoryCardStore.slots BELOW PS1_MEMCARD_SLOTS: the loops on
        // both sides would simply never reach the extra slot, so a card that
        // exists on hardware would just never be asked about; no crash, no
        // "clean" read, nothing to notice at all.
        precondition(took >= 0, "takeMemcard: slot \(slot) is out of range")
        return took == 1 ? Data(scratch) : nil
    }

    /// The whole machine. Call from the thread that owns the core.
    func saveState() throws -> Data {
        let size = ps1_save_state_size(handle)
        guard size > 0 else { throw Ps1Error.stateCorrupt }
        var data = Data(count: size)
        var written = 0
        let code = data.withUnsafeMutableBytes { raw in
            ps1_save_state(handle, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &written)
        }
        if let e = Ps1Error.from(code) { throw e }
        return data.prefix(written)
    }

    /// All-or-nothing in the core: a throw leaves the machine as it was.
    /// Load the BIOS and the disc first: the state records both and refuses
    /// a mismatch.
    func loadState(_ data: Data) throws {
        // An empty Data has no base address; the C side takes a non-optional pointer.
        guard !data.isEmpty else { throw Ps1Error.stateBadMagic }
        let code = data.withUnsafeBytes { raw in
            ps1_load_state(handle, raw.bindMemory(to: UInt8.self).baseAddress, data.count)
        }
        if let e = Ps1Error.from(code) { throw e }
    }

    /// The serial of the disc that was in the tray, read from the header
    /// alone. Nil for a disc that names none.
    static func peekStateSerial(_ data: Data) throws -> String? {
        guard !data.isEmpty else { throw Ps1Error.stateBadMagic }
        var info = Ps1StateInfo()
        let code = data.withUnsafeBytes { raw in
            ps1_peek_state(raw.bindMemory(to: UInt8.self).baseAddress, data.count, &info)
        }
        if let e = Ps1Error.from(code) { throw e }
        let bytes = withUnsafeBytes(of: info.serial) { Array($0) }.prefix { $0 != 0 }
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }

    func display() -> Ps1Display {
        var d = Ps1Display()
        ps1_get_display(handle, &d)
        return d
    }

    func readAudio(into dst: UnsafeMutablePointer<Float>, maxFloats: Int) -> Int {
        ps1_read_audio(handle, dst, maxFloats)
    }
}
