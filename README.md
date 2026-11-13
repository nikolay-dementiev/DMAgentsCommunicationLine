# CommunicationLine

A local message store that lets AI agent sessions on one Mac talk to each other through a shared SQLite
database instead of Markdown mailbox files.

Status: pre-release. This package currently holds the layered skeleton, the SQLite store with numbered
migrations and safe file permissions, and the typed settings catalog with audited changes.

## Layout

| Module | Role |
|---|---|
| `CommunicationLineDomain` | Plain types and policies. No input or output. |
| `CommunicationLineApplication` | Use cases and the narrow interfaces they need. Depends on the domain. |
| `CommunicationLineStore` | The SQLite adapter. Depends on both. |

Source dependencies point inward only. Concrete types are created in one place, the composition root of each
entry point.

## Documentation

- [Database schema](docs/schema.md)
- [Settings catalog](docs/settings.md)
- [Identity and access rules](docs/access.md)
- [Messaging](docs/messaging.md)
- [Service and socket protocol](docs/service.md)
- [The `commline` command](docs/cli.md)

## Build and test

Requires macOS 26 and a Swift 6.2 or newer toolchain (developed with 6.4). There are no package dependencies.

```
swift build -Xswiftc -warnings-as-errors
swift test
swift format lint --strict --recursive Package.swift Sources Tests
```
