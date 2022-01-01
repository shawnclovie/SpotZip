// swift-tools-version:5.0
import PackageDescription

let package = Package(
    name: "SpotZipArchive",
	platforms: [
		.macOS(.v10_11), .iOS(.v9),
	],
    products: [
        .library(
            name: "SpotZipArchive",
            targets: ["SpotZipArchive"]),
    ],
    dependencies: [
    ],
    targets: [
        .target(
            name: "SpotZipArchive",
            dependencies: []),
		.testTarget(name: "SpotZipArchiveTests", dependencies: [
			.target(name: "SpotZipArchive"),
		]),
    ]
)
