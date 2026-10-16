// GifChunks.swift - Spreads one big lossy GIF across every CPU core.
//
// gifsicle is single-threaded, and a GIF can't simply be cut at a frame: most frames store only what changed
// since the one before, so a slice's first frame is a partial picture (and gifsicle can't unoptimise a GIF whose
// full frames need more than 256 colours). So each chunk after the first starts with a keyframe: the fully
// composited frame, rendered by ImageIO. Each chunk is optimised by its own gifsicle, then they are joined.
//
// Measured on an 88 MB, 446-frame screen recording (Smallest): 44 s serial, 11 s over 12 chunks, 2.6% larger
// (the keyframes), every frame's delay identical and every chunk boundary scoring the same as the serial result.
// Lossy modes only: a keyframe is requantised to 256 colours, which a lossless result must never be.

import Foundation
import ImageIO
import UniformTypeIdentifiers

extension ImageEncoder {
    /// Below this a serial run is quick enough that chunking only adds keyframes.
    static let chunkMinBytes: Int64 = 8_000_000
    /// A chunk shorter than this spends more on its keyframe than it saves.
    static let chunkMinFrames = 16
    /// Every chunk's gifsicle reads the whole source, so cap how many hold a copy at once.
    static let chunkMemoryBudget: Int64 = 3_000_000_000

    /// Frame ranges to optimise separately, or nil when one run is the better choice.
    static func chunkRanges(frames: Int, bytes: Int64, cores: Int = ProcessInfo.processInfo.activeProcessorCount) -> [ClosedRange<Int>]? {
        guard bytes >= chunkMinBytes else { return nil }
        let byMemory = Int(max(1, chunkMemoryBudget / max(1, bytes)))
        let count = min(cores, frames / chunkMinFrames, byMemory)
        guard count >= 2 else { return nil }
        let per = (frames + count - 1) / count
        return stride(from: 0, to: frames, by: per).map { $0...min(frames - 1, $0 + per - 1) }
    }

    /// Which frames may start a chunk. A keyframe is the whole picture, so it can only stand in for a frame whose
    /// successor expects nothing cleared: a frame with a "background" or "previous" disposal would leave the
    /// next (partial) frame drawn over the wrong pixels. gifsicle's --info prints a `disposal` line only for those.
    static func keyframeSafe(info: String) -> [Bool] {
        var safe: [Bool] = []
        for line in info.split(separator: "\n") {
            let t = line.drop(while: { $0 == " " })
            if t.hasPrefix("+ image #") { safe.append(true) }
            else if t.hasPrefix("disposal "), !safe.isEmpty {
                let mode = t.dropFirst("disposal ".count).prefix(while: { $0 != " " })
                if mode != "asis" && mode != "none" { safe[safe.count - 1] = false }
            }
        }
        return safe
    }

    /// Moves each chunk start forward to the nearest frame that is safe to start on. A chunk with no safe frame
    /// is joined to the one before it. Returns nil when fewer than two chunks are left.
    static func alignedRanges(_ ranges: [ClosedRange<Int>], safe: [Bool]) -> [ClosedRange<Int>]? {
        guard let last = ranges.last?.upperBound, safe.count == last + 1 else { return nil }
        var starts = [0]
        for r in ranges.dropFirst() {
            if let s = (r.lowerBound...r.upperBound).first(where: { safe[$0] }), s > starts.last! { starts.append(s) }
        }
        guard starts.count >= 2 else { return nil }
        return starts.indices.map { starts[$0]...(($0 + 1 < starts.count ? starts[$0 + 1] : last + 1) - 1) }
    }

    /// The chunking to use for this file, or nil to run it whole.
    func chunkPlan(tool: URL, input: URL, frames: Int, work: URL) async throws -> [ClosedRange<Int>]? {
        guard let ranges = Self.chunkRanges(frames: frames, bytes: Self.fileBytes(input)) else { return nil }
        let infoFile = work.appendingPathComponent("info.txt")
        guard await ProcessRunner.run(tool, arguments: ["--info", input.path, "-o", infoFile.path]).exitCode == 0,
              let text = try? String(contentsOf: infoFile, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: infoFile)
        return Self.alignedRanges(ranges, safe: Self.keyframeSafe(info: text))
    }

    func runGifsicleChunked(tool: URL, input: URL, output: URL, baseArgs: [String], ranges: [ClosedRange<Int>], work: URL) async throws {
        let chunks = try await withThrowingTaskGroup(of: (Int, URL).self) { group -> [URL] in
            for (i, range) in ranges.enumerated() {
                group.addTask {
                    let chunk = work.appendingPathComponent("chunk\(i).gif")
                    var args = baseArgs
                    if range.lowerBound == 0 {
                        args += [input.path, "#0-\(range.upperBound)"]
                    } else {
                        let key = work.appendingPathComponent("key\(i).gif")
                        let raw = work.appendingPathComponent("raw\(i).gif")
                        try await Self.renderKeyframe(of: input, index: range.lowerBound, to: raw)
                        // ImageIO writes "clear to background" disposal, which would wipe the picture the next
                        // (partial) frame is drawn over. A safe start frame leaves it alone, so say so.
                        try self.throwIfFailed(await ProcessRunner.run(tool, arguments: ["--disposal=asis", raw.path, "-o", key.path]), tool: "gifsicle")
                        args += [key.path, input.path, "#\(range.lowerBound + 1)-\(range.upperBound)"]
                    }
                    args += ["-o", chunk.path]
                    try self.throwIfFailed(await ProcessRunner.run(tool, arguments: args), tool: "gifsicle")
                    return (i, chunk)
                }
            }
            var done: [(Int, URL)] = []
            for try await item in group { done.append(item) }
            return done.sorted { $0.0 < $1.0 }.map(\.1)
        }
        try Task.checkCancellation(or: EncodeError.cancelled)
        // Plain concatenation: frames, delays and each chunk's own palette are kept; the first chunk carries the loop count.
        let args = ["--no-warnings"] + chunks.map(\.path) + ["-o", output.path]
        try self.throwIfFailed(await ProcessRunner.run(tool, arguments: args), tool: "gifsicle")
    }

    /// Frame `index` as ImageIO composites it (what a viewer shows), as a one-frame GIF that keeps that frame's delay.
    static func renderKeyframe(of source: URL, index: Int, to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(src, index, nil),
                      let dest = CGImageDestinationCreateWithURL(destination as CFURL, UTType.gif.identifier as CFString, 1, nil) else {
                    continuation.resume(throwing: EncodeError.decodeFailed("couldn't render frame \(index) of the GIF"))
                    return
                }
                let gif = (CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
                let props: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: delay, kCGImagePropertyGIFDelayTime: delay]]
                CGImageDestinationAddImage(dest, image, props as CFDictionary)
                if CGImageDestinationFinalize(dest) { continuation.resume() }
                else { continuation.resume(throwing: EncodeError.encodeFailed("couldn't write a keyframe")) }
            }
        }
    }
}
