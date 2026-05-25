// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "OkBrainCC",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "OkBrainCC", targets: ["OkBrainCC"])
  ],
  targets: [
    .executableTarget(name: "OkBrainCC")
  ]
)
