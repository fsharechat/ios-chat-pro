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
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.25.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
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
    ]
)
