import Foundation

enum FileDiscovery {
    static func homeDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    static func jsonlFiles(under root: URL, skippingDirectoryNames: Set<String> = []) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true, skippingDirectoryNames.contains(fileURL.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }

            guard fileURL.pathExtension == "jsonl" else { continue }
            if values?.isRegularFile == true {
                urls.append(fileURL)
            }
        }
        return urls
    }

    static func sortedByModifiedDescending(_ urls: [URL]) -> [URL] {
        urls.sorted { left, right in
            let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return leftDate > rightDate
        }
    }
}
