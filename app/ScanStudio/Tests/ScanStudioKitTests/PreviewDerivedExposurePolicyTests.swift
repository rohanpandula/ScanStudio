import Testing
@testable import ScanStudioKit

@Suite("Preview-derived exposure policy")
struct PreviewDerivedExposurePolicyTests {
    private func evidence(
        _ frame: Int,
        mean: Double,
        blank: Double = 0.1,
        needsApproval: Bool = false
    ) -> PreviewDerivedExposurePolicy.Evidence {
        .init(
            frameIndex: frame,
            thumbnailMean: mean,
            thumbnailStddev: 12,
            blankConfidence: blank,
            needsApproval: needsApproval
        )
    }

    @Test("darker frames receive at most one positive EV with device clamping")
    func derivesBoundedPositiveAdjustment() throws {
        let frames = [evidence(1, mean: 100), evidence(2, mean: 25)]
        let result = try PreviewDerivedExposurePolicy.adjustments(
            evidence: frames,
            referenceFrameIndex: 1,
            referenceRGBRaw10ns: [210_000, 220_000, 400_000]
        )

        #expect(result[1]?.appliedRgbExposuresRaw10ns == [210_000, 220_000, 400_000])
        #expect(result[2]?.requestedPositiveEv == 2)
        #expect(result[2]?.appliedPositiveEv == 1)
        #expect(result[2]?.appliedRgbExposuresRaw10ns == [400_000, 400_000, 400_000])
        #expect(result[2]?.deviceBoundClampedChannels == ["R", "G", "B"])
    }

    @Test("blank or ambiguous preview evidence is refused")
    func refusesUnusableEvidence() {
        #expect(throws: PreviewDerivedExposurePolicy.Refusal.self) {
            try PreviewDerivedExposurePolicy.referenceFrame(in: [evidence(1, mean: 80, blank: 1)])
        }
        #expect(throws: PreviewDerivedExposurePolicy.Refusal.self) {
            try PreviewDerivedExposurePolicy.referenceFrame(in: [evidence(1, mean: 80, needsApproval: true)])
        }
        #expect(throws: PreviewDerivedExposurePolicy.Refusal.self) {
            try PreviewDerivedExposurePolicy.referenceFrame(in: [evidence(1, mean: 80), evidence(1, mean: 90)])
        }
    }

    @Test("preview-derived exposure refuses incompatible frame geometry")
    func refusesIncompatibleCaptureGeometry() {
        let roll = CaptureRecipe(
            resolutionDpi: 4000,
            bitDepth: 16,
            multisamplePasses: 1,
            channels: "rgbi"
        )
        let compatible = CaptureRecipe(
            resolutionDpi: 4000,
            bitDepth: 16,
            multisamplePasses: 1,
            channels: "rgbi",
            exposureOverride10ns: [100_000, 100_000, 100_000]
        )
        let incompatible = CaptureRecipe(
            resolutionDpi: 2000,
            bitDepth: 16,
            multisamplePasses: 1,
            channels: "rgbi"
        )

        #expect(PreviewDerivedExposurePolicy.hasCompatibleCaptureGeometry(compatible, with: roll))
        #expect(!PreviewDerivedExposurePolicy.hasCompatibleCaptureGeometry(incompatible, with: roll))
    }
}
