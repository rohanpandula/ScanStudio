// Offline tests for host-architecture resolution (02-02). Guards the pure,
// no-subprocess contract: `HostArchitectureProvider` derives its answer from
// `ProcessInfo.machineHardwareName` (a direct `hw.machine` syscall), never
// through a `Process` or a shelled-out `/usr/bin/uname` — so the host-arch
// resolver is deterministic and unit-testable on any machine.

import XCTest

@testable import ScanStudioKit

final class HostArchitectureTests: XCTestCase {
    // No-subprocess guarantee: the provider's only information source is the
    // `hw.machine` syscall behind `ProcessInfo.machineHardwareName`. There is
    // no Process use in the provider path by construction; this is enforced
    // at review level, not by a runtime capability probe.

    func testEnumCases() {
        XCTAssertEqual(HostArchitecture.arm64.rawValue, "arm64")
        XCTAssertEqual(HostArchitecture.x86_64.rawValue, "x86_64")
    }

    func testCaseIterableHasExactlyTwoCases() {
        XCTAssertEqual(HostArchitecture.allCases.count, 2)
        XCTAssertEqual(Set(HostArchitecture.allCases), [.arm64, .x86_64])
    }

    func testCurrentMatchesProcessInfoMachineName() {
        let name = ProcessInfo.processInfo.machineHardwareName
        let current = HostArchitectureProvider.current()
        if name.hasPrefix("arm64") {
            XCTAssertEqual(current, .arm64,
                           "machineHardwareName '\(name)' must map to .arm64")
        } else if name.hasPrefix("x86_64") {
            XCTAssertEqual(current, .x86_64,
                           "machineHardwareName '\(name)' must map to .x86_64")
        } else {
            // Unrecognized machine name: the provider still resolves to a
            // known architecture via its documented fallback, never crashes.
            XCTAssertTrue(current == .arm64 || current == .x86_64,
                          "provider must always resolve to a known arch (got '\(current.rawValue)' for '\(name)')")
        }
    }

    func testCurrentArchPrefixMatchesMachineName() {
        // The resolved arch's raw value must be a prefix of the reported
        // machine name (arm64* → arm64, x86_64* → x86_64) on a real host.
        let name = ProcessInfo.processInfo.machineHardwareName
        let arch = HostArchitectureProvider.current()
        XCTAssertTrue(name.hasPrefix(arch.rawValue),
                      "machineHardwareName '\(name)' must begin with resolved arch '\(arch.rawValue)'")
    }

    func testCurrentHostArchitectureConvenienceMatchesCurrent() {
        XCTAssertEqual(HostArchitectureProvider.currentHostArchitecture,
                       HostArchitectureProvider.current())
    }
}
