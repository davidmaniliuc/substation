// swift-tools-version: 6.2
// tools-version 6.2 is the floor: `.macOS(.v26)` is unavailable in 6.0/6.1 and
// the manifest itself fails to compile.
import PackageDescription

let package = Package(
    name: "PS1",
    platforms: [.macOS(.v26)],
    products: [
        // The product keeps the name PS1 so the built binary is `PS1`, which is
        // what Info.plist's CFBundleExecutable and build.sh both expect.
        .executable(name: "PS1", targets: ["PS1App"]),
    ],
    targets: [
        // Exposes ps1-capi/include/ps1.h to Swift as module CPs1. The static
        // library itself is linked by build.sh with an ABSOLUTE path, not by an
        // unsafeFlags entry here: a relative path in a manifest resolves against
        // the linker's working directory and breaks the moment the package is
        // built from anywhere but its own root.
        .target(name: "CPs1"),
        // Everything except @main lives in a LIBRARY target. An executable
        // target cannot be linked until something defines `main`, so keeping
        // the app's code here means the test suite builds and runs from the
        // first component onward instead of only once the entry point exists.
        .target(name: "PS1", dependencies: ["CPs1"]),
        .executableTarget(name: "PS1App", dependencies: ["PS1"]),
        .testTarget(name: "PS1Tests", dependencies: ["PS1"]),
    ]
)
