// swift-tools-version:5.8
import PackageDescription

let package = Package(
    name: "IMCore",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "IMProto", targets: ["IMProto"]),
        .library(name: "IMTransport", targets: ["IMTransport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.25.0"),
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
    ]
)
