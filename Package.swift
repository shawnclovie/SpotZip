// swift-tools-version:5.0

import PackageDescription

let package = Package(
    name: "SpotZipArchive",
    products: [
        .library(
            name: "SpotZipArchive",
            targets: ["SpotZipArchive"]),
    ],
    dependencies: [
		.package(url: "https://github.com/shawnclovie/Spot", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "SpotZipArchive",
            dependencies: ["Spot"]),
    ]
)
