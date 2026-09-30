import Foundation
import MorphKit

/// Expands dropped/picked URLs (files and folders) into supported media items.
nonisolated enum FileScanner {
    struct Result: Sendable {
        var items: [MediaItem] = []
        var skipped = 0
    }

    /// Recursively scans folders (skipping hidden files and package contents such as .photoslibrary).
    static func scan(_ urls: [URL], limit: Int = 20_000) -> Result {
        var result = Result()
        var seen = Set<String>()
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isRegularFileKey]

        func consider(_ url: URL) {
            guard result.items.count < limit, seen.insert(url.standardizedFileURL.path).inserted else { return }
            if let item = MediaProbe.item(for: url) {
                result.items.append(item)
            } else {
                result.skipped += 1
            }
        }

        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isFolder = values?.isDirectory == true && values?.isPackage != true
            guard isFolder else {
                consider(url)
                continue
            }
            guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys,
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            let folderItems: [URL] = enumerator.compactMap { element in
                // Symlinked files count too (symlinked folders aren't followed, so there are no loops).
                guard let file = element as? URL,
                      (try? file.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                else { return nil }
                return file
            }
            // Natural order ("IMG_2" before "IMG_10") within folders.
            for file in folderItems.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
                consider(file)
            }
        }
        return result
    }
}
