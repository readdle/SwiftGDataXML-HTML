// swift-tools-version:6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftGDataXML_HTML",
    products: [
        .library(name: "SwiftGDataXML_HTML", targets: ["SwiftGDataXML_HTML"])
    ],
    targets: [
        .target(name: "SwiftGDataXML_HTML"),
        .testTarget(name: "SwiftGDataXML_HTMLTests", dependencies: ["SwiftGDataXML_HTML"])
    ],
    swiftLanguageModes: [.v5]
)
