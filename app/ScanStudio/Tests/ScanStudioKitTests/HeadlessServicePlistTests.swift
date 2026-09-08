import Foundation
import Testing
@testable import ScanStudioKit

@Test("Headless service serializes literal paths and never retries a hardware host")
func headlessServicePlistContract() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("service-plist-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = root.appendingPathComponent("Scan Studio & QA.app")
    let bin = bundle.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    for name in ["scanstudio-cli", "scanstudio-engine"] {
        let file = bin.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    }
    let socket = root.appendingPathComponent("private/control.sock").path
    let log = root.appendingPathComponent("private/logs/host.log").path
    let data = try HeadlessServicePlist.data(bundle: bundle, socket: socket, log: log)
    let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    #expect(plist["ProgramArguments"] as? [String] == [bin.appendingPathComponent("scanstudio-cli").path, "host", "run", "--socket", socket, "--log", log])
    #expect(plist["KeepAlive"] as? Bool == false)
    #expect(plist["Umask"] as? Int == 0o077)
    #expect(plist["Label"] as? String == HeadlessServicePlist.label)
    #expect(throws: (any Error).self) {
        try HeadlessServicePlist.data(bundle: bundle, socket: "relative.sock", log: log)
    }
}
