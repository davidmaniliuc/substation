import Foundation
import CPs1

/// Every failure the C ABI can report, as a Swift error.
enum Ps1Error: Error, Equatable {
    case createFailed
    case badBIOSSize
    case badCue
    case multiFileCue
    case outOfMemory
    case unknown(Int32)

    static func from(_ code: Int32) -> Ps1Error? {
        switch code {
        case 0: return nil
        case -1: return .badBIOSSize
        case -2: return .badCue
        case -3: return .multiFileCue
        case -4: return .outOfMemory
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
    /// `cue` is parsed immediately and is not retained.
    func loadDisc(bin: Data, cue: Data?) throws {
        // Retain BEFORE the call: the core starts reading these bytes the
        // moment the disc is attached.
        self.discData = bin

        let code: Int32 = bin.withUnsafeBytes { binRaw -> Int32 in
            let binPtr = binRaw.bindMemory(to: UInt8.self).baseAddress
            if let cue {
                return cue.withUnsafeBytes { cueRaw -> Int32 in
                    ps1_load_disc(handle, binPtr, bin.count,
                                  cueRaw.bindMemory(to: UInt8.self).baseAddress, cue.count)
                }
            }
            return ps1_load_disc(handle, binPtr, bin.count, nil, 0)
        }

        if let e = Ps1Error.from(code) {
            self.discData = nil
            throw e
        }
    }

    func reset() { ps1_reset(handle) }
    func runFrame() { ps1_run_frame(handle) }
    func setButtons(_ mask: UInt16) { ps1_set_buttons(handle, mask) }

    /// `dst` must hold 1024*512 UInt16.
    func copyVRAM(into dst: UnsafeMutablePointer<UInt16>) { ps1_copy_vram(handle, dst) }

    func display() -> Ps1Display {
        var d = Ps1Display()
        ps1_get_display(handle, &d)
        return d
    }

    func readAudio(into dst: UnsafeMutablePointer<Float>, maxFloats: Int) -> Int {
        ps1_read_audio(handle, dst, maxFloats)
    }
}
