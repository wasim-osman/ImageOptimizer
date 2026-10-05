// ImageProbeTests.swift - The probe against real files with the awkward properties that
// broke naive optimisers in the benchmark: rotated photos, wide-gamut profiles, alpha, depth.

import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ImageOptimizerCore

@Suite("ImageProbe")
struct ImageProbeTests {
    private func dir() throws -> URL { try Fixtures.makeDirectory() }

    @Test("a plain JPEG reports its format, size and absence of alpha")
    func plainJPEG() throws {
        let d = try dir()
        let url = try Fixtures.write(Fixtures.photoLike(), to: d.appendingPathComponent("a.jpg"), type: .jpeg, quality: 0.9)
        let info = try ImageProbe.probe(url: url)
        #expect(info.format == .jpeg)
        #expect(info.width == 640 && info.height == 480)
        #expect(info.orientation == 1)
        #expect(info.hasAlpha == false)
        #expect(info.colorModel == .rgb)
        #expect(info.frameCount == 1)
        #expect(info.fileSize > 0)
        #expect(info.bitsPerPixel > 0)
    }

    /// The trap that made 7 of 8 real iPhone photos display sideways in the benchmark.
    @Test("EXIF orientation is read, and display dimensions swap for 90-degree rotations",
          arguments: [1, 2, 3, 4, 5, 6, 7, 8])
    func orientation(tag: Int) throws {
        let d = try dir()
        let url = try Fixtures.write(Fixtures.cornerMarkers(), to: d.appendingPathComponent("o\(tag).jpg"), type: .jpeg,
                                     quality: 0.95, orientation: tag)
        let info = try ImageProbe.probe(url: url)
        #expect(info.orientation == tag)
        if (5...8).contains(tag) {
            #expect(info.displayWidth == info.height && info.displayHeight == info.width,
                    "orientation \(tag) is a quarter turn, so display axes must swap")
        } else {
            #expect(info.displayWidth == info.width && info.displayHeight == info.height)
        }
    }

    @Test("a Display P3 profile is detected and is not mistaken for plain sRGB")
    func wideGamutProfile() throws {
        let d = try dir()
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let url = try Fixtures.write(Fixtures.photoLike(colorSpace: p3), to: d.appendingPathComponent("p3.png"), type: .png)
        let info = try ImageProbe.probe(url: url)
        #expect(info.iccProfileName == "Display P3")
        #expect(info.isPlainSRGB == false, "dropping this profile would wash the colours out")
    }

    @Test("an sRGB image counts as plain sRGB")
    func srgbIsPlain() throws {
        let d = try dir()
        let url = try Fixtures.write(Fixtures.photoLike(), to: d.appendingPathComponent("s.png"), type: .png)
        #expect(try ImageProbe.probe(url: url).isPlainSRGB)
    }

    @Test("PNG alpha and 16-bit depth are reported")
    func alphaAndDepth() throws {
        let d = try dir()
        let url = try Fixtures.write(Fixtures.sixteenBitWithAlpha(), to: d.appendingPathComponent("a16.png"), type: .png)
        let info = try ImageProbe.probe(url: url)
        #expect(info.format == .png)
        #expect(info.hasAlpha)
        #expect(info.bitDepth == 16)
    }

    @Test("a greyscale image is reported as gray, not RGB")
    func grayscale() throws {
        let d = try dir()
        let url = try Fixtures.write(Fixtures.grayscale(), to: d.appendingPathComponent("g.jpg"), type: .jpeg, quality: 0.9)
        #expect(try ImageProbe.probe(url: url).colorModel == .gray)
    }

    @Test("a CMYK JPEG is reported as CMYK")
    func cmykDetected() throws {
        // A test that can't build its fixture must FAIL, not quietly pass having tested nothing.
        let image = try #require(Fixtures.cmyk(), "this SDK could not build a CMYK fixture")
        let d = try dir()
        let url = try Fixtures.write(image, to: d.appendingPathComponent("c.jpg"), type: .jpeg, quality: 0.9)
        #expect(try ImageProbe.probe(url: url).colorModel == .cmyk)
    }

    @Test("an animated GIF is refused as an unsupported format, by name")
    func gifRefused() throws {
        let d = try dir()
        let url = try Fixtures.animatedGIF(to: d.appendingPathComponent("anim.gif"))
        #expect(throws: ProbeError.unsupportedFormat("GIF")) { _ = try ImageProbe.probe(url: url) }
    }

    @Test("TIFF is refused by name")
    func tiffRefused() throws {
        let d = try dir()
        let url = try Fixtures.write(Fixtures.photoLike(width: 64, height: 64), to: d.appendingPathComponent("t.tiff"), type: .tiff)
        #expect(throws: ProbeError.unsupportedFormat("TIFF")) { _ = try ImageProbe.probe(url: url) }
    }

    @Test("a HEIC photo is recognised")
    func heic() throws {
        let d = try dir()
        let url = try Fixtures.write(Fixtures.photoLike(), to: d.appendingPathComponent("h.heic"), type: .heic, quality: 0.8)
        let info = try ImageProbe.probe(url: url)
        #expect(info.format == .heic)
        #expect(info.hasGainMap == false)
    }

    @Test("a non-image file is unreadable, not a crash")
    func notAnImage() throws {
        let d = try dir()
        let url = d.appendingPathComponent("notes.jpg")
        try Data("this is text, not an image".utf8).write(to: url)
        #expect(throws: ProbeError.self) { _ = try ImageProbe.probe(url: url) }
    }

    @Test("a missing file is unreadable, not a crash")
    func missing() {
        #expect(throws: ProbeError.self) {
            _ = try ImageProbe.probe(url: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).jpg"))
        }
    }

    @Test("a truncated JPEG does not crash the probe")
    func truncated() throws {
        let d = try dir()
        let good = try Fixtures.write(Fixtures.photoLike(), to: d.appendingPathComponent("good.jpg"), type: .jpeg, quality: 0.9)
        let data = try Data(contentsOf: good)
        let cut = d.appendingPathComponent("cut.jpg")
        try data.prefix(data.count / 3).write(to: cut)
        // Either a clean ProbeError or a readable-but-damaged result is acceptable; a crash is not.
        _ = try? ImageProbe.probe(url: cut)
    }
}
