import Foundation

enum DateParsing {
    private static let fractionalISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ value: String) -> Date? {
        fractionalISO8601.date(from: value) ?? plainISO8601.date(from: value)
    }

    static func floorToHour(_ date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Date {
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return calendar.date(from: components) ?? date
    }
}

