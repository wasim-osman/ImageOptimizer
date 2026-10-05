// BloatGuardTests.swift - The two defences against making an image worse or no smaller.

import Foundation
import Testing
@testable import ImageOptimizerCore

@Suite("BloatGuard")
struct BloatGuardTests {
    private let guardUnderTest = BloatGuard()

    private func jpeg(bytes: Int64, width: Int = 4000, height: Int = 3000) -> ImageInfo {
        ImageInfo(format: .jpeg, width: width, height: height, fileSize: bytes)
    }

    @Test("a fat camera JPEG proceeds")
    func fatJPEGProceeds() {
        // 4000x3000 at 4 MB = 2.67 bits/pixel
        #expect(guardUnderTest.preflight(jpeg(bytes: 4_000_000), mode: .balanced) == .proceed)
    }

    @Test("an already squeezed JPEG is refused with a reason that names the numbers")
    func squeezedJPEGRefused() {
        // 4000x3000 at 900 KB = 0.6 bits/pixel
        guard case .alreadyOptimised(let reason) = guardUnderTest.preflight(jpeg(bytes: 900_000), mode: .balanced) else {
            Issue.record("expected a refusal"); return
        }
        #expect(reason.contains("0.60"), "got \(reason)")
        #expect(reason.contains("JPEG"))
    }

    @Test("floors get stricter as the target quality rises",
          arguments: [ImageFormat.jpeg, .heic])
    func floorsAreOrdered(format: ImageFormat) throws {
        let high = try #require(BloatGuard.bppFloor(format: format, mode: .highQuality))
        let balanced = try #require(BloatGuard.bppFloor(format: format, mode: .balanced))
        let smallest = try #require(BloatGuard.bppFloor(format: format, mode: .smallest))
        #expect(high > balanced && balanced > smallest,
                "a higher quality target needs more bits, so a file is 'already optimised' sooner")
    }

    @Test("PNG has no density floor, because its size depends on content rather than quality")
    func pngHasNoFloor() {
        #expect(BloatGuard.bppFloor(format: .png, mode: .balanced) == nil)
        let png = ImageInfo(format: .png, width: 4000, height: 3000, fileSize: 50_000)
        #expect(guardUnderTest.preflight(png, mode: .balanced) == .proceed)
    }

    @Test("a tiny file is refused whatever its format")
    func tinyFileRefused() {
        let png = ImageInfo(format: .png, width: 16, height: 16, fileSize: 400)
        guard case .alreadyOptimised = guardUnderTest.preflight(png, mode: .balanced) else {
            Issue.record("a 400-byte file can't be meaningfully reduced"); return
        }
    }

    @Test("an unknown size is never read as efficient")
    func unknownSizeProceeds() {
        let info = ImageInfo(format: .jpeg, width: 4000, height: 3000, fileSize: 0)
        #expect(info.bitsPerPixel == 0)
        #expect(guardUnderTest.preflight(info, mode: .balanced) == .proceed)
    }

    // MARK: - Post-flight

    @Test("a lossy result at or above 92% of the input is discarded")
    func lossyDiscarded() {
        #expect(BloatGuard.postFlightShouldDiscard(inputSize: 1000, outputSize: 920, lossless: false))
        #expect(BloatGuard.postFlightShouldDiscard(inputSize: 1000, outputSize: 1500, lossless: false),
                "a larger output is the exact failure this guard exists to prevent")
        #expect(BloatGuard.postFlightShouldDiscard(inputSize: 1000, outputSize: 919, lossless: false) == false)
    }

    /// Lossless costs no quality, so a small saving is still a saving.
    @Test("a lossless result is kept for any genuine saving")
    func losslessKeepsSmallSaving() {
        #expect(BloatGuard.postFlightShouldDiscard(inputSize: 1000, outputSize: 960, lossless: true) == false)
        #expect(BloatGuard.postFlightShouldDiscard(inputSize: 1000, outputSize: 999, lossless: true) == false)
    }

    @Test("a lossless result that isn't smaller is discarded")
    func losslessNoSavingDiscarded() {
        #expect(BloatGuard.postFlightShouldDiscard(inputSize: 1000, outputSize: 1000, lossless: true))
        #expect(BloatGuard.postFlightShouldDiscard(inputSize: 1000, outputSize: 1200, lossless: true))
    }

    @Test("an unknown input size never discards a real output")
    func unknownInputSize() {
        #expect(BloatGuard.postFlightShouldDiscard(inputSize: 0, outputSize: 500, lossless: false) == false)
    }
}
