import Foundation
import Testing

@testable import ScanStudioKit

@Suite("Capture workflow support")
struct CaptureWorkflowSupportTests {
    @Test("curated stocks set their documented process and box speed")
    func curatedStockMapping() {
        let portra = try! #require(FilmStock.matching(metadataName: "Kodak Portra 400"))
        #expect(portra.process == .c41ColorNegative)
        #expect(portra.boxSpeedIso == 400)

        let xp2 = try! #require(FilmStock.matching(metadataName: "Ilford XP2 Super"))
        #expect(xp2.process == .c41ColorNegative)
        #expect(xp2.boxSpeedIso == 400)
    }

    @Test("filename tokens are safe and legacy hash runs survive")
    func filenameExpansion() {
        #expect(FilenameTemplate.defaultTemplate == "ScanStudio#")
        let metadata = MetadataSet(
            camera: "Canon 7E",
            lens: "EF 50mm f/1.8 STM",
            filmStock: "Kodak Gold 200",
            date: .exact(date: "2026-07-27")
        )
        #expect(FilenameTemplate.expand("$FilmStock-$Camera-$Lens-$Month-$Day-$Year-$Frame", metadata: metadata, frameIndex: 3) == "KodakGold200-Canon7E-EF50mmF1.8STM-07-27-2026-0003")
        #expect(FilenameTemplate.expand("Archive_####", metadata: metadata, frameIndex: 3) == "Archive_####")
        #expect(FilenameTemplate.expand("$Year-$Month-$Day", metadata: MetadataSet(), frameIndex: 1) == "UnknownYear-UnknownMonth-UnknownDay")
        #expect(FilenameTemplate.expand("$Year-$Month-$Day", metadata: MetadataSet(date: .monthOnly(year: 2026, month: 7)), frameIndex: 1) == "2026-07-UnknownDay")
    }

    @Test("recent gear ranks matching lenses and removal stays per-user")
    func recentGearOrderingAndRemoval() {
        var history = RecentGearHistory()
        history.remember(camera: "Nikon F3", lens: "50mm")
        history.remember(camera: "Canon 7E", lens: "EF 50mm")
        history.remember(camera: "Canon 7E", lens: "EF 85mm")
        #expect(history.recentLenses(for: "Canon 7E") == ["EF 85mm", "EF 50mm", "50mm"])
        history.removeLens("EF 50mm")
        #expect(!history.recentLenses(for: "Canon 7E").contains("EF 50mm"))
        history.remember(camera: "Partial", lens: nil)
        #expect(history.lastUsed?.camera == "Canon 7E")
    }

    @Test("shared save location derives separate folders and prevents TIFF aliasing when shared")
    func destinationAndCollisionPolicy() {
        #expect(OutputDestination.destination(base: "/Scans", subfolder: "Master TIFF", fallback: "/fallback") == "/Scans/Master TIFF")
        #expect(OutputNamingTemplate.template(FilenameTemplate.defaultTemplate, roleSuffix: "Master", separateFolders: false).hasSuffix("-Master"))
        #expect(OutputNamingTemplate.template(FilenameTemplate.defaultTemplate, roleSuffix: "Positive", separateFolders: false).hasSuffix("-Positive"))
        #expect(OutputNamingTemplate.template("Film-Master-Positive", roleSuffix: "Master", separateFolders: false) == "Film-Master-Positive-Master")
        #expect(OutputNamingTemplate.template("Film-Master", roleSuffix: "Master", separateFolders: false) == "Film-Master")
    }

    @Test("output location is presented as ready by default and custom only when deliberately changed")
    func outputLocationPresentation() {
        #expect(OutputLocationPresentation.summary(
            hasOpenProject: false,
            customLocation: ""
        ) == "Save Roll creates the project and sets up default output locations automatically.")
        #expect(!OutputLocationPresentation.showsChangeAction(hasOpenProject: false))

        #expect(OutputLocationPresentation.summary(
            hasOpenProject: true,
            customLocation: ""
        ) == "Ready: every enabled output already has a save location. Changing it is optional.")
        #expect(OutputLocationPresentation.showsChangeAction(hasOpenProject: true))

        #expect(OutputLocationPresentation.summary(
            hasOpenProject: true,
            customLocation: "  /Volumes/Film Scans  "
        ) == "Custom output location:\n/Volumes/Film Scans")
    }

    @Test("output retention allows enabling any output but never disabling the last one")
    func outputRetentionPolicy() {
        #expect(OutputRetentionPolicy.allowsChange(
            .archive,
            to: false,
            archiveEnabled: true,
            positiveEnabled: false,
            previewEnabled: false
        ) == false)
        #expect(OutputRetentionPolicy.allowsChange(
            .positive,
            to: false,
            archiveEnabled: true,
            positiveEnabled: true,
            previewEnabled: false
        ))
        #expect(OutputRetentionPolicy.allowsChange(
            .preview,
            to: true,
            archiveEnabled: false,
            positiveEnabled: false,
            previewEnabled: false
        ))
    }

    @Test("recipe presets respect real-device multisample limits and expose manual changes as custom")
    func recipePolicy() {
        let masterOnly = try! #require(ScanRecipePolicy.values(for: .masterOnly, filmProcess: .c41ColorNegative, supportedMultisamplePasses: [4]))
        #expect(masterOnly.multisamplePasses == 4)
        #expect(masterOnly.positiveTiff == false)
        #expect(masterOnly.positiveJPEG == false)

        let bw = try! #require(ScanRecipePolicy.values(for: .masterTiffJpeg, filmProcess: .bwNegative, supportedMultisamplePasses: [4]))
        #expect(bw.channels == "rgb")
        #expect(bw.digitalIce == false)

        var edited = masterOnly
        edited.bitDepth = 8
        #expect(ScanRecipePolicy.preset(matching: edited, filmProcess: .c41ColorNegative, supportedMultisamplePasses: [4]) == .custom)
    }
}
