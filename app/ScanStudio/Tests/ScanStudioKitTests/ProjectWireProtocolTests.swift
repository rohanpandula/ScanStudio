// Proves WireProtocol.swift's project.create/project.open/project.list
// mirror types decode the exact JSON shapes the Rust engine's manifest
// schema (domain.rs) produces (T-02-05) — a hand-written, engine-shaped
// JSON literal, not just a Swift-to-Swift round trip, so a wire-shape
// mismatch fails a test instead of failing silently at runtime. Also
// proves `ProjectCreateParams.directory` omits its wire key entirely when
// nil, matching `AcquireThumbnailsParams.frames`'s established
// omit-on-nil precedent, and that the newly-`Codable` `SimulatedFilmCarrier`
// is wire-compatible with the engine's `MediaCarrier` enum.

import Foundation
import Testing

@testable import ScanStudioKit

@Suite("Project wire protocol")
struct ProjectWireProtocolTests {
    @Test("ScannerStatus decodes motion readiness when present and stays compatible when absent")
    func scannerStatusMotionReadinessIsAdditive() throws {
        let present = try JSONDecoder().decode(
            ScannerStatus.self,
            from: Data(
                #"{"connected":true,"adapter":"SA-30","mediaLoaded":false,"carrier":null,"frameCount":null,"lamp":"stable","transport":"idle","activeJobId":null,"filmPresent":true,"motionArmed":true}"#.utf8
            )
        )
        let absent = try JSONDecoder().decode(
            ScannerStatus.self,
            from: Data(
                #"{"connected":true,"adapter":null,"mediaLoaded":false,"carrier":null,"frameCount":null,"lamp":"stable","transport":"idle","activeJobId":null}"#.utf8
            )
        )

        #expect(present.motionArmed == true)
        #expect(absent.motionArmed == nil)
    }

    @Test("roll.approve requires both the frame and exact completed preview operation")
    func rollApproveParamsEncodeExactPreviewIdentity() throws {
        let data = try JSONEncoder().encode(
            RollApproveParams(
                frameIndex: 7,
                operationId: "preview-operation-7"
            )
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["frameIndex"] as? Int == 7)
        #expect(object["operationId"] as? String == "preview-operation-7")
    }

