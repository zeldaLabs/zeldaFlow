// swift-tools-version:6.2
//
// THIS MANIFEST DOES NOT BUILD THE APP. `scripts/build-app.sh` is the only
// supported build (ADR 10) and this file is kept for editor/tooling support
// only. It is deliberately out of date with the real build: it has no
// FluidAudio target and does not link CoreML/Accelerate/CoreAudio, so even
// on a toolchain where `swift build` runs it would not produce a working
// zeldaFlow. Change build inputs in scripts/build-app.sh, not here.
//
// NOTE: the macOS 27 beta CLT ships a PackageDescription whose swiftinterface
// and dylib disagree on several symbols (.v15, .swiftLanguageMode, the
// swiftLanguageVersions: init). Stick to API that exists in both: the string
// platform overload and unsafeFlags.
import PackageDescription

let package = Package(
    name: "zeldaFlow",
    platforms: [.macOS("15.0")],
    targets: [
        .binaryTarget(
            name: "whisper",
            path: "Vendor/whisper.xcframework"
        ),
        .executableTarget(
            name: "zeldaFlow",
            dependencies: ["whisper"],
            path: "Sources/zeldaFlow",
            swiftSettings: [
                // Swift 5 language mode: strict-concurrency findings stay warnings.
                .unsafeFlags(["-swift-version", "5"])
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                // The app bundle carries whisper.framework in Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        )
    ]
)
