// MetadataCategory.swift - The groups of embedded metadata a user can choose to remove.

import Foundation

public enum MetadataCategory: String, Sendable, CaseIterable, Codable {
    case location
    case dateTime
    case cameraAndLens
    case exposure
    case authorship
    case descriptions
    case other

    public var displayName: String {
        switch self {
        case .location: return "Location"
        case .dateTime: return "Date and time"
        case .cameraAndLens: return "Camera and lens"
        case .exposure: return "Exposure settings"
        case .authorship: return "Author, copyright and software"
        case .descriptions: return "Titles, descriptions and keywords"
        case .other: return "Everything else"
        }
    }

    public var detail: String {
        switch self {
        case .location: return "GPS position, altitude, direction, and place names"
        case .dateTime: return "When the photo was taken or edited"
        case .cameraAndLens: return "Make, model, lens and serial numbers"
        case .exposure: return "ISO, shutter speed, aperture, focal length, flash"
        case .authorship: return "Artist, copyright, the software used"
        case .descriptions: return "Captions, comments, ratings, tags"
        case .other: return "Technical tags, maker notes and anything not listed above"
        }
    }

    /// What is removed unless the user changes it: only the location.
    public static let defaultRemoved: Set<MetadataCategory> = [.location]
}
