// swift-tools-version:6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftGDataXML_HTML",
    products: [
        .library(name: "SwiftGDataXML_HTML", targets: ["SwiftGDataXML_HTML"])
    ],
    targets: [
        .target(name: "libvasprintf"),
        .target(name: "SwiftGDataXML_HTML",
                dependencies: [
                    .target(name: "libvasprintf", condition: .when(platforms: [.windows])),
                ],
                cSettings: [
                    .define("LIBXML_STATIC", .when(platforms: [.windows])),
                ]),
        .testTarget(name: "SwiftGDataXML_HTMLTests", dependencies: ["SwiftGDataXML_HTML"])
    ]
)
