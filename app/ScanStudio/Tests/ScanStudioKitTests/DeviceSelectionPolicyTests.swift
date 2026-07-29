import Testing

@testable import ScanStudioKit

@Suite("Device selection policy")
struct DeviceSelectionPolicyTests {
    private let simulated = DeviceInfo(
        deviceId: "sim-ls5000-0",
        model: "SUPER COOLSCAN 5000 ED",
        kind: "simulated",
        firmware: "1.0",
        connection: "usb",
        supportedMultisamplePasses: nil
    )
    private let real = DeviceInfo(
        deviceId: "coolscan3:usb:libusb:000:013",
        model: "LS-5000 ED",
        kind: "real",
        firmware: "1.0",
        connection: "usb",
        supportedMultisamplePasses: [4]
    )

    @Test("Discovery in flight suppresses connection with no devices")
    func discoveryEmpty() {
        #expect(
            DeviceSelectionPolicy.state(isDiscovering: true, devices: [])
                == .discovering
        )
    }

    @Test("Discovery in flight suppresses connection with a partial device list")
    func discoveryPartial() {
        #expect(
            DeviceSelectionPolicy.state(isDiscovering: true, devices: [simulated])
                == .discovering
        )
    }

    @Test("Discovery takes precedence over connecting and both progress messages use sentence-case scanner")
    func discoveryAndConnectionPresentation() {
        #expect(
            DeviceSelectionPolicy.state(
                isDiscovering: false,
                isConnecting: true,
                devices: [real]
            ) == .connecting
        )
        #expect(
            DeviceSelectionPolicy.state(
                isDiscovering: true,
                isConnecting: true,
                devices: [real]
            ) == .discovering
        )
        #expect(DeviceSelectionPolicy.State.discovering.progressText == "Searching for scanner…")
        #expect(DeviceSelectionPolicy.State.connecting.progressText == "Connecting to scanner…")
    }

    @Test("Completed discovery distinguishes no devices")
    func noDevices() {
        #expect(
            DeviceSelectionPolicy.state(isDiscovering: false, devices: [])
                == .noDevices
        )
    }

    @Test("A lone real scanner is an unambiguous direct connection")
    func realOnly() {
        #expect(
            DeviceSelectionPolicy.state(isDiscovering: false, devices: [real])
                == .directConnect(real)
        )
        #expect(DeviceSelectionPolicy.resolveNilTarget(devices: [real]) == real.deviceId)
        #expect(DeviceSelectionPolicy.connectLabel(for: real) == "Connect LS-5000 ED")
    }

    @Test("A lone simulator is explicit before connection")
    func simulatorOnly() {
        #expect(
            DeviceSelectionPolicy.state(isDiscovering: false, devices: [simulated])
                == .directConnect(simulated)
        )
        #expect(
            DeviceSelectionPolicy.resolveNilTarget(devices: [simulated])
                == simulated.deviceId
        )
        #expect(
            DeviceSelectionPolicy.connectLabel(for: simulated)
                == "Connect Simulator"
        )
        #expect(
            DeviceSelectionPolicy.menuLabel(for: simulated)
                == "Simulator — SUPER COOLSCAN 5000 ED"
        )
    }

    @Test("A real scanner hides the simulator and offers a direct real connection")
    func simulatorAndReal() {
        #expect(
            DeviceSelectionPolicy.state(
                isDiscovering: false,
                devices: [simulated, real]
            ) == .directConnect(real)
        )
        #expect(
            DeviceSelectionPolicy.resolveNilTarget(devices: [simulated, real]) == nil
        )
    }

    @Test("Multiple real scanners hide simulators and require an explicit real choice")
    func multipleRealScanners() {
        let simulated2 = DeviceInfo(
            deviceId: "sim-ls5000-1",
            model: "Second Simulator",
            kind: "simulated",
            firmware: "1.0",
            connection: "usb",
            supportedMultisamplePasses: nil
        )
        let real2 = DeviceInfo(
            deviceId: "real-ls5000-2",
            model: "Second Real Scanner",
            kind: "real",
            firmware: "1.0",
            connection: "usb",
            supportedMultisamplePasses: [4]
        )

        #expect(
            DeviceSelectionPolicy.connectionCandidates(
                from: [simulated, real, simulated2, real2]
            ) == [real, real2]
        )
        #expect(
            DeviceSelectionPolicy.state(
                isDiscovering: false,
                devices: [simulated, real, simulated2, real2]
            ) == .explicitChoice([real, real2])
        )
        #expect(
            DeviceSelectionPolicy.resolveNilTarget(
                devices: [simulated, real, simulated2, real2]
            ) == nil
        )
    }

    @Test("Ranking is stable inside real and simulated groups")
    func stableRanking() {
        let simulated2 = DeviceInfo(
            deviceId: "sim-ls5000-1",
            model: "Second Simulator",
            kind: "simulated",
            firmware: "1.0",
            connection: "usb",
            supportedMultisamplePasses: nil
        )
        let real2 = DeviceInfo(
            deviceId: "real-ls5000-2",
            model: "Second Real Scanner",
            kind: "real",
            firmware: "1.0",
            connection: "usb",
            supportedMultisamplePasses: [4]
        )

        #expect(
            DeviceSelectionPolicy.rank([simulated, real, simulated2, real2])
                .map(\.deviceId)
                == [real.deviceId, real2.deviceId, simulated.deviceId, simulated2.deviceId]
        )
    }

    @Test("Nil-target resolution fails closed except for exactly one explicit id")
    func nilTargetResolution() {
        #expect(DeviceSelectionPolicy.resolveNilTarget(devices: []) == nil)
        #expect(DeviceSelectionPolicy.resolveNilTarget(devices: [real]) == real.deviceId)
        #expect(DeviceSelectionPolicy.resolveNilTarget(devices: [real, simulated]) == nil)
    }
}
