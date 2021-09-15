// swift-tools-version:5.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftGDataXML_HTML",
    products: [
        // Products define the executables and libraries produced by a package, and make them visible to other packages.
        .library(name: "SwiftGDataXML_HTML", targets: ["SwiftGDataXML_HTML"])
    ],
    dependencies: [
        .package(url: "https://github.com/readdle/swift-libxml.git", .branch("libxml2"))
    ],
    targets: [
        .target(name: "SwiftGDataXML_HTML"),
        .testTarget(name: "SwiftGDataXML_HTMLTests", dependencies: ["SwiftGDataXML_HTML"])
    ]
)
