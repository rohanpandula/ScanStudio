import Foundation
import Testing

@testable import ScanStudioKit

@Suite("Bundled engine policy")
struct BundledEnginePolicyTests {
    private let cli = URL(fileURLWithPath: "/Applications/ScanStudio.app/Contents/MacOS/scanstudio-cli")
    private let sibling = "/Applications/ScanStudio.app/Contents/MacOS/scanstudio-engine"

    @Test("bundled CLI resolves its sibling")
    func bundledSibling() throws {
        let result = try BundledEnginePolicy.resolve(cliExecutableURL: cli, environment: [:], engineOverride: nil, fileExists: { $0 == sibling })
        #expect(result.path == sibling)
    }

    @Test("bundled CLI accepts matching explicit and environment paths")
    func matchingOverrides() throws {
        let explicit = try BundledEnginePolicy.resolve(cliExecutableURL: cli, environment: [:], engineOverride: sibling, fileExists: { _ in true })
        let environment = try BundledEnginePolicy.resolve(cliExecutableURL: cli, environment: ["SCANSTUDIO_ENGINE_PATH": sibling], engineOverride: nil, fileExists: { _ in true })
        #expect(explicit.path == sibling)
        #expect(environment.path == sibling)
    }

    @Test("bundled CLI refuses an explicit escape")
    func refusesExplicitEscape() {
        #expect(throws: BundledEnginePolicy.BundledEngineRefusal.self) {
            try BundledEnginePolicy.resolve(cliExecutableURL: cli, environment: [:], engineOverride: "/tmp/engine", fileExists: { _ in true })
        }
    }

    @Test("bundled CLI refuses an environment escape")
    func refusesEnvironmentEscape() {
        #expect(throws: BundledEnginePolicy.BundledEngineRefusal.self) {
            try BundledEnginePolicy.resolve(cliExecutableURL: cli, environment: ["SCANSTUDIO_ENGINE_PATH": "/tmp/engine"], engineOverride: nil, fileExists: { _ in true })
        }
    }

    @Test("symlinked override resolving to sibling is accepted")
    func acceptsEquivalentSymlink() throws {
        let result = try BundledEnginePolicy.resolve(
            cliExecutableURL: cli, environment: [:], engineOverride: "/tmp/engine-link", fileExists: { _ in true },
            resolvingPath: { url in url.path == "/tmp/engine-link" ? URL(fileURLWithPath: sibling) : url }
        )
        #expect(result.path == sibling)
    }

    @Test("bundled engine symlink cannot escape the app")
    func refusesSiblingEscape() {
        #expect(throws: BundledEnginePolicy.BundledEngineRefusal.self) {
            try BundledEnginePolicy.resolve(
                cliExecutableURL: cli, environment: [:], engineOverride: nil, fileExists: { _ in true },
                resolvingPath: { url in
                    url.path.hasSuffix("scanstudio-engine") ? URL(fileURLWithPath: "/tmp/scanstudio-engine") : url
                }
            )
        }
    }

    @Test("loose development locate remains available")
    func looseLocate() throws {
        let result = try BundledEnginePolicy.resolve(cliExecutableURL: URL(fileURLWithPath: "/checkout/.build/scanstudio-cli"), environment: [:], engineOverride: nil, fileExists: { _ in false }, locateLoose: { URL(fileURLWithPath: "/checkout/engine/target/debug/scanstudio-engine") })
        #expect(result.path.contains("scanstudio-engine"))
    }

    @Test("failed loose locate gives shim guidance")
    func looseFailure() {
        do {
            _ = try BundledEnginePolicy.resolve(cliExecutableURL: URL(fileURLWithPath: "/tmp/scanstudio-cli"), environment: [:], engineOverride: nil, fileExists: { _ in false }, locateLoose: { throw EngineLocator.LocateError(message: "missing") })
            Issue.record("expected refusal")
        } catch let refusal as BundledEnginePolicy.BundledEngineRefusal {
            #expect(refusal.code == "ENGINE_NOT_BUNDLED")
            #expect(refusal.guidance.contains("install_cli_shim.sh"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
