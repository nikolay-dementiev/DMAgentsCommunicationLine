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
    .library(name: "CommunicationLineService", targets: ["CommunicationLineService"]),
    .library(name: "CommunicationLineInstall", targets: ["CommunicationLineInstall"]),
    .library(name: "CommunicationLineCLI", targets: ["CommunicationLineCLI"]),
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
    .target(
      name: "CommunicationLineService",
      dependencies: [
        "CommunicationLineDomain", "CommunicationLineApplication", "CommunicationLineStore",
        "CommunicationLineWire",
      ]
    ),
    .target(
      name: "CommunicationLineInstall",
      dependencies: ["CommunicationLineWire", "CommunicationLineStore"]
    ),
    .testTarget(
      name: "CommunicationLineInstallTests",
      dependencies: ["CommunicationLineInstall", "CommunicationLineWire"]
    ),
    .target(
      name: "CommunicationLineCLI",
      dependencies: ["CommunicationLineWire", "CommunicationLineInstall"]
    ),
    .testTarget(
      name: "CommunicationLineCLITests",
      dependencies: ["CommunicationLineCLI", "CommunicationLineWire"]
    ),
    .executableTarget(name: "commline", dependencies: ["CommunicationLineCLI"]),
    .executableTarget(
      name: "commline-service",
      dependencies: ["CommunicationLineService"]
    ),
    .testTarget(
      name: "CommunicationLineServiceTests",
      dependencies: [
        "CommunicationLineService", "CommunicationLineWire", "CommunicationLineDomain",
        "CommunicationLineApplication",
      ]
    ),
    .testTarget(
      name: "CommunicationLineWireTests",
      dependencies: ["CommunicationLineWire"]
    ),
    .testTarget(
      name: "CommunicationLineEndToEndTests",
      dependencies: [
        "commline", "commline-service", "CommunicationLineService", "CommunicationLineDomain",
      ]
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
