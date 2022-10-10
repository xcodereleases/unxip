// swift-tools-version:5.5
import PackageDescription

let package = Package(
	name: "unxip",
	platforms: [
		.macOS(.v11)
	],
	products: [
        .library(name: "libunxip", targets: ["libunxip"]),
		.executable(name: "unxip", targets: ["unxip"])
	],
	targets: [
        .target(
            name: "libunxip",
            path: "./",
            exclude: [
                "LICENSE",
                "README.md",
            ],
            sources: ["libunxip.swift"]
        ),
		.executableTarget(
			name: "unxip",
            dependencies: ["libunxip"],
			path: "./",
			exclude: [
				"LICENSE",
				"README.md",
			],
			sources: ["unxip.swift"]
		)
	]
)
