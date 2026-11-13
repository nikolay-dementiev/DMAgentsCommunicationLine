// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "CommunicationLine",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "CommunicationLineDomain", targets: ["CommunicationLineDomain"]),
    .library(name: "CommunicationLineApplication", targets: ["CommunicationLineApplication"]),
    .library(name: "CommunicationLineStore", targets: ["CommunicationLineStore"]),
    .library(name: "CommunicationLineWire", targets: ["CommunicationLineWire"]),
  ],
  targets: [
    .target(name: "CommunicationLineDomain"),
    .target(
      name: "CommunicationLineApplication",
      dependencies: ["CommunicationLineDomain"]
    ),
    .target(
      name: "CommunicationLineStore",
      dependencies: ["CommunicationLineDomain", "CommunicationLineApplication"],
      resources: [.copy("Resources/settings-defaults.json")]
    ),
    .target(name: "CommunicationLineWire"),
    .testTarget(
      name: "CommunicationLineWireTests",
      dependencies: ["CommunicationLineWire"]
    ),
    .testTarget(
      name: "CommunicationLineDomainTests",
      dependencies: ["CommunicationLineDomain"]
    ),
    .testTarget(
      name: "CommunicationLineApplicationTests",
      dependencies: ["CommunicationLineApplication", "CommunicationLineDomain"]
    ),
    .testTarget(
      name: "CommunicationLineStoreTests",
      dependencies: [
        "CommunicationLineStore", "CommunicationLineApplication", "CommunicationLineDomain",
      ]
    ),
  ]
)