    @Test("legacy ProcessingRecipe without software dust removal decodes as safely off")
    func legacyProcessingRecipeDefaultsSoftwareDustRemovalOff() throws {
        let data = Data(#"{"filmProcess":"bwNegative","autofocusEachFrame":true,"autoExposureEachFrame":true,"digitalIceEnabled":false,"digitalIceMode":"legacy"}"#.utf8)
        let recipe = try JSONDecoder().decode(ProcessingRecipe.self, from: data)
        #expect(recipe.softwareDustRemovalBw == false)
    }

    @Test("legacy ArchiveRecipe without enabled retains the master by default")
    func legacyArchiveRecipeDefaultsEnabled() throws {
        let archive = try JSONDecoder().decode(
            ArchiveRecipe.self,
            from: Data(#"{"filenameTemplate":"Archive_####","destination":"/Scans/Archive"}"#.utf8)
        )
        #expect(archive.enabled == true)
        #expect(archive.fullCapturePackage == true)
    }

    @Test("derivative-only WrittenOutputs decodes without an archive path")
    func derivativeOnlyWrittenOutputsDecodes() throws {
        let outputs = try JSONDecoder().decode(
            WrittenOutputs.self,
            from: Data(#"{"positivePath":"/Scans/Positive/ScanStudio1.tif","previewPath":"/Scans/Preview/ScanStudio1.jpg"}"#.utf8)
        )
        #expect(outputs.archivePath == nil)
        #expect(outputs.positivePath?.hasSuffix(".tif") == true)
        #expect(outputs.derivativeTransform == .identity)
    }

    @Test("frame geometry and receipts decode exact derivative transforms while legacy values default to identity")
    func derivativeTransformWireCompatibilityAndReceiptProvenance() throws {
        let legacyAlignment = try JSONDecoder().decode(
            FrameAlignment.self,
            from: Data(#"{"offsetRows":7,"approved":false}"#.utf8)
        )
        #expect(legacyAlignment.derivativeTransform == .identity)

        let alignment = try JSONDecoder().decode(
            FrameAlignment.self,
            from: Data(
                #"{"offsetRows":-3,"approved":true,"derivativeTransform":{"rotationDegrees":270,"horizontalMirror":true,"verticalMirror":false}}"#.utf8
            )
        )
        let expected = DerivativeTransform(
            rotationDegrees: 270,
            horizontalMirror: true,
            verticalMirror: false
        )
        #expect(alignment.derivativeTransform == expected)

        let outputs = try JSONDecoder().decode(
            WrittenOutputs.self,
            from: Data(
                #"{"archivePath":"/Archive/frame.tif","positivePath":"/Positive/frame.tif","previewPath":"/Preview/frame.jpg","derivativeTransform":{"rotationDegrees":270,"horizontalMirror":true,"verticalMirror":false}}"#.utf8
            )
        )
        #expect(outputs.archivePath == "/Archive/frame.tif")
        #expect(outputs.derivativeTransform == expected)
    }
    @Test("ProjectCreateParams omits the directory key entirely when nil")
    func createParamsOmitsDirectoryWhenNil() throws {
        let params = ProjectCreateParams(
            name: "Test",
            carrier: .roll36,
            frameCount: 36,
            filmProcess: .c41ColorNegative,
            directory: nil
        )

        let data = try JSONEncoder().encode(params)
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(value?["directory"] == nil, "an omitted directory must not serialize as a null key: \(String(data: data, encoding: .utf8) ?? "<invalid>")")
        #expect(value?["name"] as? String == "Test")
        #expect(value?["carrier"] as? String == "roll36")
        #expect(value?["frameCount"] as? Int == 36)
        #expect(value?["filmProcess"] as? String == "c41ColorNegative")
    }

    @Test("a hand-written, engine-shaped ScanProject JSON payload decodes exactly, including a nested full ScanReceipt")
    func scanProjectDecodesEngineShapedPayload() throws {
        let json = """
        {
            "schemaVersion": 1,
            "id": "proj-1",
            "name": "Kitchen Table Roll",
            "carrier": "roll36",
            "frameCount": 2,
            "filmProcess": "c41ColorNegative",
            "recipes": {
                "archive": {"filenameTemplate": "ProjectArchive_####", "destination": "/Scans/ProjectArchive"},
                "positive": {"enabled": true, "fileFormat": "tiff", "colorProfile": "sRgb", "filenameTemplate": "ProjectPositive_####", "destination": "/Scans/ProjectPositive"},
                "preview": {"enabled": true, "fileFormat": "jpeg", "maxLongEdgePx": 1024, "filenameTemplate": "ProjectPreview_####", "destination": "/Scans/ProjectPreview"}
            },
            "rollMetadata": {
                "camera": null,
                "lens": null,
                "filmStock": null,
                "process": null,
                "iso": null,
                "date": null,
                "location": null,
                "photographer": null,
                "copyright": null,
                "rollId": null,
                "frameNumber": null,
                "notes": null,
                "keywords": []
            },
            "createdAt": "2026-07-22T09:00:00Z",
            "frames": [
                {"index": 1, "excluded": false, "receipts": []},
                {
                    "index": 2,
                    "excluded": true,
                    "receipts": [
                        {
                            "jobId": "job-1",
                            "frameIndex": 2,
                            "startedAt": "2026-07-22T09:00:05Z",
                            "durationMs": 2100,
                            "passes": 2,
                            "resolutionDpi": 4000,
                            "bitDepth": 16,
                            "channels": "rgbi",
                            "engineVersion": "0.1.0",
                            "deviceId": "sim-ls5000-0",
                            "simulated": true,
                            "settingsFingerprint": "1a3d265e0b54bbd2",
                            "processing": {
                                "filmProcess": "c41ColorNegative",
                                "autofocusEachFrame": true,
                                "autoExposureEachFrame": true,
                                "digitalIceEnabled": true,
                                "digitalIceMode": "legacy"
                            },
                            "output": {
                                "archive": {"filenameTemplate": "Archive_####", "destination": "/Scans/Archive"},
                                "positive": {"enabled": true, "fileFormat": "tiff", "colorProfile": "adobeRgb1998", "filenameTemplate": "Roll_001_####", "destination": "/Scans/Roll_001"},
                                "preview": {"enabled": true, "fileFormat": "jpeg", "maxLongEdgePx": 2048, "filenameTemplate": "Preview_####", "destination": "/Scans/Preview"}
                            }
                        }
                    ]
                }
            ]
        }
        """

        let project = try JSONDecoder().decode(ScanProject.self, from: Data(json.utf8))

        #expect(project.schemaVersion == 1)
        #expect(project.id == "proj-1")
        #expect(project.name == "Kitchen Table Roll")
        #expect(project.carrier == .roll36)
        #expect(project.frameCount == 2)
        #expect(project.filmProcess == .c41ColorNegative)
        #expect(project.recipes.archive.enabled == true, "old project JSON retains its historic master behavior")
        #expect(project.recipes.archive.filenameTemplate == "ProjectArchive_####")
        #expect(project.rollMetadata == MetadataSet())
        #expect(project.createdAt == "2026-07-22T09:00:00Z")
        #expect(project.frames.count == 2)
        #expect(project.frames[0].index == 1)
        #expect(project.frames[0].excluded == false)
        #expect(project.frames[0].receipts.isEmpty)
        #expect(project.frames[1].index == 2)
        #expect(project.frames[1].excluded == true)
        #expect(project.frames[1].receipts.count == 1)

        let receipt = project.frames[1].receipts[0]
        #expect(receipt.jobId == "job-1")
        #expect(receipt.frameIndex == 2)
        #expect(receipt.startedAt == "2026-07-22T09:00:05Z")
        #expect(receipt.durationMs == 2100)
        #expect(receipt.passes == 2)
        #expect(receipt.resolutionDpi == 4000)
        #expect(receipt.bitDepth == 16)
        #expect(receipt.channels == "rgbi")
        #expect(receipt.engineVersion == "0.1.0")
        #expect(receipt.deviceId == "sim-ls5000-0")
        #expect(receipt.simulated == true)
        #expect(receipt.settingsFingerprint == "1a3d265e0b54bbd2")
        #expect(receipt.processing?.filmProcess == .c41ColorNegative)
        #expect(receipt.processing?.digitalIceMode == .legacy)
        #expect(receipt.output?.positive.fileFormat == .tiff)
        #expect(receipt.output?.positive.colorProfile == .adobeRgb1998)
        #expect(receipt.output?.positive.destination == "/Scans/Roll_001")
        #expect(receipt.output?.archive.filenameTemplate == "Archive_####")
    }

    @Test("SimulatedFilmCarrier round-trips through JSONEncoder/JSONDecoder as its exact wire string")
    func simulatedFilmCarrierRoundTripsAsWireString() throws {
        for (carrier, wire) in [
            (SimulatedFilmCarrier.roll36, "roll36"),
            (SimulatedFilmCarrier.strip6, "strip6"),
            (SimulatedFilmCarrier.mounted, "mounted"),
        ] {
            let data = try JSONEncoder().encode(carrier)
            #expect(String(data: data, encoding: .utf8) == "\"\(wire)\"")

            let decoded = try JSONDecoder().decode(SimulatedFilmCarrier.self, from: Data("\"\(wire)\"".utf8))
            #expect(decoded == carrier)
        }
    }

    @Test("a full ScanProject value round-trips through JSONEncoder/JSONDecoder and remains equal to the original")
    func scanProjectRoundTripsAndRemainsEqual() throws {
        let original = ScanProject(
            schemaVersion: 1,
            id: "proj-2",
            name: "Strip Test",
            carrier: .strip6,
            frameCount: 1,
            filmProcess: .bwNegative,
            recipes: OutputRecipe(
                archive: ArchiveRecipe(filenameTemplate: "Archive_####", destination: "/Scans/Archive"),
                positive: PositiveRecipe(
                    enabled: true,
                    fileFormat: .tiff,
                    colorProfile: .adobeRgb1998,
                    filenameTemplate: "Positive_####",
                    destination: "/Scans/Positive"
                ),
                preview: PreviewRecipe(
                    enabled: true,
                    fileFormat: .jpeg,
                    maxLongEdgePx: 2_048,
                    filenameTemplate: "Preview_####",
                    destination: "/Scans/Preview"
                )
            ),
            rollMetadata: MetadataSet(camera: "Nikon F100", date: .yearOnly(year: 2026)),
            createdAt: "2026-07-23T12:00:00Z",
            frames: [
                ProjectFrame(
                    index: 1,
                    excluded: false,
                    receipts: [
                        ScanReceipt(
                            jobId: "job-9",
                            frameIndex: 1,
                            startedAt: "2026-07-23T12:00:01Z",
                            durationMs: 1_500,
                            passes: 1,
                            resolutionDpi: 4_000,
                            bitDepth: 16,
                            channels: "rgb",
                            engineVersion: "0.1.0",
                            deviceId: "sim-ls5000-0",
                            simulated: true,
                            settingsFingerprint: "0000000000000000",
                            processing: nil,
                            output: nil,
                            outputs: nil,
                            rgbPath: nil,
                            irPath: nil,
                            meterRgbiPath: nil,
                            hardwareTelemetry: nil
                        )
                    ]
                )
            ]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScanProject.self, from: data)

        #expect(decoded == original)
    }

    @Test("a hand-written, engine-shaped AnalyzeFrameDefectsResult JSON payload decodes exactly, including omitted endX/endY for dust and present endX/endY for scratch")
    func analyzeFrameDefectsResultDecodesEngineShapedPayload() throws {
        let json = """
        {
            "frameIndex": 7,
            "defects": [
                {
                    "id": 1,
                    "kind": "dust",
                    "severity": 0.42,
                    "classification": "willCorrect",
                    "centerX": 0.25,
                    "centerY": 0.61,
                    "radius": 0.015
                },
                {
                    "id": 2,
                    "kind": "scratch",
                    "severity": 0.83,
                    "classification": "uncertain",
                    "centerX": 0.10,
                    "centerY": 0.20,
                    "radius": 0.004,
                    "endX": 0.30,
                    "endY": 0.55
                }
            ],
            "simulated": true,
            "digitalIceEnabled": true,
            "transportSmearFlagged": true,
            "transportSmearReason": "streak visible in infrared channel"
        }
        """

        let result = try JSONDecoder().decode(AnalyzeFrameDefectsResult.self, from: Data(json.utf8))

        #expect(result.frameIndex == 7)
        #expect(result.simulated == true)
        #expect(result.digitalIceEnabled == true)
        #expect(result.transportSmearFlagged == true)
        #expect(result.transportSmearReason == "streak visible in infrared channel")
        #expect(result.defects.count == 2)

        let dust = result.defects[0]
        #expect(dust.id == 1)
        #expect(dust.kind == .dust)
        #expect(dust.severity == 0.42)
        #expect(dust.classification == .willCorrect)
        #expect(dust.centerX == 0.25)
        #expect(dust.centerY == 0.61)
        #expect(dust.radius == 0.015)
        #expect(dust.endX == nil)
        #expect(dust.endY == nil)

        let scratch = result.defects[1]
        #expect(scratch.id == 2)
        #expect(scratch.kind == .scratch)
        #expect(scratch.severity == 0.83)
        #expect(scratch.classification == .uncertain)
        #expect(scratch.centerX == 0.10)
        #expect(scratch.centerY == 0.20)
        #expect(scratch.radius == 0.004)
        #expect(scratch.endX != nil)
        #expect(scratch.endY != nil)
        #expect(scratch.endX == 0.30)
        #expect(scratch.endY == 0.55)

        let nullReasonJSON = """
        {
            "frameIndex": 8,
            "defects": [],
            "simulated": false,
            "digitalIceEnabled": true,
            "transportSmearFlagged": false,
            "transportSmearReason": null
        }
        """
        let nullReasonResult = try JSONDecoder().decode(AnalyzeFrameDefectsResult.self, from: Data(nullReasonJSON.utf8))
        #expect(nullReasonResult.frameIndex == 8)
        #expect(nullReasonResult.simulated == false)
        #expect(nullReasonResult.digitalIceEnabled == true)
        #expect(nullReasonResult.transportSmearFlagged == false)
        #expect(nullReasonResult.transportSmearReason == nil)
    }

    @Test("AnalyzeFrameDefectsParams encodes frameIndex/capture/processing correctly shaped")
    func analyzeFrameDefectsParamsEncodesCorrectShape() throws {
        let params = AnalyzeFrameDefectsParams(
            frameIndex: 12,
            capture: CaptureRecipe(resolutionDpi: 4_000, bitDepth: 16, multisamplePasses: 2, channels: "rgbi"),
            processing: ProcessingRecipe(
                filmProcess: .c41ColorNegative,
                autofocusEachFrame: true,
                autoExposureEachFrame: true,
                digitalIceEnabled: true,
                digitalIceMode: .legacy
            )
        )

        let data = try JSONEncoder().encode(params)
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(value?["frameIndex"] as? Int == 12)

        let capture = value?["capture"] as? [String: Any]
        #expect(capture?["resolutionDpi"] as? Int == 4_000)
        #expect(capture?["bitDepth"] as? Int == 16)
        #expect(capture?["multisamplePasses"] as? Int == 2)
        #expect(capture?["channels"] as? String == "rgbi")

        let processing = value?["processing"] as? [String: Any]
        #expect(processing?["filmProcess"] as? String == "c41ColorNegative")
        #expect(processing?["autofocusEachFrame"] as? Bool == true)
        #expect(processing?["autoExposureEachFrame"] as? Bool == true)
        #expect(processing?["digitalIceEnabled"] as? Bool == true)
        #expect(processing?["digitalIceMode"] as? String == "legacy")
    }

    // MARK: - PartialDate / MetadataSet (META-01)

    @Test("PartialDate.exact decodes the engine's internally-tagged JSON shape and round-trips")
    func partialDateExactRoundTrips() throws {
        let json = #"{"kind":"exact","date":"2026-07-22"}"#
        let decoded = try JSONDecoder().decode(PartialDate.self, from: Data(json.utf8))
        #expect(decoded == .exact(date: "2026-07-22"))

        let reencoded = try JSONEncoder().encode(decoded)
        let originalObject = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary
        let reencodedObject = try JSONSerialization.jsonObject(with: reencoded) as? NSDictionary
        #expect(reencodedObject == originalObject)
    }

    @Test("PartialDate.monthOnly decodes the engine's internally-tagged JSON shape and round-trips")
    func partialDateMonthOnlyRoundTrips() throws {
        let json = #"{"kind":"monthOnly","year":2026,"month":7}"#
        let decoded = try JSONDecoder().decode(PartialDate.self, from: Data(json.utf8))
        #expect(decoded == .monthOnly(year: 2026, month: 7))

        let reencoded = try JSONEncoder().encode(decoded)
        let originalObject = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary
        let reencodedObject = try JSONSerialization.jsonObject(with: reencoded) as? NSDictionary
        #expect(reencodedObject == originalObject)
    }

    @Test("PartialDate.yearOnly decodes the engine's internally-tagged JSON shape and round-trips")
    func partialDateYearOnlyRoundTrips() throws {
        let json = #"{"kind":"yearOnly","year":2026}"#
        let decoded = try JSONDecoder().decode(PartialDate.self, from: Data(json.utf8))
        #expect(decoded == .yearOnly(year: 2026))

        let reencoded = try JSONEncoder().encode(decoded)
        let originalObject = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary
        let reencodedObject = try JSONSerialization.jsonObject(with: reencoded) as? NSDictionary
        #expect(reencodedObject == originalObject)
    }

    @Test("PartialDate.unknown decodes the engine's internally-tagged JSON shape and round-trips")
    func partialDateUnknownRoundTrips() throws {
        let json = #"{"kind":"unknown"}"#
        let decoded = try JSONDecoder().decode(PartialDate.self, from: Data(json.utf8))
        #expect(decoded == .unknown)

        let reencoded = try JSONEncoder().encode(decoded)
        let originalObject = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary
        let reencodedObject = try JSONSerialization.jsonObject(with: reencoded) as? NSDictionary
        #expect(reencodedObject == originalObject)
    }

    @Test("a fully-populated MetadataSet round-trips through JSONEncoder/JSONDecoder unchanged")
    func metadataSetFullyPopulatedRoundTrips() throws {
        let original = MetadataSet(
            camera: "Nikon F100",
            lens: "50mm f/1.4",
            filmStock: "Portra 400",
            process: .c41ColorNegative,
            iso: 400,
            date: .monthOnly(year: 2026, month: 7),
            location: "Home",
            photographer: "Rohan",
            copyright: "\u{00A9} 2026 Rohan",
            rollId: "roll-42",
            frameNumber: 12,
            notes: "Overcast light",
            keywords: ["family", "backyard"]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MetadataSet.self, from: data)

        #expect(decoded == original)
    }

    @Test("a MetadataSet with every optional field nil round-trips and omits every nil-optional key while still encoding an empty keywords array")
    func metadataSetEmptyRoundTripsAndOmitsNilKeys() throws {
        let original = MetadataSet()

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MetadataSet.self, from: data)
        #expect(decoded == original)

        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let optionalKeys = [
            "camera", "lens", "filmStock", "process", "iso", "date",
            "location", "photographer", "copyright", "rollId", "frameNumber", "notes",
        ]
        for key in optionalKeys {
            #expect(value?[key] == nil, "\(key) must be omitted, not encoded as null")
        }
        #expect(value?["keywords"] as? [String] == [])
    }
}
