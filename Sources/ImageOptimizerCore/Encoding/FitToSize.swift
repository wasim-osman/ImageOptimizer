// FitToSize.swift - "Fit to size": keeps shrinking until the file is no bigger than a target (Discord's 10 MB).
//
// Two levers, used in this order because quality loss is gentler than losing pixels:
//  1. Quality, searched finely (JPEG distance, HEIC quality, PNG colours) at full resolution.
//  2. Resolution, when quality alone can't get there. Size is roughly a power of the longer side, so each trial
//     predicts the next side from the last result and the loop homes in on the largest side that still fits.
// A GIF only has the second lever that works (a panning screen recording changes every pixel of every frame, so
// lossy compression saves almost nothing), so it goes straight to the resolution search.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension ImageEncoder {
    /// Shortest longer side a fit is allowed to shrink to before giving up, per format.
    static func fitFloor(_ format: ImageFormat) -> Int { format == .gif ? 120 : 200 }

    /// Finds the largest `side` whose `trial(side)` result is no bigger than `target`, calling `trial` as few times as
    /// it can. `trial` writes its candidate itself and returns its size; a candidate that doesn't fit may return any
    /// size above the target. `minFill` stops the search once a result uses at least that share of the target.
    static func fitSide(
        start: Int, floor: Int, ceiling: Int, target: Int64, aim: Double = 0.93, minFill: Double,
        trial: (Int) async throws -> Int64
    ) async throws -> (side: Int, bytes: Int64)? {
        var fit: (side: Int, bytes: Int64)?          // the largest side known to fit
        var failSide = Int.max                       // the smallest side known not to fit
        var points: [(x: Double, y: Double)] = []    // (log side, log bytes), to learn the exponent
        var exponent = 1.7                           // measured: GIF size ~ side^1.7
        var side = min(max(start, floor), ceiling)
        for _ in 0..<14 {
            try Task.checkCancellation(or: EncodeError.cancelled)
            let bytes = try await trial(side)
            if bytes <= target {
                if fit == nil || side > fit!.side { fit = (side, bytes) }
                if side >= ceiling || Double(bytes) >= minFill * Double(target) { return fit }
            } else {
                failSide = min(failSide, side)
                if side <= floor { return fit }
            }
            points.append((log(Double(side)), log(Double(max(1, bytes)))))
            if points.count >= 2 {
                let a = points[points.count - 2], b = points[points.count - 1]
                if abs(b.x - a.x) > 0.02 { exponent = min(3, max(0.8, (b.y - a.y) / (b.x - a.x))) }
            }
            var next = Int((Double(side) * pow(Double(target) * aim / Double(max(1, bytes)), 1 / exponent)).rounded())
            let lo = fit?.side ?? (floor - 1)
            let hi = min(failSide, ceiling + 1)
            if hi - lo <= 1 + lo / 100 { return fit }                // closed in on the edge
            if bytes > target { next = min(next, Int(Double(side) * 0.96)) }   // a miss always shrinks
            if next <= lo || next >= hi { next = (lo + hi) / 2 }
            side = max(floor, min(ceiling, next))
        }
        return fit
    }

    func runFitToSize(
        target limit: Int64, lossyPNG: Bool, info: ImageInfo, input: URL, output: URL, work: URL,
        report: inout EncodeReport, onProgress: (@Sendable (Double) -> Void)?
    ) async throws {
        // Leave room for the metadata the user chose to keep (about 7 KB on a phone photo), so it needn't be dropped.
        let target = info.format == .gif ? limit : limit - min(limit / 50, 100_000)
        let longer = max(info.displayWidth, info.displayHeight)
        let floor = Self.fitFloor(info.format)
        let ext = Self.fitExtension(info.format)
        func cand(_ side: Int) -> URL { work.appendingPathComponent("cand-\(side).\(ext)") }
        var trials = 0
        func tick() { trials += 1; onProgress?(min(0.95, Double(trials) / 8)) }
        /// A side at or above the original means "don't resize".
        func capped(_ side: Int) -> Int? { side >= longer ? nil : side }

        var start = longer
        let trial: (Int) async throws -> Int64
        let minFill: Double
        switch info.format {
        case .jpeg, .raw:
            minFill = 0.75
            trial = { side in
                let pixels = try await Task.detached(priority: .utility) { try PixelExtractor.extract(url: input, info: info, maxSide: capped(side)) }.value
                try Task.checkCancellation(or: EncodeError.cancelled)
                defer { tick() }
                return try await self.bisectJPEG(pixels: pixels, target: target, work: work, dest: cand(side))
            }
        case .heic:
            minFill = 0.75
            trial = { side in
                defer { tick() }
                return try await self.bisectHEIC(input: input, orientation: info.orientation, maxSide: capped(side), target: target, work: work, dest: cand(side))
            }
        case .png:
            minFill = 0.75
            trial = { side in
                defer { tick() }
                return try await self.fitPNG(input: input, maxSide: capped(side), lossy: lossyPNG, target: target, work: work, dest: cand(side))
            }
        case .gif:
            minFill = 0.8
            // Skip the full-size run: a file needing far more than a trim is not going to fit without resizing, and a
            // full-size trial of a huge GIF is the slowest thing in the whole search.
            let ratio = Double(target) * 0.93 / Double(max(1, info.fileSize))
            start = max(floor, min(longer, Int(Double(longer) * pow(min(1, ratio), 1 / 1.7))))
            trial = { side in
                defer { tick() }
                _ = try await self.runGifsicle(input: input, output: cand(side), lossy: 40, maxSide: side, frames: info.frameCount, work: work)
                return Self.fileBytes(cand(side))
            }
        }
        guard let best = try await Self.fitSide(start: start, floor: floor, ceiling: longer, target: target, minFill: minFill, trial: trial) else {
            throw EncodeError.encodeFailed("couldn't get this under \(EncodePlanner.megabytes(limit)) even shrunk to \(floor) px. Try a larger target size.")
        }
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: cand(best.side), to: output)
        let size = EncodePlanner.megabytes(best.bytes)
        report.notes.append(best.side < longer
            ? "Fitted under \(EncodePlanner.megabytes(limit)) (\(size)) by shrinking to \(best.side) px on the longer side."
            : "Fitted under \(EncodePlanner.megabytes(limit)) (\(size)) at full size, by adjusting quality.")
    }

    static func fitExtension(_ format: ImageFormat) -> String {
        switch format {
        case .jpeg, .raw: return "jpg"
        case .png: return "png"
        case .heic: return "heic"
        case .gif: return "gif"
        }
    }

    // MARK: - JPEG

    /// The best quality (lowest jpegli distance) that fits, written to `dest`. Returns the size at the worst
    /// quality tried when nothing fits, so the caller knows to shrink the picture.
    func bisectJPEG(pixels: DecodedPixels, target: Int64, work: URL, dest: URL) async throws -> Int64 {
        let attempt = work.appendingPathComponent("attempt-\(dest.lastPathComponent)")
        let best = work.appendingPathComponent("best-\(dest.lastPathComponent)")
        func encode(_ distance: Double) async throws -> Int64 {
            try Task.checkCancellation(or: EncodeError.cancelled)
            try await encodeJPEGLI(pixels: pixels, distance: distance, chroma: distance > 1.2 ? "420" : nil, output: attempt, work: work)
            return Self.fileBytes(attempt)
        }
        func keep() { try? FileManager.default.removeItem(at: best); try? FileManager.default.moveItem(at: attempt, to: best) }
        var (low, high) = (0.4, 4.0)       // low = nicest we'd use, high = ugliest we'd accept
        var bytes = try await encode(low)
        if bytes <= target { keep() } else {
            bytes = try await encode(high)
            if bytes > target { try? FileManager.default.removeItem(at: dest); try FileManager.default.moveItem(at: attempt, to: dest); return bytes }
            keep()
            // `low` doesn't fit and `high` does; close in on the nicest distance that fits.
            for _ in 0..<7 {
                let mid = (low * high).squareRoot()
                let size = try await encode(mid)
                if size <= target { high = mid; bytes = size; keep() } else { low = mid }
            }
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: best, to: dest)
        return Self.fileBytes(dest)
    }

    // MARK: - HEIC

    func bisectHEIC(input: URL, orientation: Int, maxSide: Int?, target: Int64, work: URL, dest: URL) async throws -> Int64 {
        let attempt = work.appendingPathComponent("attempt-\(dest.lastPathComponent)")
        let best = work.appendingPathComponent("best-\(dest.lastPathComponent)")
        func encode(_ quality: Double) async throws -> Int64 {
            try Task.checkCancellation(or: EncodeError.cancelled)
            try? FileManager.default.removeItem(at: attempt)
            try await runHEIC(input: input, output: attempt, quality: quality, orientation: orientation, maxSide: maxSide)
            return Self.fileBytes(attempt)
        }
        func keep() { try? FileManager.default.removeItem(at: best); try? FileManager.default.moveItem(at: attempt, to: best) }
        var (low, high) = (0.2, 0.85)      // low = ugliest we'd accept, high = nicest we'd use
        var bytes = try await encode(high)
        if bytes <= target { keep() } else {
            bytes = try await encode(low)
            if bytes > target { try? FileManager.default.removeItem(at: dest); try FileManager.default.moveItem(at: attempt, to: dest); return bytes }
            keep()
            for _ in 0..<6 {
                let mid = (low + high) / 2
                let size = try await encode(mid)
                if size <= target { low = mid; bytes = size; keep() } else { high = mid }
            }
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: best, to: dest)
        return Self.fileBytes(dest)
    }

    // MARK: - PNG

    /// Tries the gentlest thing that fits: lossless, then palette reduction, then a stronger one. Past that the caller
    /// shrinks the picture (`maxSide`) and this is run on the smaller copy.
    func fitPNG(input: URL, maxSide: Int?, lossy: Bool, target: Int64, work: URL, dest: URL) async throws -> Int64 {
        var source = input
        if let maxSide {
            let resized = work.appendingPathComponent("resized-\(maxSide).png")
            try await Task.detached(priority: .utility) { try Self.writeResizedPNG(from: input, maxSide: maxSide, to: resized) }.value
            source = resized
        }
        // "Reduce PNG colours" off in Settings means never palette-reduce: only resizing can then make it smaller.
        let tiers: [(min: Int, max: Int)?] = !lossy ? [nil] : maxSide == nil ? [nil, (80, 98), (0, 60)] : [(0, 70)]
        var bytes: Int64 = .max
        for tier in tiers {
            try Task.checkCancellation(or: EncodeError.cancelled)
            var current = source
            if let tier {
                let quant = work.appendingPathComponent("quant-\(dest.lastPathComponent)")
                try? FileManager.default.removeItem(at: quant)
                if try await runPNGQuant(input: source, output: quant, minQuality: tier.min, maxQuality: tier.max, speed: 3).produced { current = quant }
            }
            try? FileManager.default.removeItem(at: dest)
            try await runOxipng(input: current, output: dest, level: 4)
            bytes = Self.fileBytes(dest)
            if bytes <= target { return bytes }
        }
        return bytes
    }

    static func writeResizedPNG(from source: URL, maxSide: Int, to destination: URL) throws {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil) else { throw EncodeError.decodeFailed("couldn't open \(source.lastPathComponent)") }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary),
              let dest = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw EncodeError.decodeFailed("couldn't resize \(source.lastPathComponent)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw EncodeError.encodeFailed("couldn't write the resized PNG") }
    }
}
