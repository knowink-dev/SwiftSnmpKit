// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftSnmpKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v10_15)
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "SwiftSnmpKit",
            targets: ["SwiftSnmpKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", exact: .init(2, 62, 0)),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: .init(2, 6, 0)),
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift", exact: .init(1, 8, 0)),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "SwiftSnmpKit",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "CryptoSwift", package: "CryptoSwift")
            ]),
        .testTarget(
            name: "SwiftSnmpKitTests",
            dependencies: ["SwiftSnmpKit"]),
    ]
)
