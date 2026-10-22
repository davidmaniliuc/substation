import AppKit
import CPs1
import Foundation

/// A disc as the session takes it: the `.bin` is borrowed for as long as the
/// session reads it, the other three are read during the call that hands
/// them over.
struct DiscBytes {
    var bin: Data
    var cue: Data?
    var sbi: Data?
    var ppf: Data?
}

/// Everything a session is built from. The toolbar band's three numbers are
/// `ToolbarBand`'s, filled in by `Session.init`.
struct SessionConfig {
    var bios: Data
    /// Nil boots the BIOS shell.
    var disc: DiscBytes?
    /// Nil is a cold boot.
    var resumeState: Data?
    /// Created on the first card write.
    var cardDirectory: URL
    /// The view the picture goes on, or nil to present nowhere.
    var view: NSView?
    var cpuEngine: CpuEngine
    var fastBoot: Bool
}

/// The ten PGXP switches and the tolerance, applied in one call so the
/// per-frame re-apply costs one crossing.
struct PgxpSettings: Equatable, Sendable {
    var enabled = false
    var cpu = false
    var culling = false
    var vertexCache = false
    var textureCorrection = false
    var colorCorrection = false
    var depthBuffer = false
    var transparentDepth = false
    var disable2d = false
    var preserveProjection = false
    /// Nil is "none".
    var tolerance: Float?
}

/// One running game, below the user interface: the machine, its threads,
/// the audio output and the memory cards. Every setter returns at once;
/// every request's completion runs exactly once, on the main actor.
@MainActor
protocol GameSession: AnyObject {
    func start() throws(Ps1Error)

    func setButtons(_ mask: UInt16)
    func setSticks(_ s: Sticks)
    func pressAnalog()
    func setSpeed(_ speed: Int)
    func setPaused(_ paused: Bool)
    func setRewinding(_ on: Bool)
    func setPgxp(_ p: PgxpSettings)
    func setCpuEngine(_ e: CpuEngine)
    func setRewindBudget(bytes: Int)
    func setRunahead(frames: Int)
    func setGain(_ g: Float)
    func setDither(_ m: DitherMode)
    func setTextureFilter(_ f: TextureFilter)
    func setSpriteFilter(_ f: TextureFilter)
    func setScale(_ s: Int)
    func setSize(points: CGSize, backingScale: CGFloat)
    func setOccluded(_ o: Bool)
    func setBandShown(_ b: Bool)

    func requestSave(_ done: @escaping @MainActor (Result<ResumeSnapshot, Ps1Error>) -> Void)
    /// On success, the state the load replaced: Undo Load State's bytes.
    func requestLoad(_ state: Data, _ done: @escaping @MainActor (Result<Data, Ps1Error>) -> Void)
    func requestReset(_ done: @escaping @MainActor (Ps1Error?) -> Void)
    /// A newer swap answers this one `.superseded`.
    func requestSwap(_ disc: DiscBytes, _ done: @escaping @MainActor (Ps1Error?) -> Void)
    /// A PNG, or nil when no picture could be taken.
    func requestScreenshot(_ done: @escaping @MainActor (Data?) -> Void)

    var framesProduced: UInt64 { get }
    var padStatus: PadStatus { get }
    var cardWrites: UInt64 { get }
    var rewindSeconds: Double { get }
    var newestDisplay: Ps1Display { get }

    /// Stops everything, answering every waiting request `.sessionStopped`
    /// and writing the cards. Idempotent.
    func free()
}

/// Keeps a disc's `.bin` alive while the session borrows it. One retain
/// crosses the ABI as the disc's `release_ctx` and the session's `release`
/// gives it back. Held as `NSData` because its `bytes` stay put for the
/// object's lifetime, which a `Data`'s `withUnsafeBytes` pointer does not
/// promise past its closure.
final class DiscBox: @unchecked Sendable {
    let bin: NSData
    /// Called once the session hands the bytes back, before the retain goes.
    let onRelease: (@Sendable () -> Void)?

