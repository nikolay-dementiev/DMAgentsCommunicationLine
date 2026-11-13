# Acceptance of v0.1

Each criterion below points at the test suites that prove it. Every suite runs with `swift test --filter <pattern>`;
`swift test` runs them all. The end-to-end suites start the real `commline` and `commline-service` programs.

| Criterion | Suites | Command |
|---|---|---|
| A clean install and uninstall in a temporary home | `InstallEndToEndTests` (real processes: install, upgrade, uninstall, uninstall with data leaves no file), `InstallerTests`, `InstallerFailureTests`, `UninstallerTests` | `swift test --filter "InstallEndToEndTests\|InstallerTests\|InstallerFailureTests\|UninstallerTests"` |
| Access-policy tests that fail on a deliberately broken policy | `AccessPolicyTests` (rules of sending and reading), `RightsServiceTests` (owner rules and grants), `DispatcherAgentTests` (an agent cannot reach what it must not) | `swift test --filter "AccessPolicyTests\|RightsServiceTests\|DispatcherAgentTests"` |
| Concurrency: many processes sending and waiting at once | `EndToEndTests` (`test_manyProcessesSendAtOnce_andFourWaitAtOnce`), `MessageConcurrencyTests`, `IdentityRaceTests` | `swift test --filter "EndToEndTests\|MessageConcurrencyTests\|IdentityRaceTests"` |
| Restart with pending mail | `EndToEndTests` (`test_afterARestart_pendingMailAndTokensSurvive`), `InstallEndToEndTests` (mail survives an upgrade and a kept store), `OwnerRecoveryTests` | `swift test --filter "EndToEndTests\|InstallEndToEndTests\|OwnerRecoveryTests"` |

## What was proven to fail

- Broken sending policy (any family may send): `AccessPolicyTests`, `RightsServiceTests`, `DispatcherAgentTests` and `EndToEndTests` all fail.
- Broken reading policy (a head reads every family): `AccessPolicyTests` and `EndToEndTests` fail.
- An uninstall that keeps the store with `--delete-data`: `InstallEndToEndTests` fails.
- A recovery that does not start the service again: `InstallEndToEndTests` fails.

The data races in the test doubles are checked with `swift test --sanitize=thread --filter "InstallerTests\|UninstallerTests\|AgentSetupTests\|OwnerRecovery\|SocketReadiness\|HostCommandTests\|InstallEndToEnd\|WaiterTests"`.
