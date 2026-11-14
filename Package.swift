// swift-tools-version:6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftGDataXML_HTML",
    products: [
        .library(name: "SwiftGDataXML_HTML", targets: ["SwiftGDataXML_HTML"])
    ],
    dependencies: [
        .package(url: "https://github.com/readdle/swift-libxml.git", branch: "libxml2-unix")
    ],
    targets: [
        .target(
            name: "SwiftGDataXML_HTML",
            dependencies: [
                .product(name: "libxml", package: "swift-libxml", condition: .when(platforms: [.linux]))
            ]
        ),
        .testTarget(name: "SwiftGDataXML_HTMLTests", dependencies: ["SwiftGDataXML_HTML"])
    ],
    swiftLanguageModes: [.v5]
)
