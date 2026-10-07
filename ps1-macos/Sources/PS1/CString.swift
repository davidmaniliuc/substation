/// A NUL-terminated C array inside a struct, which Swift imports as a tuple:
/// hence the pointer walk rather than a `String(cString:)` over the tuple
/// itself. Empty becomes nil: the core had nothing to say.
func cString<T>(_ field: inout T) -> String? {
    let text = withUnsafePointer(to: &field) {
        $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
            String(cString: $0)
        }
    }
    return text.isEmpty ? nil : text
}
