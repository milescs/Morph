import Foundation

/// A place people send files ("Email", "Discord"), with the format, size and resolution that work
/// there. Loaded from JSON so the limits can be updated without a new version of Morph.
public struct Destination: Codable, Sendable, Hashable, Identifiable {
    /// What to produce for one kind of file.
    public struct Rule: Codable, Sendable, Hashable {
        public var target: OutputFormat
        public var sizeLimitMB: Double?
        /// Images: longest side in pixels.
        public var maxLongSide: Int?
        /// Video: short side in pixels (1080 = 1080p).
        public var shortSide: Int?
        /// 0…1; nil keeps the default.
        public var quality: Double?

        public init(target: OutputFormat, sizeLimitMB: Double? = nil, maxLongSide: Int? = nil, shortSide: Int? = nil,
                    quality: Double? = nil) {
            self.target = target
            self.sizeLimitMB = sizeLimitMB
            self.maxLongSide = maxLongSide
            self.shortSide = shortSide
            self.quality = quality
        }

        public var sizeLimit: Int64? { sizeLimitMB.map { Int64(($0 * 1_000_000).rounded()) } }
    }

    public var id: String
    public var name: String
    /// SF Symbol.
    public var symbol: String
    /// Short label shown on the chip, e.g. "10 MB".
    public var badge: String
    /// One sentence about the limits.
    public var summary: String
    /// Keyed by `MediaKind.rawValue`.
    public var rules: [String: Rule]

    public init(id: String, name: String, symbol: String, badge: String, summary: String, rules: [MediaKind: Rule]) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.badge = badge
        self.summary = summary
        self.rules = Dictionary(uniqueKeysWithValues: rules.map { ($0.key.rawValue, $0.value) })
    }

    public func rule(for kind: MediaKind) -> Rule? { rules[kind.rawValue] }

    /// Settings that make files of `kind` fit this destination, or nil if it doesn't take them.
    /// Starts from defaults (so leftover Pro options can't break compatibility) but keeps privacy choices.
    public func settings(for kind: MediaKind, keepingPrivacyFrom base: ConversionSettings) -> ConversionSettings? {
        guard let rule = rule(for: kind) else { return nil }
        var settings = ConversionSettings(target: rule.target)
        settings.image.metadata = base.image.metadata == .keep ? .removeLocation : base.image.metadata
        settings.video.stripMetadata = base.video.stripMetadata
        settings.audio.stripMetadata = base.audio.stripMetadata
        switch ConversionSettings.sliderDomain(target: rule.target, kind: kind) {
        case .image:
            settings.image.sizeLimit = rule.sizeLimit
            if let quality = rule.quality { settings.image.quality = quality }
            if let side = rule.maxLongSide { settings.image.resize = .longestSide(side) }
        case .video:
            settings.video.sizeLimit = rule.sizeLimit
            if let quality = rule.quality { settings.video.quality = quality }
            if let side = rule.shortSide { settings.video.resolution = .shortSide(side) }
        case .audio:
            settings.audio.sizeLimit = rule.sizeLimit
            if let quality = rule.quality { settings.audio.quality = quality }
        }
        return settings
    }

    // Rules with targets this version doesn't know (added by a newer catalog) are skipped.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        symbol = c.value(.symbol, or: "paperplane.fill")
        badge = c.value(.badge, or: "")
        summary = c.value(.summary, or: "")
        let raw = c.value(.rules, or: [String: LossyRule]())
        rules = raw.compactMapValues(\.rule).filter { MediaKind(rawValue: $0.key) != nil }
    }

    private struct LossyRule: Decodable {
        var rule: Rule?
        init(from decoder: any Decoder) throws { rule = try? Rule(from: decoder) }
    }
}

/// The list of destinations, with a schema version and the date its limits were last checked.
public struct DestinationCatalog: Codable, Sendable, Hashable {
    /// Schema version; a catalog with a higher version than this app understands is ignored.
    public static let supportedVersion = 1

    public var version: Int
    /// ISO date (yyyy-MM-dd) the limits were last reviewed.
    public var updated: String
    public var destinations: [Destination]

    public init(version: Int = supportedVersion, updated: String, destinations: [Destination]) {
        self.version = version
        self.updated = updated
        self.destinations = destinations
    }

    public static func decode(_ data: Data) throws -> DestinationCatalog {
        let catalog = try JSONDecoder().decode(DestinationCatalog.self, from: data)
        guard catalog.version <= supportedVersion else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Newer catalog version"))
        }
        return catalog
    }

    public func destination(id: String) -> Destination? { destinations.first { $0.id == id } }
}
