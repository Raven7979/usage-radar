import Foundation

enum JSONLines {
    static func dictionaries(from url: URL) -> [([String: Any], Int)] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }

        var result: [([String: Any], Int)] = []
        for (index, line) in content.split(whereSeparator: \.isNewline).enumerated() {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any] else {
                continue
            }
            result.append((dictionary, index + 1))
        }
        return result
    }
}

