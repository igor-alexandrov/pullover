import Foundation
import PulloverCore

public struct InvalidRepositoryError: Error, LocalizedError, Equatable {
    public var input: String
    public var errorDescription: String? { "Repository needs to look like owner/repo — got \"\(input)\"" }
}

/// Settings and snoozes, persisted in `UserDefaults`. Both are stored as JSON
/// blobs rather than one key per field, so a settings shape written by an
/// older build is decoded — and defaulted field by field — in one place.
public final class AppStore: @unchecked Sendable {
    private static let settingsKey = "settings"
    private static let snoozesKey = "snoozes"

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var settings: Settings {
        lock.withLock {
            guard let data = defaults.data(forKey: Self.settingsKey),
                  let settings = try? JSONDecoder().decode(Settings.self, from: data) else { return .defaults }
            return settings
        }
    }

    public func updateSettings(_ change: (inout Settings) -> Void) {
        var next = settings
        change(&next)
        lock.withLock {
            defaults.set(try? JSONEncoder().encode(next), forKey: Self.settingsKey)
        }
    }

    public func addRepository(_ fullName: String) throws {
        let normalised = fullName.trimmingCharacters(in: .whitespaces).lowercased()
        guard normalised.wholeMatch(of: /[\w.-]+\/[\w.-]+/) != nil else {
            throw InvalidRepositoryError(input: fullName)
        }
        updateSettings { settings in
            if !settings.repositories.contains(normalised) { settings.repositories.append(normalised) }
        }
    }

    public func removeRepository(_ fullName: String) {
        let normalised = fullName.trimmingCharacters(in: .whitespaces).lowercased()
        updateSettings { $0.repositories.removeAll { $0 == normalised } }
    }

    public var snoozes: [String: Snooze] {
        lock.withLock {
            guard let data = defaults.data(forKey: Self.snoozesKey),
                  let snoozes = try? ISODate.makeDecoder().decode([String: Snooze].self, from: data) else { return [:] }
            return snoozes
        }
    }

    private func writeSnoozes(_ snoozes: [String: Snooze]) {
        lock.withLock {
            defaults.set(try? ISODate.makeEncoder().encode(snoozes), forKey: Self.snoozesKey)
        }
    }

    /// `hours` is required for `.untilTime` and ignored otherwise.
    public func snooze(_ prId: String, type: SnoozeType, now: Date, hours: Int? = nil) {
        let until: Date? = type == .untilTime ? now.addingTimeInterval(TimeInterval((hours ?? 24) * 3600)) : nil
        var next = snoozes
        next[prId] = Snooze(prId: prId, type: type, snoozedAt: now, until: until)
        writeSnoozes(next)
    }

    public func unsnooze(_ prId: String) {
        var next = snoozes
        next[prId] = nil
        writeSnoozes(next)
    }
}
