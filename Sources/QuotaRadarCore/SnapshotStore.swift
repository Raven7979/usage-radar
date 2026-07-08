import Foundation

public enum SnapshotStore {
    public static let appGroupIdentifier = "group.com.ravenlei.QuotaRadar"

    public static func snapshotURL() throws -> URL {
        let fileManager = FileManager.default
        let directory = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("QuotaRadar", isDirectory: true)

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("snapshot.json")
    }

    public static func write(_ snapshot: UsageSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: snapshotURL(), options: [.atomic])
    }

    public static func read() -> UsageSnapshot? {
        guard let url = try? snapshotURL(),
              let data = try? Data(contentsOf: url) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(UsageSnapshot.self, from: data)
    }
}

