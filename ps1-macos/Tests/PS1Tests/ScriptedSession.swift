import Foundation
@testable import PS1

/// A `GameSession` a test drives by hand. Every setter is recorded in
/// `calls` as it was made (`"setSpeed(4)"`), and every request by its name
/// (`"requestReset"`); a request waits until the test answers it, oldest
/// first, with the matching `answer*`. Like the real
/// session, a newer swap answers the waiting one `.superseded`, and `free()`
/// answers everything still waiting `.sessionStopped`.
@MainActor
final class ScriptedSession: GameSession {
    private(set) var calls: [String] = []
    /// What `start()` throws, or nil to start.
    var startError: Ps1Error?
    private(set) var started = false
    private(set) var freed = false

    var framesProduced: UInt64 = 0
    var padStatus: PadStatus = .idle
    var cardWrites: UInt64 = 0
    var rewindSeconds: Double = 0
    var newestDisplay = Ps1Display()
    var onEvent: (@MainActor (SessionEvent) -> Void)?

    /// Delivers `e` as the session's trampoline does, minus the hop.
    func emit(_ e: SessionEvent) { onEvent?(e) }

    private var saves: [@MainActor (Result<ResumeSnapshot, Ps1Error>) -> Void] = []
    private var loads: [(state: Data, done: @MainActor (Result<Data, Ps1Error>) -> Void)] = []
    private var resets: [@MainActor (Ps1Error?) -> Void] = []
    private var swap: (disc: DiscBytes, done: @MainActor (Ps1Error?) -> Void)?
    private var screenshots: [@MainActor (Data?) -> Void] = []

    var pendingSaves: Int { saves.count }
    var pendingLoads: [Data] { loads.map(\.state) }
    var pendingResets: Int { resets.count }
    var pendingSwap: DiscBytes? { swap?.disc }
    var pendingScreenshots: Int { screenshots.count }

    func start() throws(Ps1Error) {
        calls.append("start()")
        if let startError { throw startError }
        started = true
    }

    func setButtons(_ mask: UInt16) { calls.append("setButtons(\(mask))") }
    func setSticks(_ s: Sticks) { calls.append("setSticks(\(s.lx), \(s.ly), \(s.rx), \(s.ry))") }
    func pressAnalog() { calls.append("pressAnalog()") }
    func setSpeed(_ speed: Int) { calls.append("setSpeed(\(speed))") }
    func setPaused(_ paused: Bool) { calls.append("setPaused(\(paused))") }
    func setRewinding(_ on: Bool) { calls.append("setRewinding(\(on))") }
    func setPgxp(_ p: PgxpSettings) { calls.append("setPgxp(\(p))") }
    func setCpuEngine(_ e: CpuEngine) { calls.append("setCpuEngine(\(e))") }
    func setRewindBudget(bytes: Int) { calls.append("setRewindBudget(bytes: \(bytes))") }
    func setRunahead(frames: Int) { calls.append("setRunahead(frames: \(frames))") }
    func setVramMode(_ m: VramMode) { calls.append("setVramMode(\(m))") }
    func setGain(_ g: Float) { calls.append("setGain(\(g))") }
    func setDither(_ m: DitherMode) { calls.append("setDither(\(m))") }
    func setTextureFilter(_ f: TextureFilter) { calls.append("setTextureFilter(\(f))") }
    func setSpriteFilter(_ f: TextureFilter) { calls.append("setSpriteFilter(\(f))") }
    func setScale(_ s: Int) { calls.append("setScale(\(s))") }
    func setSize(points: CGSize, backingScale: CGFloat) {
        calls.append("setSize(points: \(points.width)x\(points.height), backingScale: \(backingScale))")
    }
    func setOccluded(_ o: Bool) { calls.append("setOccluded(\(o))") }
    func setBandShown(_ b: Bool) { calls.append("setBandShown(\(b))") }

    func requestSave(_ done: @escaping @MainActor (Result<ResumeSnapshot, Ps1Error>) -> Void) {
        calls.append("requestSave")
        guard !freed else { return done(.failure(.sessionStopped)) }
        saves.append(done)
    }

    func requestLoad(_ state: Data, _ done: @escaping @MainActor (Result<Data, Ps1Error>) -> Void) {
        calls.append("requestLoad")
        guard !freed else { return done(.failure(.sessionStopped)) }
        loads.append((state, done))
    }

    func requestReset(_ done: @escaping @MainActor (Ps1Error?) -> Void) {
        calls.append("requestReset")
        guard !freed else { return done(.sessionStopped) }
        resets.append(done)
    }

    func requestSwap(_ disc: DiscBytes, _ done: @escaping @MainActor (Ps1Error?) -> Void) {
        calls.append("requestSwap")
        guard !freed else { return done(.sessionStopped) }
        let old = swap
        swap = (disc, done)
        old?.done(.superseded)
    }

    func requestScreenshot(_ done: @escaping @MainActor (Data?) -> Void) {
        calls.append("requestScreenshot")
        guard !freed else { return done(nil) }
        screenshots.append(done)
    }

    func answerSave(_ result: Result<ResumeSnapshot, Ps1Error>) {
        guard !saves.isEmpty else { return }
        saves.removeFirst()(result)
    }

    /// Answers the oldest save the way the real session's thread does: the
    /// answer is taken now, and lands on the main actor when the returned
    /// hop runs.
    func answerSaveLater(_ result: Result<ResumeSnapshot, Ps1Error>) -> @MainActor () -> Void {
        guard !saves.isEmpty else { return {} }
        let done = saves.removeFirst()
        return { done(result) }
    }

    func answerLoad(_ result: Result<Data, Ps1Error>) {
        guard !loads.isEmpty else { return }
        loads.removeFirst().done(result)
    }

    func answerReset(_ error: Ps1Error?) {
        guard !resets.isEmpty else { return }
        resets.removeFirst()(error)
    }

    func answerSwap(_ error: Ps1Error?) {
        guard let s = swap else { return }
        swap = nil
        s.done(error)
    }

    func answerScreenshot(_ png: Data?) {
        guard !screenshots.isEmpty else { return }
        screenshots.removeFirst()(png)
    }

    func free() {
        guard !freed else { return }
        freed = true
        calls.append("free()")
        while !saves.isEmpty { answerSave(.failure(.sessionStopped)) }
        while !loads.isEmpty { answerLoad(.failure(.sessionStopped)) }
        while !resets.isEmpty { answerReset(.sessionStopped) }
        answerSwap(.sessionStopped)
        while !screenshots.isEmpty { answerScreenshot(nil) }
    }
}
