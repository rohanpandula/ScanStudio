import Foundation
import Testing

@testable import ScanStudioKit

@Suite("Error presentation policy")
struct ErrorPresentationPolicyTests {
    @Test("a preview readiness timeout explains what stopped and preserves the full diagnostic")
    func previewReadinessTimeout() throws {
        let rawMessage = """
        INTERNAL: PyCoolscanError: SynchronizedProtocolError: ready group 51-60: terminal sense 000000 not reached after 120s
        """
        let presentation = ErrorPresentationPolicy.make(lastErrorMessage: rawMessage)
        let components = try #require(
            URLComponents(url: presentation.issueURL, resolvingAgainstBaseURL: false)
        )
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )

        #expect(presentation.title == "The scanner did not detect the film")
        #expect(
            presentation.guidance
                == "ScanStudio waited 2 minutes for the film to become ready, but the scanner continued to report that no film was present. No preview was created. The scanner may have ejected the film, or the film may not be fully inserted. Check the scanner, reinsert the film if it was ejected, then try Preview once. No power cycle is needed for this error alone. If it happens again, stop and open an issue with the technical details below."
        )
        #expect(presentation.technicalDetails == rawMessage)
        #expect(query["body"]?.contains(rawMessage) == true)
    }

    @Test("another ready group does not claim that film was not detected")
    func anotherReadyGroupUsesFallback() {
        let rawMessage = """
        INTERNAL: PyCoolscanError: SynchronizedProtocolError: ready group 41-50: terminal sense 000000 not reached after 120s
        """
        let presentation = ErrorPresentationPolicy.make(lastErrorMessage: rawMessage)

        #expect(presentation.title == "ScanStudio could not complete that action")
        #expect(
            presentation.guidance
                == "Review the technical details below. If the problem continues, report the issue."
        )
        #expect(presentation.technicalDetails == rawMessage)
    }

    @Test("ready group 51 through 60 tolerates protocol whitespace")
    func previewReadinessTimeoutWhitespace() {
        let rawMessage = """
        INTERNAL: PyCoolscanError: SynchronizedProtocolError: ready group   51 - 60 : terminal sense  000000 not reached after 120 s
        """
        let presentation = ErrorPresentationPolicy.make(lastErrorMessage: rawMessage)

        #expect(presentation.title == "The scanner did not detect the film")
        #expect(presentation.guidance.contains("waited 2 minutes for the film"))
        #expect(presentation.technicalDetails == rawMessage)
    }

    @Test("known error codes get calm titles and useful recovery guidance")
    func knownCodeMappings() {
        let cases: [(String, String, String)] = [
            (
                "INTERNAL: CAPTURE_WORKER_BOOTSTRAP_FAILED: CoolscanPy import missing",
                "ScanStudio’s scanning components need repair",
                "The scanner was not moved. Update or reinstall ScanStudio, then try again."
            ),
            (
                "REFEED_REQUIRED: the transport index no longer matches",
                "Film needs to be reloaded",
                "Eject and reinsert the film, then preview it again."
            ),
            (
                "FEEDER_PARKED: transport parked at end-stop",
                "Film transport needs a restart",
                "Power-cycle the scanner before trying another film movement."
            ),
            (
                "internal: bridge error HARDWARE_LANE_BUSY: another operation owns the lane",
                "Scanner is finishing another task",
                "Wait for the current scanner operation to finish, then try again."
            ),
            (
                "HW_MOTION_NOT_ARMED: movement safeguards are not ready",
                "Scanner isn’t ready yet",
                "Moving film has to be enabled when ScanStudio starts, and it was not this time. Starting it again the usual way will not change that."
            ),
            (
                "NOT_CONNECTED: no scanner session",
                "Scanner connection was lost",
                "Reconnect ScanStudio to the scanner, then try again. You do not need to power-cycle it."
            ),
            (
                "NO_MEDIA: no film detected",
                "No film is detected",
                "Insert film, preview it, then try again."
            ),
            (
                "SCANNER_BUSY: scan job active",
                "Scanner is busy",
                "Wait for the current scan or preview to finish, then try again."
            ),
            (
                "INVALID_PARAMS: frame selection was empty",
                "These settings could not be used",
                "Review the selected frames and scan settings, then try again."
            ),
            (
                "PROJECT_NOT_FOUND: no active project",
                "Save or open a roll first",
                "Save this roll or open its existing project, then try again."
            ),
            (
                "ARCHIVE_COLLISION: an archive master already exists",
                "A master TIFF already exists",
                "Choose a different name or save location. ScanStudio will not overwrite an archive master."
            ),
        ]

        for (rawMessage, expectedTitle, expectedGuidance) in cases {
            let presentation = ErrorPresentationPolicy.make(lastErrorMessage: rawMessage)
            #expect(presentation.title == expectedTitle)
            #expect(presentation.guidance == expectedGuidance)
            #expect(presentation.technicalDetails == rawMessage)
        }
    }

    @Test("an unknown error uses a calm fallback without matching code fragments")
    func unknownFallback() {
        let rawMessage = "XNOT_CONNECTEDY: an unfamiliar subsystem failed"
        let presentation = ErrorPresentationPolicy.make(lastErrorMessage: rawMessage)

        #expect(presentation.title == "ScanStudio could not complete that action")
        #expect(
            presentation.guidance
                == "Review the technical details below. If the problem continues, report the issue."
        )
        #expect(presentation.technicalDetails == rawMessage)
    }

    @Test("an unknown leading code stays available in the safe issue text")
    func unknownCodeInIssueText() throws {
        let presentation = ErrorPresentationPolicy.make(
            lastErrorMessage: "BRIDGE_TIMEOUT: no terminal event arrived"
        )
        let components = try #require(
            URLComponents(url: presentation.issueURL, resolvingAgainstBaseURL: false)
        )
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )

        #expect(presentation.title == "ScanStudio could not complete that action")
        #expect(query["title"]?.contains("(BRIDGE_TIMEOUT)") == true)
        #expect(query["body"]?.contains("Error code: BRIDGE_TIMEOUT") == true)
    }

    @Test("the GitHub issue URL has an exact root and percent-encoded concise fields")
    func issueURL() throws {
        let rawMessage = #"INVALID_PARAMS: Crop #2 & output "Gold" could not be used"#
        let presentation = ErrorPresentationPolicy.make(
            lastErrorMessage: rawMessage,
            context: ErrorPresentationContext(
                scanStudioVersion: "0.4 alpha",
                operatingSystemVersion: "macOS 15.4 (24E214)"
            )
        )

        let components = try #require(
            URLComponents(url: presentation.issueURL, resolvingAgainstBaseURL: false)
        )
        #expect(components.scheme == "https")
        #expect(components.host == "github.com")
        #expect(
            components.path
                == "/rohanpandula/ScanStudio/issues/new"
        )
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        #expect(query["title"] == "ScanStudio: These settings could not be used (INVALID_PARAMS)")
        #expect(query["body"]?.contains("ScanStudio version: 0.4 alpha") == true)
        #expect(query["body"]?.contains("Operating system: macOS 15.4 (24E214)") == true)
        #expect(query["body"]?.contains("Error code: INVALID_PARAMS") == true)
        #expect(query["body"]?.contains(rawMessage) == true)

        let encodedURL = presentation.issueURL.absoluteString
        #expect(!encodedURL.contains(" "))
        #expect(encodedURL.contains("%23"))
        #expect(encodedURL.contains("%26"))
    }

    @Test("the issue draft and local copy include a bounded privacy-safe diagnostic timeline")
    func diagnosticTimelineInIssue() throws {
        let presentation = ErrorPresentationPolicy.make(
            lastErrorMessage: "NOT_CONNECTED: bridge error NOT_CONNECTED: no device is open",
            context: ErrorPresentationContext(
                scanStudioVersion: "0.4 alpha",
                operatingSystemVersion: "macOS 15.4",
                diagnosticSessionId: "session-1234",
                engineVersion: "0.1.0",
                connectionSummary: "uiConnected=true; deviceKind=real; previewActive=true",
                recentDiagnosticEvents: [
                    "2026-07-28T00:08:18Z device.connect.succeeded connected=true kind=real",
                    "2026-07-28T00:09:01Z preview.failed code=NOT_CONNECTED uiConnectedBefore=true",
                ],
                diagnosticLogRelativePath: "~/.scanstudio/diagnostics/session-1234.jsonl"
            )
        )
        let components = try #require(
            URLComponents(url: presentation.issueURL, resolvingAgainstBaseURL: false)
        )
        let body = try #require(
            components.queryItems?.first { $0.name == "body" }?.value
        )

        #expect(body.contains("Diagnostic session: session-1234"))
        #expect(body.contains("Engine version: 0.1.0"))
        #expect(body.contains("Connection state: uiConnected=true; deviceKind=real; previewActive=true"))
        #expect(body.contains("Recent diagnostic events:"))
        #expect(body.contains("preview.failed code=NOT_CONNECTED uiConnectedBefore=true"))
        #expect(body.contains("No images, receipts, or raw logs are attached automatically."))

        #expect(presentation.technicalDetails.contains("Diagnostic session: session-1234"))
        #expect(presentation.technicalDetails.contains("Local log: ~/.scanstudio/diagnostics/session-1234.jsonl"))
        #expect(presentation.technicalDetails.contains("preview.failed code=NOT_CONNECTED"))
    }

    @Test("issue text redacts paths and explicitly supplied private work details")
    func reportRedaction() throws {
        let privateValues = [
            "/Users/private-user/Pictures/Private Roll/manifest.json",
            "/private/var/folders/yz/session/receipt.json",
            "/var/folders/zz/cache/thumbnail.png",
            "/tmp/scanstudio-engine.log",
            "/Volumes/Archive/Family Roll",
            "/Volumes/Projects/Alice Wedding.scanstudio",
            "Kodak Gold 200",
            "Canon 7E",
            "EF 50mm f/1.8 STM",
            "coolscan3:usb:libusb:000:013",
            "SN-ABC-123",
        ]
        let rawMessage = """
        INVALID_PARAMS: project "/Users/private-user/Pictures/Private Roll/manifest.json";
        receipt=/private/var/folders/yz/session/receipt.json;
        thumbnail=/var/folders/zz/cache/thumbnail.png; log=/tmp/scanstudio-engine.log;
        save=/Volumes/Archive/Family Roll; project=/Volumes/Projects/Alice Wedding.scanstudio;
        filmStock=Kodak Gold 200; camera=Canon 7E; lens=EF 50mm f/1.8 STM;
        deviceId=coolscan3:usb:libusb:000:013; serial=SN-ABC-123
        """
        let presentation = ErrorPresentationPolicy.make(
            lastErrorMessage: rawMessage,
            context: ErrorPresentationContext(
                selectedPaths: Array(privateValues[0...5]),
                filmMetadataValues: Array(privateValues[6...8]),
                deviceIdentifiers: Array(privateValues[9...10])
            )
        )
        let components = try #require(
            URLComponents(url: presentation.issueURL, resolvingAgainstBaseURL: false)
        )
        let body = try #require(components.queryItems?.first { $0.name == "body" }?.value)

        #expect(presentation.technicalDetails == rawMessage)
        for privateValue in privateValues {
            #expect(!body.localizedCaseInsensitiveContains(privateValue))
        }
        #expect(body.contains("<redacted path>"))
        #expect(body.contains("<redacted>"))
    }

    @Test("common local paths and labeled identifiers are redacted without caller context")
    func automaticRedaction() throws {
        let privateValues = [
            "/Users/alice/Photo Work/roll.scanstudio",
            "/private/var/folders/ab/session/preview.tiff",
            "/var/folders/zz/cache/thumbnail.png",
            "/tmp/studio job/engine.log",
            "/Volumes/Film Archive/Private Roll/master.tif",
            "Ilford HP5 Plus",
            "Leica M6",
            "Summicron 50mm",
            "coolscan3:usb:libusb:000:013",
            "NK12345",
        ]
        let rawMessage = """
        INTERNAL: home="/Users/alice/Photo Work/roll.scanstudio";
        temp='/private/var/folders/ab/session/preview.tiff';
        cache=/var/folders/zz/cache/thumbnail.png; scratch="/tmp/studio job/engine.log";
        volume="/Volumes/Film Archive/Private Roll/master.tif";
        filmStock="Ilford HP5 Plus"; camera='Leica M6'; lens=Summicron 50mm;
        deviceId="coolscan3:usb:libusb:000:013"; serialNumber=NK12345
        """
        let presentation = ErrorPresentationPolicy.make(lastErrorMessage: rawMessage)
        let components = try #require(
            URLComponents(url: presentation.issueURL, resolvingAgainstBaseURL: false)
        )
        let body = try #require(components.queryItems?.first { $0.name == "body" }?.value)

        #expect(presentation.technicalDetails == rawMessage)
        for privateValue in privateValues {
            #expect(!body.localizedCaseInsensitiveContains(privateValue))
        }
        #expect(body.contains("<redacted path>"))
        #expect(body.contains("<redacted>"))
    }

    @Test("the issue body is capped while local technical details stay complete")
    func issueBodyCap() throws {
        let rawMessage = "INTERNAL: " + String(repeating: "transport detail ", count: 500)
        let presentation = ErrorPresentationPolicy.make(lastErrorMessage: rawMessage)
        let components = try #require(
            URLComponents(url: presentation.issueURL, resolvingAgainstBaseURL: false)
        )
        let body = try #require(components.queryItems?.first { $0.name == "body" }?.value)

        #expect(body.count <= ErrorPresentationPolicy.maximumIssueBodyCharacters)
        #expect(body.hasSuffix("\n[technical message truncated]"))
        #expect(presentation.technicalDetails == rawMessage)
    }
}
