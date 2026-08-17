// swift-tools-version:5.7
//
// FlashTeX — a native, live-rendering LaTeX editor.
//
//   Language  : Swift 5.7 (Xcode 14.2 / macOS 12+)
//   UI        : AppKit (fully native), PDFKit for preview
//   Build     : swift build -c release && ./build.sh
//
import PackageDescription

let package = Package(
    name: "FlashTeX",
    platforms: [.macOS(.v12)],
    targets: [
        .target(
            name: "FlashTeXCore",
            path: "Sources/FlashTeXCore"
        ),
        .executableTarget(
            name: "FlashTeX",
            dependencies: ["FlashTeXCore"],
            path: "Sources/FlashTeX"
        ),
        .testTarget(
            name: "FlashTeXCoreTests",
            dependencies: ["FlashTeXCore"],
            path: "Tests/FlashTeXCoreTests"
        ),
        .testTarget(
            name: "FlashTeXCompilerTests",
            dependencies: ["FlashTeX"],
            path: "Tests/FlashTeXCompilerTests"
        ),
    ]
)
