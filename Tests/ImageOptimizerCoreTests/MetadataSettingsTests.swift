// MetadataSettingsTests.swift - The metadata choice: its default, the planner handing it to the encoder, and old
// saved settings still loading.

import Foundation
import Testing
@testable import ImageOptimizerCore

@Suite("Metadata settings")
struct MetadataSettingsTests {
    @Test("the default removes the location and nothing else")
    func defaultIsLocationOnly() {
        #expect(Settings().removeMetadata == [.location])
        #expect(MetadataCategory.defaultRemoved == [.location])
    }

    @Test("settings saved by an older version load, keep their values, and get the location default")
    func oldSettingsLoad() throws {
        // Exactly what 1.2.x wrote: no removeMetadata key.
        let old = #"{"encoderMode":"smallest","pngLossy":false,"outputLocation":"sameAsSource","chosenFolderPath":"","suffix":"_small","conflictPolicy":"numberIt","deleteSource":true,"preserveDates":false,"concurrency":6}"#
        let s = try JSONDecoder().decode(Settings.self, from: Data(old.utf8))
        #expect(s.encoderMode == .smallest && !s.pngLossy && s.suffix == "_small" && s.conflictPolicy == .numberIt)
        #expect(s.deleteSource && !s.preserveDates && s.concurrency == 6, "the user's other choices must not be reset")
        #expect(s.removeMetadata == [.location], "an upgrade must never start leaking the location")
    }

    @Test("a chosen set round-trips, including an empty one (keep everything)")
    func roundTrip() throws {
        for chosen in [Set<MetadataCategory>(), [.location, .dateTime], Set(MetadataCategory.allCases)] {
            var s = Settings(); s.removeMetadata = chosen
            let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
            #expect(back == s && back.removeMetadata == chosen)
        }
    }

    @Test("the planner passes the choice to the encoder")
    func plannerCarriesIt() {
        var s = Settings(); s.removeMetadata = [.location, .cameraAndLens]
        let info = ImageInfo(format: .jpeg, width: 4000, height: 3000, bitDepth: 8, fileSize: 6_000_000)
        let plan = EncodePlanner().plan(info: info, inputURL: URL(fileURLWithPath: "/tmp/a.jpg"), settings: s)
        #expect(plan.removeMetadata == [.location, .cameraAndLens])
    }

    @Test("every category has a name and an explanation for the settings window")
    func allDescribed() {
        for c in MetadataCategory.allCases { #expect(!c.displayName.isEmpty && !c.detail.isEmpty) }
    }
}
