// swift-tools-version:5.8
import PackageDescription

let package = Package(
    name: "IMCore",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "IMProto", targets: ["IMProto"]),
        .library(name: "IMTransport", targets: ["IMTransport"]),
        .library(name: "IMClient", targets: ["IMClient"]),
        .library(name: "IMStorage", targets: ["IMStorage"]),
        .library(name: "IMMessaging", targets: ["IMMessaging"]),
        .library(name: "AppCore", targets: ["AppCore"]),
        .library(name: "IMContacts", targets: ["IMContacts"]),
        .library(name: "IMGroups", targets: ["IMGroups"]),
        .library(name: "IMKit", targets: ["IMKit"]),
        .library(name: "IMMedia", targets: ["IMMedia"]),
        .library(name: "IMCall", targets: ["IMCall"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.25.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
        // Pinned exactly, not `from:` — stasel/WebRTC's version numbers track
        // Chromium milestones, not semver compatibility promises, so an
        // unbounded range risks a silent ABI-breaking jump on `swift package
        // update` (see the Phase 3 design doc's risk note on this dependency).
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "149.0.0"),
    ],
    targets: [
        .target(
            name: "IMProto",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .testTarget(name: "IMProtoTests", dependencies: ["IMProto"]),
        .target(name: "IMTransport"),
        .testTarget(name: "IMTransportTests", dependencies: ["IMTransport"]),
        .target(name: "IMClient", dependencies: ["IMTransport", "IMProto"]),
        .testTarget(name: "IMClientTests", dependencies: ["IMClient"]),
        .target(name: "IMStorage", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "IMStorageTests", dependencies: ["IMStorage"]),
        .target(name: "IMMessaging", dependencies: ["IMClient", "IMStorage", "IMProto", "IMTransport"]),
        .testTarget(name: "IMMessagingTests", dependencies: ["IMMessaging"]),
        .target(name: "IMContacts", dependencies: ["IMClient", "IMStorage", "IMProto", "IMTransport"]),
        .testTarget(name: "IMContactsTests", dependencies: ["IMContacts"]),
        .target(name: "IMGroups", dependencies: ["IMClient", "IMStorage", "IMProto", "IMTransport"]),
        .testTarget(name: "IMGroupsTests", dependencies: ["IMGroups"]),
        .target(name: "IMKit", dependencies: ["IMStorage", "IMContacts", "IMMessaging", "IMMedia", "IMGroups"]),
        .testTarget(name: "IMKitTests", dependencies: ["IMKit"]),
        .target(name: "IMMedia", dependencies: ["IMClient", "IMProto", "IMTransport"]),
        .testTarget(name: "IMMediaTests", dependencies: ["IMMedia"]),
        .target(name: "IMCall", dependencies: ["IMMessaging", "IMStorage", "IMProto", "IMClient", .product(name: "WebRTC", package: "WebRTC")]),
        .testTarget(name: "IMCallTests", dependencies: ["IMCall", "IMMessaging", "IMStorage", "IMClient", "IMTransport", "IMProto"]),
        .target(name: "AppCore", dependencies: ["IMClient", "IMStorage", "IMMessaging", "IMContacts", "IMMedia", "IMGroups"]),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore", "IMClient", "IMProto", "IMTransport"]),
    ]
)
