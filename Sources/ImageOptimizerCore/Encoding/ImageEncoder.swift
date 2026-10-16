// ImageEncoder.swift - Runs an ImagePlan's steps and leaves the result at `partURL`.

import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum EncodeError: LocalizedError, Sendable, Equatable {
    case toolMissing(String)
    case toolFailed(tool: String, message: String)
    case decodeFailed(String)
    case encodeFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .toolMissing(let t): return "The \(t) encoder is missing from this install."
        case .toolFailed(let tool, let message):
            return "\(tool) failed" + (message.isEmpty ? "." : ": \(message)")
        case .decodeFailed(let why): return "Couldn't decode the image: \(why)"
        case .encodeFailed(let why): return "Couldn't encode the image: \(why)"
        case .cancelled: return "Cancelled."
        }
    }
}

public struct EncodeReport: Sendable, Equatable {
    /// Human-readable notes about what actually happened, e.g. a step that was skipped.
    public var notes: [String] = []
    /// True when the file written is a lossless repack even though the plan asked for lossy (a lossy GIF
    /// that saved too little falls back to lossless). The post-flight guard then keeps any real saving.
    public var producedLossless = false
}

public struct ImageEncoder: Sendable {
    public init() {}

    /// Runs every step, writing the final result to `partURL`. Intermediate files live in a temp
    /// directory that is always removed. Throws `EncodeError.cancelled` if the task is cancelled.
    public func encode(
        plan: ImagePlan,
        info: ImageInfo,
        to partURL: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> EncodeReport {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ImageOptimizer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var report = EncodeReport()
        var current = plan.inputURL
        for (index, step) in plan.steps.enumerated() {
            try Task.checkCancellation(or: EncodeError.cancelled)
            let isLast = index == plan.steps.count - 1
            let destination = isLast ? partURL : work.appendingPathComponent("step\(index).\(plan.inputURL.pathExtension)")
            switch step {
            case .jpegli(let distance, let chroma):
                try await runJPEGLI(input: plan.inputURL, info: info, distance: distance, chroma: chroma,
                                    output: destination, work: work)
                current = destination
            case .pngquant(let lo, let hi, let speed):
                let result = try await runPNGQuant(input: current, output: destination, minQuality: lo, maxQuality: hi, speed: speed)
                if let note = result.note { report.notes.append(note) }
                if result.produced { current = destination }
            case .oxipng(let level):
                try await runOxipng(input: current, output: destination, level: level)
                current = destination
            case .gifsicle(let lossy, let maxSide):
                let fellBack = try await runGifsicle(input: plan.inputURL, output: destination, lossy: lossy, maxSide: maxSide, frames: info.frameCount, work: work)
                if fellBack {
                    report.producedLossless = true
                    report.notes.append("Lossy compression wouldn't have saved enough, so this GIF was repacked losslessly instead.")
                }
                current = destination
            case .heic(let quality):
                try await runHEIC(input: plan.inputURL, output: destination, quality: quality, orientation: info.orientation)
                current = destination
            case .fitToSize(let target, let lossyPNG):
                try await runFitToSize(target: target, lossyPNG: lossyPNG, info: info, input: plan.inputURL, output: destination, work: work, report: &report, onProgress: onProgress)
                current = destination
            }
            onProgress?(Double(index + 1) / Double(plan.steps.count))
        }
        // pngquant skipped and nothing after it wrote the file: copy the input through so the
        // caller always finds a result at partURL.
        if current != partURL, !FileManager.default.fileExists(atPath: partURL.path) {
            try FileManager.default.copyItem(at: current, to: partURL)
        }
        // Put back whatever metadata the user chose to keep. GIF has none of this kind.
        if info.format != .gif {
            let (source, removing) = (plan.inputURL, plan.removeMetadata)
            // Kept metadata adds bytes, which must not push a "fit to size" result back over its limit.
            let bare = work.appendingPathComponent("bare.\(partURL.deletingPathExtension().pathExtension)")
            if plan.fitTargetBytes != nil { try? FileManager.default.copyItem(at: partURL, to: bare) }
            let result = await Task.detached(priority: .utility) { MetadataFilter.apply(source: source, to: partURL, removing: removing) }.value
            if let target = plan.fitTargetBytes, Self.fileBytes(partURL) > target, FileManager.default.fileExists(atPath: bare.path) {
                _ = try? FileManager.default.replaceItemAt(partURL, withItemAt: bare)
                report.notes.append("Metadata was left out to stay under the size limit.")
            } else if let result, result.kept > 0 {
                report.notes.append("Kept \(result.kept) metadata fields; removed \(result.removed).")
            }
        }
        return report
    }

    // MARK: - JPEG (jpegli)

    private func runJPEGLI(input: URL, info: ImageInfo, distance: Double, chroma: String?,
                           output: URL, work: URL) async throws {
        // Decoding is CPU-heavy; keep it off the cooperative pool so other jobs aren't starved.
        let pixels = try await Task.detached(priority: .utility) { try PixelExtractor.extract(url: input, info: info) }.value
        try Task.checkCancellation(or: EncodeError.cancelled)
        try await encodeJPEGLI(pixels: pixels, distance: distance, chroma: chroma, output: output, work: work)
    }

    func encodeJPEGLI(pixels: DecodedPixels, distance: Double, chroma: String?, output: URL, work: URL) async throws {
        guard let tool = ToolLocator.url(for: .cjpegli) else { throw EncodeError.toolMissing("cjpegli") }

        var args = ["-", output.path, "-d", String(format: "%.2f", distance), "-p", "2"]
        if let chroma { args += ["--chroma_subsampling=\(chroma)"] }
        if let icc = pixels.iccProfile {
            let iccURL = work.appendingPathComponent("profile.icc")
            try icc.write(to: iccURL)
            args += ["-x", "icc_pathname=\(iccURL.path)"]
        }
        let result = await ProcessRunner.run(tool, arguments: args) { handle in
            try handle.write(contentsOf: pixels.pnmHeader)
            // Stream in chunks so a 100 MB image isn't copied again into one giant Data.
            let chunk = 1 << 20
            var offset = 0
            while offset < pixels.bytes.count {
                let end = min(offset + chunk, pixels.bytes.count)
                try handle.write(contentsOf: Data(pixels.bytes[offset..<end]))
                offset = end
            }
        }
        try throwIfFailed(result, tool: "cjpegli")
    }

    // MARK: - PNG (pngquant, oxipng)

    struct QuantResult { var produced: Bool; var note: String? }

    func runPNGQuant(input: URL, output: URL, minQuality: Int, maxQuality: Int, speed: Int) async throws -> QuantResult {
        guard let tool = ToolLocator.url(for: .pngquant) else { throw EncodeError.toolMissing("pngquant") }
        let args = ["--quality", "\(minQuality)-\(maxQuality)", "--speed", "\(speed)", "--strip", "--force",
                    "--skip-if-larger", "--output", output.path, "--", input.path]
        let result = await ProcessRunner.run(tool, arguments: args)
        if result.wasCancelled { throw EncodeError.cancelled }
        switch result.exitCode {
        case 0: return QuantResult(produced: true, note: nil)
        case 98: return QuantResult(produced: false, note: "Palette reduction wouldn't have made this PNG smaller, so it was left lossless.")
        case 99: return QuantResult(produced: false, note: "Palette reduction would have visibly changed this PNG, so it was left lossless.")
        default: throw EncodeError.toolFailed(tool: "pngquant", message: clean(result.stderr))
        }
    }

    func runOxipng(input: URL, output: URL, level: Int) async throws {
        guard let tool = ToolLocator.url(for: .oxipng) else { throw EncodeError.toolMissing("oxipng") }
        // `--strip safe` keeps the colour profile; `--strip all` would shift colours (measured).
        // `--force` writes even when the result isn't smaller, so the caller's guard decides.
        let args = ["-o", "\(level)", "--strip", "safe", "--threads", "2", "--force", "--out", output.path, input.path]
        let result = await ProcessRunner.run(tool, arguments: args)
        try throwIfFailed(result, tool: "oxipng")
    }

    // MARK: - GIF (gifsicle)

    /// Returns true when a lossy request fell back to a lossless result.
    func runGifsicle(input: URL, output: URL, lossy: Int?, maxSide: Int?, frames: Int, work: URL) async throws -> Bool {
        guard let tool = ToolLocator.url(for: .gifsicle) else { throw EncodeError.toolMissing("gifsicle") }
        // -O3 is the strongest frame-diffing and palette search. Comments and unknown extensions are
        // dropped (the "essentials only" metadata rule); frames, delays and the loop count are kept.
        func run(lossy: Int?) async throws {
            var args = ["-O3", "--no-comments", "--no-names", "--no-extensions", "--no-warnings"]
            if let lossy { args.append("--lossy=\(lossy)") }
            if let maxSide { args += ["--resize-fit", "\(maxSide)x\(maxSide)"] }
            // A big lossy GIF is spread across the cores; lossless stays one exact run (see GifChunks.swift).
            if lossy != nil, let ranges = try await chunkPlan(tool: tool, input: input, frames: frames, work: work) {
                try await runGifsicleChunked(tool: tool, input: input, output: output, baseArgs: args, ranges: ranges, work: work)
                return
            }
            args += [input.path, "-o", output.path]
            try throwIfFailed(await ProcessRunner.run(tool, arguments: args), tool: "gifsicle")
        }
        try await run(lossy: lossy)
        // A resized GIF is smaller because it is smaller, not because of lossy, so the fallback doesn't apply.
        guard lossy != nil, maxSide == nil else { return false }
        // Lossy costs quality, so it must earn it. Measured on real GIFs, lossy often saved nothing
        // beyond what a lossless repack already does (and sometimes grew the file); when it falls short
        // of the guard's bar, keep the lossless result instead of throwing the saving away.
        let bytes = Self.fileBytes
        let original = bytes(input)
        if Double(bytes(output)) >= Double(original) * 0.92 {
            try Task.checkCancellation(or: EncodeError.cancelled)
            try await run(lossy: nil)
            return true
        }
        return false
    }

    // MARK: - HEIC (Apple, in-process)

    func runHEIC(input: URL, output: URL, quality: Double, orientation: Int, maxSide: Int? = nil) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
                      let image = Self.storedImage(source, maxSide: maxSide),
                      let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
                    continuation.resume(throwing: EncodeError.encodeFailed("couldn't open the HEIC"))
                    return
                }
                // Encode the decoded STORED pixels as a bare image and pass the orientation
                // explicitly. Measured: this drops GPS, capture time and camera model, keeps the
                // orientation and the colour profile, and leaves the stored pixels unrotated.
                // (Copying from the source instead keeps everything except GPS, which breaks the
                // "essentials only" metadata rule; omitting the orientation turns photos sideways.)
                let options: [CFString: Any] = [
                    kCGImageDestinationLossyCompressionQuality: quality,
                    kCGImagePropertyOrientation: orientation,
                ]
                CGImageDestinationAddImage(dest, image, options as CFDictionary)
                if CGImageDestinationFinalize(dest) {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: EncodeError.encodeFailed("the HEIC encoder reported a failure"))
                }
            }
        }
    }

    /// The decoded STORED pixels (orientation not applied), shrunk to fit `maxSide` on the longer side when given.
    static func storedImage(_ source: CGImageSource, maxSide: Int?) -> CGImage? {
        guard let maxSide else { return CGImageSourceCreateImageAtIndex(source, 0, nil) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - Helpers

    static func fileBytes(_ u: URL) -> Int64 { ((try? FileManager.default.attributesOfItem(atPath: u.path)[.size]) as? Int64) ?? .max }

    func throwIfFailed(_ result: ProcessResult, tool: String) throws {
        if result.wasCancelled { throw EncodeError.cancelled }
        guard result.exitCode == 0 else { throw EncodeError.toolFailed(tool: tool, message: clean(result.stderr)) }
    }

    private func clean(_ stderr: String) -> String {
        let line = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Task where Success == Never, Failure == Never {
    /// Throws `error` instead of CancellationError, so callers see one cancellation type.
    static func checkCancellation(or error: Error) throws {
        if Task.isCancelled { throw error }
    }
}
