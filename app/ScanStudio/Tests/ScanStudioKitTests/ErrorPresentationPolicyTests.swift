import Foundation
import Testing

@testable import ScanStudioKit

@Suite("Error presentation policy")
struct ErrorPresentationPolicyTests {
    @Test("a clipped first frame asks for a deeper refeed without offering a crop")
    func leadingFrameClipped() {
        let rawMessage = "REFEED_REQUIRED: the first frame begins 17 preview rows before "
            + "the captured preview area (88.1% remains); refeed the film slightly deeper "
            + "and acquire a fresh preview. ScanStudio did not expose the cropped frame for scanning"

        let presentation = ErrorPresentationPolicy.make(lastErrorMessage: rawMessage)

        #expect(presentation.title == "The first frame is not fully inside the scanner")
        #expect(
            presentation.guidance
                == "Reinsert the film a little farther into the adapter, then preview it again. ScanStudio did not offer the cropped frame for scanning."
        )
        #expect(presentation.technicalDetails == rawMessage)
    }

    @Test("medium-not-present during batch positioning is a clear feed interruption")
    func filmFeedInterrupted() {
        let rawMessage = "FILM_FEED_INTERRUPTED: bridge scan.frameFailed "
            + "(FILM_FEED_INTERRUPTED): Film feed interrupted while positioning frame 4; "
            + "SynchronizedProtocolError: ready group 233-496: untraced sense 023a00; "
            + "terminal 000000"

        let presentation = ErrorPresentationPolicy.make(lastErrorMessage: rawMessage)

        #expect(presentation.title == "Film feed interrupted")
        #expect(
            presentation.guidance
                == "The scanner stopped detecting the film while moving to the next frame. Your finished frames are safe. Reinsert the film, acquire a fresh preview, then resume the remaining frames."
        )
        #expect(presentation.technicalDetails == rawMessage)
    }

    @Test("diagnosed scan-time transport slips require a refeed and retain the raw diagnostic")
    func scanTimeTransportSlip() {
        let diagnostics = [
            "INTERNAL: bridge scan.frameFailed (ROLL_MISMATCH): SynchronizedProtocolError: command 124: sense 045300 not in accepted ['000000']",
            "INTERNAL: bridge scan.frameFailed (FINGERPRINT_REFUSED): ProtocolError: fresh live index does not match the reviewed roll fingerprint: slot-count-mismatch",
            "INTERNAL: bridge scan.frameFailed (ROLL_MISMATCH): IndexDecodeError: transport anchor residual is inconsistent with one affine preview traversal (MAE 3.813 rows, max 7.554 rows)",
        ]

        for rawMessage in diagnostics {
            let presentation = ErrorPresentationPolicy.make(lastErrorMessage: rawMessage)

            #expect(presentation.title == "Film shifted—refeed required")
            #expect(
                presentation.guidance
                    == "The scanner lost the film’s position. Remove and firmly reinsert the strip, then acquire a fresh preview. Do not retry Capture with the current preview."
            )
            #expect(presentation.technicalDetails == rawMessage)
        }
    }

    @Test("an unrelated roll mismatch does not claim a physical transport slip")
    func unrelatedRollMismatchUsesFallback() {
        let rawMessage = "INTERNAL: bridge scan.frameFailed (ROLL_MISMATCH): calibration signature changed"
        let presentation = ErrorPresentationPolicy.make(lastErrorMessage: rawMessage)

        #expect(presentation.title == "ScanStudio could not complete that action")
        #expect(presentation.technicalDetails == rawMessage)
    }

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
                "ScanStudio could not prepare the scanner for previewing or scanning. Quit and reopen the app. If it happens again, report the issue."
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
            (
                "METER_UNUSABLE: the metering pass could not find usable image data for channel G — check film density/orientation and adapter modification; try a different process setting",
                "This film could not be metered",
                "ScanStudio couldn't find usable image data to meter this frame — the film may be too dense, upside down, or the film adapter may be modified. Check the film's density and orientation, then try a different process setting."
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
                diagnosticLogRelativePath: "~/.scanstudio/diagnostics/session-1234.jsonl",
                diagnosticLogPath: "/Users/tester/.scanstudio/diagnostics/session-1234.jsonl"
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

        // The public issue draft gets the home-relative form only -- it must
        // never disclose the local account name baked into the absolute path.
        #expect(body.contains("Local log: ~/.scanstudio/diagnostics/session-1234.jsonl"))
        #expect(!body.contains("/Users/tester"))

        #expect(presentation.technicalDetails.contains("Diagnostic session: session-1234"))
        #expect(
            presentation.technicalDetails
                .contains("Local log: /Users/tester/.scanstudio/diagnostics/session-1234.jsonl")
        )
        #expect(presentation.technicalDetails.contains("preview.failed code=NOT_CONNECTED"))
    }

    @Test("the build-identifying header always renders every field, falling back to unknown")
    func buildHeaderRendersUnknownForMissingFields() throws {
        let presentation = ErrorPresentationPolicy.make(
            lastErrorMessage: "NOT_CONNECTED: no device is open",
            context: ErrorPresentationContext(scanStudioVersion: "0.3.0-alpha.11")
        )
        let components = try #require(
            URLComponents(url: presentation.issueURL, resolvingAgainstBaseURL: false)
        )
        let body = try #require(components.queryItems?.first { $0.name == "body" }?.value)

        #expect(body.contains("ScanStudio version: 0.3.0-alpha.11"))
        #expect(body.contains("Operating system: unknown"))
        #expect(body.contains("CPU architecture: unknown"))
        #expect(body.contains("Scanner firmware: unknown"))
        #expect(body.contains("Adapter: unknown"))
        #expect(body.contains("Holder: unknown"))
        // Never silently dropped: technicalDetails renders the exact same
        // always-present header once any part of the context is populated.
        #expect(presentation.technicalDetails.contains("Scanner firmware: unknown"))
    }

    @Test("known scanner identity and holder state populate the build header")
    func buildHeaderPopulatesKnownScannerIdentity() throws {
        let presentation = ErrorPresentationPolicy.make(
            lastErrorMessage: "INTERNAL: unexpected scanner identity",
            context: ErrorPresentationContext(
                scanStudioVersion: "0.3.0-alpha.11",
                operatingSystemVersion: "macOS Version 15.4.1 (Build 24E263)",
                cpuArchitecture: "arm64",
                scannerFirmware: "1.02",
                scannerAdapter: "SA-21",
                scannerHolder: "roll36"
            )
        )
        let components = try #require(
            URLComponents(url: presentation.issueURL, resolvingAgainstBaseURL: false)
        )
        let body = try #require(components.queryItems?.first { $0.name == "body" }?.value)

        #expect(body.contains("Operating system: macOS Version 15.4.1 (Build 24E263)"))
        #expect(body.contains("CPU architecture: arm64"))
        #expect(body.contains("Scanner firmware: 1.02"))
        #expect(body.contains("Adapter: SA-21"))
        #expect(body.contains("Holder: roll36"))
    }

    @Test("both report outputs include up to the last 40 diagnostic events, not ~10")
    func reportsIncludeUpToFortyDiagnosticEvents() throws {
        // Distinct per-index timestamps (no wraparound) keep every event
        // string unique, so a substring check can never cross-match a
        // different index.
        let events = (1...50).map { "2026-08-05T00:00:00Z-\($0) event-\($0)" }
        let droppedLine = "- 2026-08-05T00:00:00Z-10 event-10"
        let survivingOldestLine = "- 2026-08-05T00:00:00Z-11 event-11"
        let survivingNewestLine = "- 2026-08-05T00:00:00Z-50 event-50"
        let presentation = ErrorPresentationPolicy.make(
            lastErrorMessage: "INTERNAL: something failed",
            context: ErrorPresentationContext(recentDiagnosticEvents: events)
        )
        let components = try #require(
            URLComponents(url: presentation.issueURL, resolvingAgainstBaseURL: false)
        )
        let body = try #require(components.queryItems?.first { $0.name == "body" }?.value)

        #expect(ErrorPresentationPolicy.maximumRecentDiagnosticEvents == 40)
        // The most recent 40 (event-11 through event-50) survive; earlier
        // ones fall off the bounded window in both outputs.
        #expect(body.contains(survivingNewestLine))
        #expect(body.contains(survivingOldestLine))
        #expect(!body.contains(droppedLine))
        #expect(presentation.technicalDetails.contains(survivingNewestLine))
        #expect(presentation.technicalDetails.contains(survivingOldestLine))
        #expect(!presentation.technicalDetails.contains(droppedLine))
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

    // MARK: - Rung 3/4 probable-cause wiring (FEEDING-UX-LADDER-OVERNIGHT-20260807.md)

    @Test("a REFEED_REQUIRED carrying a Rung-3 diagnosis surfaces its probableCause")
    func probableCauseIsExtractedThroughThePolicy() {
        let sentence = "this looks like half-frame film (frames about every 19 mm); "
            + "this driver expects standard 35 mm spacing"
        let rawMessage = "bridge error REFEED_REQUIRED: transport read was not one uniform "
            + "traversal; eject or refeed the strip and run the preview again -- if this "
            + "recurs on clean feeds it may be a capture or driver defect (transport anchor "
            + "residual is inconsistent with one affine preview traversal (MAE 4.447 rows, "
            + "max 11.241 rows) [gap-lattice-anchor] {\"probable_cause\": \"\(sentence)\"})"

        let presentation = ErrorPresentationPolicy.make(lastErrorMessage: rawMessage)

        #expect(presentation.probableCause == sentence)
        // This message names REFEED_REQUIRED but not ROLL_MISMATCH (it
        // comes from IndexDecodeError via the bridge's generic transport-
        // read wrapper, not the ROLL_MISMATCH-tagged transport-slip family
        // `FilmTransportFailurePolicy.requiresPhysicalRefeed` recognizes),
        // so it resolves through the plain REFEED_REQUIRED known-copy entry.
        #expect(presentation.title == "Film needs to be reloaded")
        #expect(presentation.technicalDetails == rawMessage)
    }

    @Test("an ordinary error without a Rung-3 diagnosis has no probableCause")
    func noProbableCauseWhenAbsent() {
        let rawMessage = "REFEED_REQUIRED: preview could not establish a usable roll session"
        let presentation = ErrorPresentationPolicy.make(lastErrorMessage: rawMessage)
        #expect(presentation.probableCause == nil)
        // Issue #16: a preview that returns REFEED_REQUIRED with low
        // confidence but no Rung-3 diagnosis is the common case, not the
        // exception -- manual placement must still be reachable here.
        #expect(presentation.canPlaceFramesManually)
    }

    @Test("a completely unrelated error never fabricates a probableCause")
    func unrelatedErrorHasNoProbableCause() {
        let presentation = ErrorPresentationPolicy.make(
            lastErrorMessage: "NOT_CONNECTED: scanner is not connected"
        )
        #expect(presentation.probableCause == nil)
        #expect(!presentation.canPlaceFramesManually)
    }

    /// S8 (adversarial review round 2, 2026-08-08): extraction must be
    /// gated on the CLASSIFIED error code, not merely on whether the raw
    /// text happens to contain a probable_cause-shaped fragment. An
    /// INTERNAL error carrying an embedded fragment -- coincidental,
    /// echoed, or adversarially crafted -- must extract nothing, and the
    /// workspace error card must therefore never offer "Place frames
    /// manually" for it.
    @Test("an INTERNAL error with an embedded probable_cause fragment extracts nothing and offers no manual-placement action")
    func internalErrorWithEmbeddedFragmentExtractsNothing() {
        let rawMessage = "INTERNAL: bridge scan.frameFailed (ROLL_MISMATCH): unexpected driver fault "
            + "[some-id] {\"probable_cause\": \"this should never surface for an INTERNAL error\"}"

        let presentation = ErrorPresentationPolicy.make(lastErrorMessage: rawMessage)

        #expect(presentation.probableCause == nil)
        #expect(presentation.title != "Film shifted—refeed required")
        #expect(presentation.title != "Film needs to be reloaded")
        #expect(!presentation.canPlaceFramesManually)
    }

    // MARK: - canPlaceFramesManually (issue #16)

    @Test("every REFEED_REQUIRED-classified refusal offers manual placement, with or without a probable cause")
    func canPlaceFramesManuallyCoversEveryReclassifiedRefeed() {
        let messages = [
            // Plain known-code REFEED_REQUIRED (noProbableCauseWhenAbsent
            // covers this one too; repeated here alongside its siblings for
            // one place that documents the full REFEED_REQUIRED family).
            "REFEED_REQUIRED: the transport index no longer matches",
            // leadingFrameClippedCopy's reclassification.
            "REFEED_REQUIRED: the first frame begins 17 preview rows before "
                + "the captured preview area (88.1% remains); refeed the film slightly deeper "
                + "and acquire a fresh preview. ScanStudio did not expose the cropped frame for scanning",
            // filmTransportSlipCopy's reclassification -- raw code is
            // INTERNAL, not REFEED_REQUIRED, and still qualifies.
            "INTERNAL: bridge scan.frameFailed (ROLL_MISMATCH): SynchronizedProtocolError: "
                + "command 124: sense 045300 not in accepted ['000000']",
        ]
        for rawMessage in messages {
            let presentation = ErrorPresentationPolicy.make(lastErrorMessage: rawMessage)
            #expect(presentation.canPlaceFramesManually, "expected true for: \(rawMessage)")
        }
    }

    @Test("codes that never resolve to REFEED_REQUIRED never offer manual placement")
    func canPlaceFramesManuallyFalseForOtherCodes() {
        let messages = [
            "NOT_CONNECTED: scanner is not connected",
            "FEEDER_PARKED: transport parked at end-stop",
            "INVALID_PARAMS: frame selection was empty",
            "BRIDGE_TIMEOUT: no terminal event arrived",
        ]
        for rawMessage in messages {
            let presentation = ErrorPresentationPolicy.make(lastErrorMessage: rawMessage)
            #expect(!presentation.canPlaceFramesManually, "expected false for: \(rawMessage)")
        }
    }
}