    init(_ bin: Data, onRelease: (@Sendable () -> Void)? = nil) {
        self.bin = bin as NSData
        self.onRelease = onRelease
    }
}

/// A completion carried across the ABI as a request's `ctx`: retained when
/// the request is made, consumed by the trampoline that answers it, which
/// hands the answer to the main actor without waiting for it.
private final class Pending<Answer: Sendable>: @unchecked Sendable {
    let done: @MainActor (Answer) -> Void

    init(_ done: @escaping @MainActor (Answer) -> Void) { self.done = done }

    /// One retain, which `take` consumes.
    func lend() -> UnsafeMutableRawPointer { Unmanaged.passRetained(self).toOpaque() }

    static func take(_ ctx: UnsafeMutableRawPointer?) -> Pending {
        Unmanaged<Pending>.fromOpaque(ctx!).takeRetainedValue()
    }

    func answer(_ answer: Answer) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.done(answer) } }
    }
}

/// The bytes a completion lends, copied: they are valid only during the call.
private func copied(_ p: UnsafePointer<UInt8>?, _ n: Int) -> Data? {
    guard let p, n > 0 else { return nil }
    return Data(bytes: p, count: n)
}

private func failure(_ code: Int32) -> Ps1Error {
    Ps1Error.from(code) ?? .unknown(code)
}

/// The session C ABI (`ps1_session.h`) behind `GameSession`.
final class Session: GameSession {
    private var handle: OpaquePointer?
    private let makeBox: (Data) -> DiscBox

    /// Builds the machine and everything around it and starts nothing. A
    /// refusal leaves the disc's bytes with the caller, so its box is
    /// released here rather than by the session.
    init(_ cfg: SessionConfig, makeBox: @escaping (Data) -> DiscBox = { DiscBox($0) }) throws(Ps1Error) {
        self.makeBox = makeBox
        let lent = cfg.disc.flatMap { Self.lend(makeBox($0.bin)) }
        var out: OpaquePointer?
        let code = cfg.cardDirectory.path.withCString { cardDir in
            Self.withDisc(cfg.disc, lent) { disc in
                Self.withBytes(cfg.resumeState) { resume, resumeLen in
                    cfg.bios.withUnsafeBytes { bios in
                        var c = Ps1SessionConfig(
                            bios: bios.bindMemory(to: UInt8.self).baseAddress, bios_len: bios.count,
                            disc: disc,
                            resume_state: resume, resume_len: resumeLen,
                            card_dir: cardDir,
                            ns_view: cfg.view.map { Unmanaged.passUnretained($0).toOpaque() },
                            band_height: ToolbarBand.height, band_edge: ToolbarBand.edge,
                            band_sigma: ToolbarBand.sigma,
                            cpu_engine: Int32(cfg.cpuEngine.rawValue),
                            fast_boot: cfg.fastBoot ? 1 : 0)
                        return ps1_session_new(&c, &out)
                    }
                }
            }
        }
        guard code == PS1_OK, let out else {
            lent?.release()
            throw failure(code)
        }
        handle = out
    }

    isolated deinit {
        free()
    }

    func start() throws(Ps1Error) {
        guard let handle else { throw .sessionStopped }
        let code = ps1_session_start(handle)
        if code != PS1_OK { throw failure(code) }
    }

    func free() {
        guard let h = handle else { return }
        handle = nil
        ps1_session_free(h)
    }

    // MARK: Setters

    func setButtons(_ mask: UInt16) {
        guard let handle else { return }
        ps1_session_set_buttons(handle, mask)
    }

    func setSticks(_ s: Sticks) {
        guard let handle else { return }
        ps1_session_set_sticks(handle, s.lx, s.ly, s.rx, s.ry)
    }

    func pressAnalog() {
        guard let handle else { return }
        ps1_session_press_analog(handle)
    }

    func setSpeed(_ speed: Int) {
        guard let handle else { return }
        ps1_session_set_speed(handle, Int32(clamping: speed))
    }

    func setPaused(_ paused: Bool) {
        guard let handle else { return }
        ps1_session_set_paused(handle, paused ? 1 : 0)
    }

