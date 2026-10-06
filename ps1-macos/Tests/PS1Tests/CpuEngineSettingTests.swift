import Testing
import Foundation
@testable import PS1

/// A fresh defaults key per test: these write to the real `UserDefaults`.
private func uniqueKey() -> String { "test-cpu-engine-\(UUID().uuidString)" }

private func setting(_ key: String,
                     available: @escaping (CpuEngine) -> Bool = { _ in true }) -> CpuEngineSetting {
    CpuEngineSetting(key: key, defaults: .standard, isAvailable: available)
}

@Test func anUnusedKeyLoadsTheDefaultEngine() {
    #expect(setting(uniqueKey()).engine == CpuEngineSetting.defaultEngine)
}

@Test func theEngineRoundTripsThroughUserDefaults() {
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }
    var written = setting(key)
    written.set(.cachedInterpreter)
    #expect(setting(key).engine == .cachedInterpreter)
}

@Test func aStoredValueNoEngineMatchesLoadsTheDefault() {
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }
    UserDefaults.standard.set(7, forKey: key)
    #expect(setting(key).engine == CpuEngineSetting.defaultEngine)
}

/// The JIT on a build without one: run the cached interpreter, but keep the
/// stored choice, so the same preferences on an Apple silicon build get it back.
@Test func anUnavailableEngineRunsTheCachedInterpreterAndIsNotForgotten() {
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }
    var written = setting(key)
    // Recompiler is the default, and setting the current value writes nothing:
    // leave it first so the key really holds it.
    written.set(.interpreter)
    written.set(.recompiler)

    let noJit = setting(key, available: { $0 != .recompiler })
    #expect(noJit.engine == .cachedInterpreter)
    #expect(noJit.stored == .recompiler)
    #expect(UserDefaults.standard.integer(forKey: key) == CpuEngine.recompiler.rawValue)
}

@Test func cpuEngineRawValuesMatchTheCAbi() {
    #expect(CpuEngine.interpreter.rawValue == 0)
    #expect(CpuEngine.cachedInterpreter.rawValue == 1)
    #expect(CpuEngine.recompiler.rawValue == 2)
}

/// Spec: "The default stays Interpreter until Stage 3's gates are green, then
/// becomes Recompiler." Plan 7's smoke test is what this rests on.
@Test func theRecompilerIsTheDefault() {
    #expect(CpuEngineSetting.defaultEngine == .recompiler)
}
