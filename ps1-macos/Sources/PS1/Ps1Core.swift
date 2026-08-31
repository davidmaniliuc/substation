import Foundation
import CPs1

/// Re-exported so the rest of the module can name the display descriptor
/// without importing CPs1. Keeping the C import to this one file is the point;
/// widening it to every file that merely passes a frame around would defeat it.
typealias Ps1Display = CPs1.Ps1Display
typealias Ps1GpuStream = CPs1.Ps1GpuStream

/// Every failure the C ABI can report, as a Swift error.
enum Ps1Error: Error, Equatable {
    case createFailed
    case badBIOSSize
    case badCue
    case multiFileCue
    case outOfMemory
    case badSBI
    case badMemcardSize
    case badSlot
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
        default: return .unknown(code)
        }
    }
}

/// The ONLY file in this app that touches the C ABI. Nothing else imports
/// CPs1, so the surface can be changed in one place.
///
/// Not thread-safe by itself: the emulator thread owns the instance and is the
/// only caller of `runFrame`/`readAudio`/`copyVRAM`.
final class Ps1Core {
    private let handle: OpaquePointer

    /// `Disc` BORROWS its bytes — it holds a slice, it does not copy. Retaining
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
    /// that has none — which is nearly all of them — but wrong for one that
    /// does: the protection check then never passes and the game loops on it
    /// behind a black screen. See `EmulatorViewModel.sidecar(forDisc:)`.
    func loadDisc(bin: Data, cue: Data?, sbi: Data?) throws {
        // Retain BEFORE the call: the core starts reading these bytes the
        // moment the disc is attached.
        self.discData = bin

        // Nested rather than flattened because withUnsafeBytes only guarantees
        // its pointer for the duration of its own closure.
        let code: Int32 = bin.withUnsafeBytes { binRaw -> Int32 in
            let binPtr = binRaw.bindMemory(to: UInt8.self).baseAddress
            return Self.withOptionalBytes(cue) { cuePtr, cueLen in
                Self.withOptionalBytes(sbi) { sbiPtr, sbiLen in
                    ps1_load_disc(handle, binPtr, bin.count, cuePtr, cueLen, sbiPtr, sbiLen)
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
    /// Called from the emulator thread, never the main actor — `EmulatorRunner`
    /// owns the core while it is running.
    ///
    /// The retain happens BEFORE the call and is rolled back on failure, the
    /// same shape `loadDisc` uses: the core starts reading these bytes the
    /// moment the disc is attached, and a rejected swap must leave the machine
    /// holding exactly what it held before — including the Data keeping the
    /// OUTGOING disc's slice alive.
    func swapDisc(bin: Data, cue: Data?, sbi: Data?) throws {
        let previous = discData
        self.discData = bin

        let code: Int32 = bin.withUnsafeBytes { binRaw -> Int32 in
            let binPtr = binRaw.bindMemory(to: UInt8.self).baseAddress
            return Self.withOptionalBytes(cue) { cuePtr, cueLen in
                Self.withOptionalBytes(sbi) { sbiPtr, sbiLen in
                    ps1_swap_disc(handle, binPtr, bin.count, cuePtr, cueLen, sbiPtr, sbiLen)
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

    func reset() { ps1_reset(handle) }
    func runFrame() { ps1_run_frame(handle) }
    func setButtons(_ mask: UInt16) { ps1_set_buttons(handle, mask) }

    /// PGXP geometry correction. Off is the shipped default; the core reads
    /// the flag per GTE operation and per store, so this is safe at any time.
    func setPgxp(_ enabled: Bool) { ps1_set_pgxp(handle, enabled ? 1 : 0) }

    /// Installs a card image. The core COPIES the bytes, so nothing is
    /// retained here — unlike the disc `.bin`, which it borrows.
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
        // with no compiler-checked link between the two — unlike the Zig
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
        // for `bytes` — this is the other half of that same guard, so a
        // divergence there fails loudly instead of silently reading as "clean".
        //
        // This guards MemoryCardStore.slots drifting ABOVE PS1_MEMCARD_SLOTS
        // — the C side then reports PS1_ERR_BAD_SLOT for the extra index, and
        // `took` comes back negative here. It cannot catch the opposite
        // drift, MemoryCardStore.slots BELOW PS1_MEMCARD_SLOTS: the loops on
        // both sides would simply never reach the extra slot, so a card that
        // exists on hardware would just never be asked about — no crash, no
        // "clean" read, nothing to notice at all.
        precondition(took >= 0, "takeMemcard: slot \(slot) is out of range")
        return took == 1 ? Data(scratch) : nil
    }

    /// `dst` must hold 1024*512 UInt16.
    func copyVRAM(into dst: UnsafeMutablePointer<UInt16>) { ps1_copy_vram(handle, dst) }

    /// One frame of recorded GP0 commands.
    ///
    /// The returned pointers are CORE-OWNED and alias the recorder's storage
    /// (ps1.h contract rule 4): valid only until the next `runFrame()`. Copy
    /// what you need before stepping the machine again.
    ///
    /// This is a DRAIN — it resets the recorder — so it must be called exactly
    /// once per `runFrame()`. Skipping it stacks the next frame on top until
    /// the capacity overruns.
    func takeFrameStream() -> Ps1GpuStream {
        var s = Ps1GpuStream()
        ps1_take_frame_stream(handle, &s)
        return s
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
