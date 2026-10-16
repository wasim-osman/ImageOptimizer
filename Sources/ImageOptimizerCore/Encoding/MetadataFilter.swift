// MetadataFilter.swift - Puts back the metadata the user chose to keep.
//
// Every encoder here writes a bare image (a re-encode can't carry metadata across), so a result starts with none.
// This copies the SOURCE's metadata onto the finished file, minus the categories the user ticked, using
// CGImageDestinationCopyImageSource, which rewrites only the metadata and leaves the image data byte for byte
// as the encoder wrote it (measured: identical decoded pixels, colour profile kept).
//
// Fail safe: the copy is written to a temp file and checked before it replaces anything. If anything goes wrong,
// or a removed category is still present afterwards, the bare file is left as it was, so a failure never leaks
// something the user asked to remove.

import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum MetadataFilter {
    /// Tags that are never copied: they describe the source's pixels, not the result's. The encoder has already
    /// applied the orientation and written the real dimensions and colour profile.
    private static func isNeverCopied(prefix: String, name: String) -> Bool {
        if prefix == "iio" { return true }
        switch "\(prefix):\(name)" {
        case "tiff:Orientation", "exif:PixelXDimension", "exif:PixelYDimension",
             "tiff:PhotometricInterpretation", "tiff:Compression", "tiff:ResolutionUnit":
            return true
        default: return false
        }
    }

    private static let dateNames: Set<String> = [
        "DateTime", "DateTimeOriginal", "DateTimeDigitized", "CreateDate", "ModifyDate", "MetadataDate", "DateCreated",
        "TimeCreated", "DigitalCreationDate", "DigitalCreationTime"]
    private static let cameraNames: Set<String> = [
        "Make", "Model", "UniqueCameraModel", "LocalizedCameraModel", "CameraSerialNumber", "SerialNumber",
        "BodySerialNumber", "LensSerialNumber", "LensModel", "LensMake", "LensSpecification", "LensInfo", "Lens",
        "LensID", "LensIDNumber", "FirmwareVersion", "OwnerName", "ImageNumber"]
    private static let exposureNames: Set<String> = [
        "ExposureTime", "FNumber", "ExposureProgram", "ISOSpeedRatings", "PhotographicSensitivity", "ISOSpeed",
        "SensitivityType", "ShutterSpeedValue", "ApertureValue", "BrightnessValue", "ExposureBiasValue",
        "MaxApertureValue", "SubjectDistance", "SubjectDistanceRange", "MeteringMode", "LightSource", "Flash",
        "FlashEnergy", "FocalLength", "FocalLenIn35mmFilm", "FocalLengthIn35mmFilm", "SubjectArea", "SubjectLocation",
        "ExposureMode", "WhiteBalance", "DigitalZoomRatio", "SceneCaptureType", "GainControl", "Contrast",
        "Saturation", "Sharpness", "SensingMethod", "CustomRendered", "SceneType", "ExposureIndex",
        "RecommendedExposureIndex", "CompositeImage"]
    private static let authorNames: Set<String> = [
        "Artist", "Copyright", "Software", "HostComputer", "CreatorTool", "creator", "rights", "Credit", "Source",
        "AuthorsPosition", "CameraOwnerName", "Marked", "UsageTerms", "WebStatement", "Owner", "Photographer",
        "ProcessingSoftware"]
    private static let descriptionNames: Set<String> = [
        "ImageDescription", "UserComment", "title", "description", "subject", "Rating", "Label", "Nickname",
        "Headline", "Caption", "CaptionWriter", "Keywords", "Instructions", "Category", "SupplementalCategories",
        "Urgency", "DocumentTitle", "XPTitle", "XPComment", "XPKeywords", "XPSubject", "XPAuthor", "TransmissionReference"]
    private static let locationNames: Set<String> = [
        "City", "State", "Country", "Location", "CountryCode", "LocationShown", "LocationCreated", "Sublocation",
        "ProvinceState", "CountryName", "CountryCodeName", "IntellectualGenre"]

    /// The category a tag belongs to, or nil when it is never copied. `path` is ImageIO's "prefix:Name".
    static func category(prefix: String, name: String) -> MetadataCategory? {
        if isNeverCopied(prefix: prefix, name: name) { return nil }
        let base = name.split(separator: "[").first.map(String.init) ?? name   // "dc:subject[1]" -> "subject"
        let lower = base.lowercased()
        // Anything GPS, wherever it is stored (EXIF, XMP, or a GPS block of its own), is location.
        if prefix.lowercased() == "gps" || lower.hasPrefix("gps") || locationNames.contains(base) { return .location }
        if dateNames.contains(base) || lower.hasPrefix("subsec") || lower.hasPrefix("offsettime") { return .dateTime }
        if prefix == "aux" || cameraNames.contains(base) { return .cameraAndLens }
        if exposureNames.contains(base) { return .exposure }
        if authorNames.contains(base) || prefix == "xmpRights" { return .authorship }
        if descriptionNames.contains(base) { return .descriptions }
        return .other
    }

    private static func tags(of metadata: CGImageMetadata) -> [(path: String, category: MetadataCategory?)] {
        var out: [(String, MetadataCategory?)] = []
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, tag in
            let prefix = (CGImageMetadataTagCopyPrefix(tag) as String?) ?? ""
            let full = path as String
            let name = full.hasPrefix(prefix + ":") ? String(full.dropFirst(prefix.count + 1)) : full
            out.append((full, category(prefix: prefix, name: name)))
            return true
        }
        return out
    }

    public struct Result: Sendable, Equatable {
        /// Fields carried across.
        public var kept: Int
        /// Fields left behind because the user chose to remove them.
        public var removed: Int
    }

    /// Copies `source`'s metadata onto `output` (rewritten in place), leaving out `removing`.
    /// Returns nil, with `output` untouched, when there was nothing to copy or the copy couldn't be verified.
    public static func apply(source: URL, to output: URL, removing: Set<MetadataCategory>) -> Result? {
        guard removing.count < MetadataCategory.allCases.count,
              let src = CGImageSourceCreateWithURL(source as CFURL, nil),
              let sourceMetadata = CGImageSourceCopyMetadataAtIndex(src, 0, nil),
              let out = CGImageSourceCreateWithURL(output as CFURL, nil),
              let type = CGImageSourceGetType(out),
              let copy = CGImageMetadataCreateMutableCopy(sourceMetadata) else { return nil }

        var kept = 0, removed = 0
        for (path, category) in tags(of: sourceMetadata) {
            if let category, !removing.contains(category) { kept += 1; continue }
            if category != nil { removed += 1 }
            CGImageMetadataRemoveTagWithPath(copy, nil, path as CFString)
        }
        guard kept > 0 else { return nil }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationMetadata: copy, kCGImageDestinationMergeMetadata: false]
        guard CGImageDestinationCopyImageSource(dest, out, options as CFDictionary, nil), data.length > 0 else { return nil }

        // Verify before replacing anything: nothing the user removed may be in the result.
        guard let check = CGImageSourceCreateWithData(data, nil), verify(check, removing: removing) else { return nil }
        let temp = output.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).meta")
        do {
            try data.write(to: temp)
            _ = try FileManager.default.replaceItemAt(output, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return nil
        }
        return Result(kept: kept, removed: removed)
    }

    /// True when the written file holds no tag in a removed category, and, if location is removed, no GPS block.
    static func verify(_ source: CGImageSource, removing: Set<MetadataCategory>) -> Bool {
        if let md = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            for (_, category) in tags(of: md) { if let category, removing.contains(category) { return false } }
        }
        if removing.contains(.location),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           props[kCGImagePropertyGPSDictionary] != nil { return false }
        return true
    }
}