    func setRewinding(_ on: Bool) {
        guard let handle else { return }
        ps1_session_set_rewinding(handle, on ? 1 : 0)
    }

    func setPgxp(_ p: PgxpSettings) {
        guard let handle else { return }
        var c = Ps1PgxpSettings(
            enabled: p.enabled ? 1 : 0, cpu: p.cpu ? 1 : 0, culling: p.culling ? 1 : 0,
            vertex_cache: p.vertexCache ? 1 : 0,
            texture_correction: p.textureCorrection ? 1 : 0,
            color_correction: p.colorCorrection ? 1 : 0,
            depth_buffer: p.depthBuffer ? 1 : 0,
            transparent_depth: p.transparentDepth ? 1 : 0,
            disable_2d: p.disable2d ? 1 : 0,
            preserve_projection: p.preserveProjection ? 1 : 0,
            tolerance: p.tolerance ?? -1)
        ps1_session_set_pgxp(handle, &c)
    }

    func setCpuEngine(_ e: CpuEngine) {
        guard let handle else { return }
        ps1_session_set_cpu_engine(handle, Int32(e.rawValue))
    }

    func setRewindBudget(bytes: Int) {
        guard let handle else { return }
        ps1_session_set_rewind_budget(handle, max(bytes, 0))
    }

    func setRunahead(frames: Int) {
        guard let handle else { return }
        ps1_session_set_runahead(handle, Int32(clamping: frames))
    }

    func setGain(_ g: Float) {
        guard let handle else { return }
        ps1_session_set_gain(handle, g)
    }

    func setDither(_ m: DitherMode) {
        guard let handle else { return }
        ps1_session_set_dither(handle, Int32(m.rawValue))
    }

    func setTextureFilter(_ f: TextureFilter) {
        guard let handle else { return }
        ps1_session_set_texture_filter(handle, Int32(f.rawValue))
    }

    func setSpriteFilter(_ f: TextureFilter) {
        guard let handle else { return }
        ps1_session_set_sprite_filter(handle, Int32(f.rawValue))
    }

    func setScale(_ s: Int) {
        guard let handle else { return }
        ps1_session_set_scale(handle, Int32(clamping: s))
    }

    func setSize(points: CGSize, backingScale: CGFloat) {
        guard let handle else { return }
        ps1_session_set_size(handle, points.width, points.height, backingScale)
    }

    func setOccluded(_ o: Bool) {
        guard let handle else { return }
        ps1_session_set_occluded(handle, o ? 1 : 0)
    }

    func setBandShown(_ b: Bool) {
        guard let handle else { return }
        ps1_session_set_band_shown(handle, b ? 1 : 0)
    }

    // MARK: Requests

    func requestSave(_ done: @escaping @MainActor (Result<ResumeSnapshot, Ps1Error>) -> Void) {
        let pending = Pending(done)
        guard let handle else { return pending.answer(.failure(.sessionStopped)) }
        ps1_session_request_save(handle, { ctx, code, state, stateLen, png, pngLen in
            let pending = Pending<Result<ResumeSnapshot, Ps1Error>>.take(ctx)
            guard code == PS1_OK else { return pending.answer(.failure(failure(code))) }
            let snapshot = ResumeSnapshot(state: copied(state, stateLen) ?? Data(),
                                          thumbnail: copied(png, pngLen))
            pending.answer(.success(snapshot))
        }, pending.lend())
    }

    func requestLoad(_ state: Data, _ done: @escaping @MainActor (Result<Data, Ps1Error>) -> Void) {
        let pending = Pending(done)
        guard let handle else { return pending.answer(.failure(.sessionStopped)) }
        let ctx = pending.lend()
        state.withUnsafeBytes { raw in
            ps1_session_request_load(handle, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, { ctx, code, undo, undoLen in
                let pending = Pending<Result<Data, Ps1Error>>.take(ctx)
                guard code == PS1_OK else { return pending.answer(.failure(failure(code))) }
                pending.answer(.success(copied(undo, undoLen) ?? Data()))
            }, ctx)
        }
    }

