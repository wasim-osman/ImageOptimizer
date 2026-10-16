// ImageOptimizerCLI - drives the whole headless core against real files.
//
//   ImageOptimizerCLI [options] <file-or-folder>...
//     --mode high|balanced|smallest      (default balanced)
//     --lossless-png                     never use lossy palette reduction
//     --force                            skip the size guards ("convert anyway")
//     --out <folder>                     write results there instead of beside the source
//     --remove-metadata all|none|LIST    groups to remove (default: location)
//     --concurrency N                    (default: one per CPU core)
//     --plan                             show what would happen, encode nothing

import Foundation
import UniformTypeIdentifiers
import ImageOptimizerCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var settings = Settings()
var force = false
var planOnly = false
var inputs: [String] = []

var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "--mode":
        guard let v = args.popFirst() else { fail("--mode needs a value") }
        switch v {
        case "high": settings.encoderMode = .highQuality
        case "balanced": settings.encoderMode = .balanced
        case "smallest": settings.encoderMode = .smallest
        default: fail("unknown mode '\(v)' (high, balanced, smallest)")
        }
    case "--lossless-png": settings.pngLossy = false
    case "--force": force = true
    case "--plan": planOnly = true
    case "--out":
        guard let v = args.popFirst() else { fail("--out needs a folder") }
        try? FileManager.default.createDirectory(atPath: v, withIntermediateDirectories: true)
        settings.outputLocation = .chooseFolder
        settings.chosenFolderPath = v
    case "--remove-metadata":
        // all | none | a comma list of: location,date,camera,exposure,author,description,other
        guard let v = args.popFirst() else { fail("--remove-metadata needs all, none, or a list") }
        let names: [String: MetadataCategory] = ["location": .location, "date": .dateTime, "camera": .cameraAndLens,
                                                 "exposure": .exposure, "author": .authorship, "description": .descriptions, "other": .other]
        switch v {
        case "all": settings.removeMetadata = Set(MetadataCategory.allCases)
        case "none": settings.removeMetadata = []
        default:
            var chosen = Set<MetadataCategory>()
            for part in v.split(separator: ",") {
                guard let c = names[String(part)] else { fail("unknown metadata group '\(part)' (use \(names.keys.sorted().joined(separator: ", ")))") }
                chosen.insert(c)
            }
            settings.removeMetadata = chosen
        }
    case "--concurrency":
        guard let v = args.popFirst(), let n = Int(v), n > 0 else { fail("--concurrency needs a positive number") }
        settings.concurrency = n
    case "-h", "--help":
        print("usage: ImageOptimizerCLI [--mode high|balanced|smallest] [--lossless-png] [--force] [--out DIR] [--concurrency N] [--remove-metadata all|none|location,date,camera,exposure,author,description,other] [--plan] <files or folders>")
        exit(0)
    default:
        inputs.append(arg)
    }
}
guard !inputs.isEmpty else { fail("no input files. Try --help") }

// Expand folders one level deep, like dropping a folder on the app.
var files: [URL] = []
for path in inputs {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { fail("not found: \(path)") }
    if isDir.boolValue {
        let kids = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        files += kids.filter { (UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) ?? false) }.sorted { $0.path < $1.path }
    } else {
        files.append(URL(fileURLWithPath: path))
    }
}

func human(_ bytes: Int64) -> String {
    let f = ByteCountFormatter(); f.countStyle = .file
    return f.string(fromByteCount: bytes)
}

if planOnly {
    for url in files {
        do {
            let info = try ImageProbe.probe(url: url)
            let plan = EncodePlanner().plan(info: info, inputURL: url, settings: settings, forceEncode: force)
            print("\(url.lastPathComponent): \(info.format.displayName) \(info.width)x\(info.height) \(String(format: "%.2f", info.bitsPerPixel)) bpp"
                  + (info.iccProfileName.map { " [\($0)]" } ?? "") + (info.orientation != 1 ? " orient=\(info.orientation)" : ""))
            switch plan.outcome {
            case .planned: print("    -> \(plan.qualityNote): \(plan.steps)")
            case .refused(let r): print("    -> refused: \(r.reason)")
            }
        } catch { print("\(url.lastPathComponent): \(error.localizedDescription)") }
    }
    exit(0)
}

let queue = JobQueue(maxConcurrent: settings.effectiveConcurrency, settings: settings)
let started = Date()
for url in files { await queue.addJob(url: url, forceEncode: force) }
while !(await queue.isIdle) { try? await Task.sleep(for: .milliseconds(100)) }

var before: Int64 = 0, after: Int64 = 0, converted = 0
for job in await queue.snapshot() {
    let name = job.inputURL.lastPathComponent
    switch job.state {
    case .succeeded:
        let out = job.resultSize ?? 0
        before += job.inputSize; after += out; converted += 1
        let pct = job.inputSize > 0 ? Int((1 - Double(out) / Double(job.inputSize)) * 100) : 0
        print("OK       \(name): \(human(job.inputSize)) -> \(human(out)) (-\(pct)%)" + (job.error.isEmpty ? "" : "  [\(job.error)]"))
    default:
        print("\(job.state.rawValue.uppercased().padding(toLength: 16, withPad: " ", startingAt: 0)) \(name): \(job.error)")
    }
}
let secs = Date().timeIntervalSince(started)
print(String(format: "\n%d converted, %@ -> %@ (saved %@) in %.1fs", converted, human(before), human(after), human(max(0, before - after)), secs))
