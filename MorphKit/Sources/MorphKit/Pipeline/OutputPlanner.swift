import Darwin
import Foundation

public enum CollisionPolicy: String, Codable, Sendable, CaseIterable {
    case keepBoth, replace, skip

    public var displayName: String {
        switch self {
        case .keepBoth: "Keep both"
        case .replace: "Replace existing"
        case .skip: "Skip"
        }
    }
}

public enum DestinationMode: Sendable, Hashable {
    /// Each output goes next to its original.
    case nextToOriginal
    /// All outputs go into one folder.
    case folder(URL)
}

/// Decides output file names.
public struct OutputPlanner: Sendable {
    public var destination: DestinationMode
    /// `{name}` = original base name. Used when the format changes.
    public var template: String
    /// Used when the output keeps the input's format (so originals are never replaced).
    public var sameFormatTemplate: String

    public init(destination: DestinationMode, template: String = "{name}", sameFormatTemplate: String = "{name}-compressed") {
        self.destination = destination
        self.template = template
        self.sameFormatTemplate = sameFormatTemplate
    }

    /// The desired output URL (collisions are resolved when the file is committed).
    public func url(for item: MediaItem, fileExtension: String, suffix: String? = nil) -> URL {
        let directory: URL = switch destination {
        case .nextToOriginal: item.url.deletingLastPathComponent()
        case .folder(let folder): folder
        }
        let sameFormat = fileExtension.lowercased() == item.url.pathExtension.lowercased()
        let pattern = sameFormat ? sameFormatTemplate : template
        var name = pattern.replacingOccurrences(of: "{name}", with: item.baseName)
        name = Self.sanitize(name.isEmpty ? item.baseName : name)
        if let suffix { name += suffix }
        var url = directory.appending(path: name).appendingPathExtension(fileExtension)
        // Never target the original itself.
        if url.standardizedFileURL.path == item.url.standardizedFileURL.path {
            url = directory.appending(path: name + "-converted").appendingPathExtension(fileExtension)
        }
        return url
    }

    /// URL for a combined output (e.g. many images → one PDF).
    public func combinedURL(items: [MediaItem], fileExtension: String, name: String = "Combined") -> URL {
        let directory: URL = switch destination {
        case .nextToOriginal: items.first?.url.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory
        case .folder(let folder): folder
        }
        return directory.appending(path: Self.sanitize(name)).appendingPathExtension(fileExtension)
    }

    static func sanitize(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return String(cleaned.prefix(200))
    }

    /// "photo.jpg" → "photo 2.jpg", "photo 3.jpg" …
    public static func numbered(_ url: URL, _ n: Int) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dir = url.deletingLastPathComponent()
        let candidate = dir.appending(path: "\(base) \(n)")
        return ext.isEmpty ? candidate : candidate.appendingPathExtension(ext)
    }
}

public struct WriteError: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

/// Writes outputs through a temp file in the destination folder, then renames atomically.
public enum AtomicWriter {
    /// A temp URL next to `destination` that keeps its extension (so ffmpeg can infer formats).
    public static func temporaryURL(for destination: URL) -> URL {
        let dir = destination.deletingLastPathComponent()
        let ext = destination.pathExtension
        let name = ".\(destination.deletingPathExtension().lastPathComponent).morph-\(UUID().uuidString.prefix(8))"
        let url = dir.appending(path: name)
        return ext.isEmpty ? url : url.appendingPathExtension(ext)
    }

    /// Moves `temp` into place. Returns the final URL, or nil if skipped by policy.
    public static func commit(_ temp: URL, to destination: URL, policy: CollisionPolicy,
                              protecting originals: Set<String> = []) throws -> URL? {
        let fm = FileManager.default
        let isOriginal = originals.contains(destination.standardizedFileURL.path)

        if policy == .replace && !isOriginal {
            if Darwin.rename(temp.path, destination.path) == 0 { return destination }
            throw WriteError(message: String(cString: strerror(errno)))
        }
        if policy == .skip && fm.fileExists(atPath: destination.path) {
            try? fm.removeItem(at: temp)
            return nil
        }
        var candidate = destination
        var n = 2
        while true {
            if isOriginal && candidate == destination {
                candidate = OutputPlanner.numbered(destination, n)
                n += 1
                continue
            }
            if renamex_np(temp.path, candidate.path, UInt32(RENAME_EXCL)) == 0 { return candidate }
            guard errno == EEXIST else {
                let reason = String(cString: strerror(errno))
                try? fm.removeItem(at: temp)
                throw WriteError(message: "Couldn't save \(candidate.lastPathComponent): \(reason)")
            }
            candidate = OutputPlanner.numbered(destination, n)
            n += 1
            if n > 10_000 { throw WriteError(message: "Too many files with the same name.") }
        }
    }

    /// Writes data to `destination` atomically with the collision policy.
    public static func write(_ data: Data, to destination: URL, policy: CollisionPolicy,
                             protecting originals: Set<String> = []) throws -> URL? {
        let temp = temporaryURL(for: destination)
        do {
            try data.write(to: temp)
        } catch {
            throw WriteError(message: "Couldn't write to \(destination.deletingLastPathComponent().lastPathComponent): \(error.localizedDescription)")
        }
        return try commit(temp, to: destination, policy: policy, protecting: originals)
    }
}