    func requestReset(_ done: @escaping @MainActor (Ps1Error?) -> Void) {
        let pending = Pending(done)
        guard let handle else { return pending.answer(.sessionStopped) }
        ps1_session_request_reset(handle, Self.simpleDone, pending.lend())
    }

    /// The disc's box is retained for the session until it calls `release`:
    /// swapped in and later replaced, superseded, refused, or freed.
    func requestSwap(_ disc: DiscBytes, _ done: @escaping @MainActor (Ps1Error?) -> Void) {
        let pending = Pending(done)
        guard let handle else { return pending.answer(.sessionStopped) }
        Self.withDisc(disc, Self.lend(makeBox(disc.bin))) { c in
            var c = c
            ps1_session_request_swap(handle, &c, Self.simpleDone, pending.lend())
        }
    }

    func requestScreenshot(_ done: @escaping @MainActor (Data?) -> Void) {
        let pending = Pending(done)
        guard let handle else { return pending.answer(nil) }
        ps1_session_request_screenshot(handle, { ctx, png, len in
            Pending<Data?>.take(ctx).answer(copied(png, len))
        }, pending.lend())
    }

    // MARK: Counters

    var framesProduced: UInt64 {
        guard let handle else { return 0 }
        return ps1_session_frames_produced(handle)
    }

    var padStatus: PadStatus {
        guard let handle else { return .idle }
        var s = Ps1PadStatus()
        ps1_session_pad_status(handle, &s)
        return PadStatus(analog: s.analog != 0, small: s.small, large: s.large)
    }

    var cardWrites: UInt64 {
        guard let handle else { return 0 }
        return ps1_session_card_writes(handle)
    }

    var rewindSeconds: Double {
        guard let handle else { return 0 }
        return ps1_session_rewind_seconds(handle)
    }

    var newestDisplay: Ps1Display {
        var d = Ps1Display()
        if let handle { ps1_session_newest_display(handle, &d) }
        return d
    }

    // MARK: Bridging

    private static let simpleDone: Ps1Done = { ctx, code in
        Pending<Ps1Error?>.take(ctx).answer(code == PS1_OK ? nil : failure(code))
    }

    /// The retain a disc's box carries across the ABI, or nil for an empty
    /// `.bin`, which the ABI reads as no disc at all and so never releases.
    private static func lend(_ box: DiscBox) -> Unmanaged<DiscBox>? {
        box.bin.length > 0 ? Unmanaged.passRetained(box) : nil
    }

    /// `disc` as the ABI takes it, valid for `body`. The `.bin` pointer
    /// outlives the call: `lent` is the retain that crosses as `release_ctx`,
    /// which the session's `release` gives back.
    private static func withDisc<R>(_ disc: DiscBytes?, _ lent: Unmanaged<DiscBox>?,
                                    _ body: (Ps1DiscBytes) -> R) -> R {
        guard let disc, let lent else { return body(Ps1DiscBytes()) }
        let box = lent.takeUnretainedValue()
        return withBytes(disc.cue) { cue, cueLen in
            withBytes(disc.sbi) { sbi, sbiLen in
                withBytes(disc.ppf) { ppf, ppfLen in
                    body(Ps1DiscBytes(
                        bin: box.bin.bytes.assumingMemoryBound(to: UInt8.self), bin_len: box.bin.length,
                        release: { ctx in
                            let box = Unmanaged<DiscBox>.fromOpaque(ctx!).takeRetainedValue()
                            box.onRelease?()
                        },
                        release_ctx: lent.toOpaque(),
                        cue: cue, cue_len: cueLen,
                        sbi: sbi, sbi_len: sbiLen,
                        ppf: ppf, ppf_len: ppfLen))
                }
            }
        }
    }

    private static func withBytes<R>(_ data: Data?,
                                     _ body: (UnsafePointer<UInt8>?, Int) -> R) -> R {
        guard let data else { return body(nil, 0) }
        return data.withUnsafeBytes { raw in
            body(raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
    }
}
