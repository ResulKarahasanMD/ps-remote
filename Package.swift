// swift-tools-version: 6.0
import PackageDescription

// libchiaki is prebuilt by Scripts/build-libchiaki.sh into build/libchiaki;
// SwiftPM links those static archives directly and reads headers from the
// pinned submodule.
let root = Context.packageDirectory
let chiakiInclude = "\(root)/third_party/chiaki-ng/lib/include"
let chiakiBuild = "\(root)/build/libchiaki"
let brew = "/opt/homebrew/opt"

let chiakiLibDirs = [
    "\(chiakiBuild)/lib",
    "\(chiakiBuild)/third-party",
    "\(chiakiBuild)/third-party/nanopb",
    "\(chiakiBuild)/third-party/curl/lib",
]
let brewLibDirs = ["opus", "json-c", "miniupnpc", "libevent", "openssl@3"].map { "\(brew)/\($0)/lib" }

// Every target that imports CChiaki or COpus, directly or through ChiakiKit/MediaKit, needs both
// header search paths.
let chiakiSwiftSettings: [SwiftSetting] = [
    .unsafeFlags(["-Xcc", "-I\(chiakiInclude)", "-Xcc", "-I\(brew)/opus/include"]),
]

let chiakiLinkerSettings: [LinkerSetting] = [
    .unsafeFlags((chiakiLibDirs + brewLibDirs).map { "-L\($0)" }),
    .linkedLibrary("chiaki"),
    .linkedLibrary("gf_complete"),
    .linkedLibrary("jerasure"),
    .linkedLibrary("protobuf-nanopb"),
    .linkedLibrary("curl"),
    .linkedLibrary("opus"),
    .linkedLibrary("json-c"),
    .linkedLibrary("miniupnpc"),
    .linkedLibrary("event"),
    .linkedLibrary("ssl"),
    .linkedLibrary("crypto"),
    .linkedLibrary("z"),
    .linkedFramework("CoreFoundation"),
    .linkedFramework("CoreServices"),
    .linkedFramework("Security"),
    .linkedFramework("SystemConfiguration"),
]

let package = Package(
    name: "PSRemote",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "ChiakiKit", targets: ["ChiakiKit"]),
        .library(name: "MediaKit", targets: ["MediaKit"]),
        .executable(name: "psremote-cli", targets: ["psremote-cli"]),
    ],
    targets: [
        .systemLibrary(name: "CChiaki", path: "Libraries/CChiaki"),
        .systemLibrary(name: "COpus", path: "Libraries/COpus"),
        .target(
            name: "ChiakiKit",
            dependencies: ["CChiaki"],
            swiftSettings: chiakiSwiftSettings,
            linkerSettings: chiakiLinkerSettings
        ),
        .target(
            name: "MediaKit",
            dependencies: ["ChiakiKit", "COpus"],
            swiftSettings: chiakiSwiftSettings,
            linkerSettings: [
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("GameController"),
            ]
        ),
        .testTarget(
            name: "MediaKitTests",
            dependencies: ["MediaKit", "ChiakiKit", "COpus"],
            swiftSettings: chiakiSwiftSettings
        ),
        .executableTarget(
            name: "psremote-cli",
            dependencies: ["ChiakiKit", "MediaKit"],
            swiftSettings: chiakiSwiftSettings
        ),
        .testTarget(
            name: "ChiakiKitTests",
            dependencies: ["ChiakiKit", "CChiaki"],
            swiftSettings: chiakiSwiftSettings
        ),
    ]
)
