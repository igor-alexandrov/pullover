import Foundation
import PulloverCore

/// Everything a request to GitHub can fail with, kept apart by kind because
/// each kind is handled differently: a 401 signs out, a 403/429 with rate-limit
/// headers waits, a 5xx is retried, and GraphQL errors may carry partial data.
public enum GitHubError: Error, Sendable, Equatable {
    /// A non-2xx response. `headers` are lowercased.
    case http(status: Int, message: String, headers: [String: String])
    /// The request never got an answer: offline, DNS, a dropped connection.
    case network(String)
    /// A 200 whose body carries `errors`. `partialData` is the `data` GitHub
    /// still resolved, as JSON, or nil when there was none.
    case graphql(messages: [String], partialData: Data?)
    /// An answer that doesn't have the shape it must.
    case malformed(String)
}

extension GitHubError: LocalizedError {
    public var errorDescription: String? { describeError(self) }
}

extension GitHubError {
    var status: Int? {
        if case let .http(status, _, _) = self { return status }
        return nil
    }

    var messages: [String] {
        switch self {
        case let .http(_, message, _): [message]
        case let .network(message): [message]
        case let .graphql(messages, _): messages
        case let .malformed(message): [message]
        }
    }
}

/// Whether asking again could plausibly answer differently: only GitHub or its
/// edge failing on its own side (a 5xx, including the 502 a terminated query
/// comes back as) or the network dropping. A 401, a rate limit or a GraphQL
/// error answers the same however many times it is asked.
public func isTransientError(_ error: any Error) -> Bool {
    switch error as? GitHubError {
    case let .http(status, _, _)?: (500..<600).contains(status)
    case .network?: true
    default: false
    }
}

/// A dead token — revoked or expired. Only a 401 means the token itself is no good.
public func isAuthError(_ error: any Error) -> Bool {
    (error as? GitHubError)?.status == 401
}

/// When a hit rate limit lifts, or nil if `error` isn't one. GitHub attaches
/// `x-ratelimit-*` headers to nearly every response, so a permission failure
/// is also a 403 carrying them: both the status and the header must hold.
public func rateLimitResetAt(_ error: any Error, now: Date) -> Date? {
    guard case let .http(status, _, headers)? = error as? GitHubError, status == 403 || status == 429 else {
        return nil
    }
    // Primary limit: the quota is spent. `x-ratelimit-reset` is Unix seconds.
    if status == 403, headers["x-ratelimit-remaining"] == "0" {
        guard let reset = headers["x-ratelimit-reset"].flatMap(Double.init) else { return nil }
        return Date(timeIntervalSince1970: reset)
    }
    // Secondary limit (abuse detection): seconds from now, not a timestamp.
    if let retryAfter = headers["retry-after"].flatMap(Double.init) {
        return now.addingTimeInterval(retryAfter)
    }
    return nil
}

private let maxMessageLength = 120

/// One line fit for the header. A body that opens like a document rather than a
/// sentence — the HTML page a gateway sends when it gives up — is replaced by
/// the status it arrived under; a real sentence is kept, clipped at a word.
public func describeError(_ error: any Error) -> String {
    let raw: String
    if let gh = error as? GitHubError {
        switch gh {
        case let .http(_, message, _): raw = message
        case let .network(message): raw = message
        case let .graphql(messages, _): raw = messages.joined(separator: "; ")
        case let .malformed(message): raw = message
        }
    } else {
        raw = error.localizedDescription
    }

    let message = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    if message.isEmpty || message.first.map({ "<{[".contains($0) }) == true {
        guard let status = (error as? GitHubError)?.status else { return "Couldn't reach GitHub" }
        return "Couldn't reach GitHub — HTTP \(status)"
    }
    if message.count <= maxMessageLength { return message }
    let cut = String(message.prefix(maxMessageLength))
    guard let lastSpace = cut.lastIndex(of: " ") else { return cut + "…" }
    return String(cut[..<lastSpace]) + "…"
}

// MARK: - OAuth App access restrictions

private let restrictionPattern = "the `([^`]+)` organization has enabled OAuth App access restrictions"

private func restrictionRegex() -> NSRegularExpression {
    // A constant pattern; it cannot fail to compile.
    try! NSRegularExpression(pattern: restrictionPattern, options: [.caseInsensitive])
}

/// Orgs GitHub named in an OAuth-app restriction error, sorted for stable copy.
public func restrictedOrganizations(_ error: any Error) -> [String] {
    guard let gh = error as? GitHubError else { return [] }
    let regex = restrictionRegex()
    var orgs = Set<String>()
    for text in gh.messages {
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let range = Range(match.range(at: 1), in: text) { orgs.insert(String(text[range])) }
        }
    }
    return orgs.sorted()
}

/// Whether a restriction is the *only* thing that went wrong. GitHub can report
/// a timeout or a bad field in the same response as the locked-down org, and
/// dropping such a bucket for "one org is restricted" would hide a real failure.
public func isOnlyRestriction(_ error: any Error) -> Bool {
    guard let gh = error as? GitHubError else { return false }
    guard case let .graphql(messages, _) = gh else { return !restrictedOrganizations(gh).isEmpty }
    let regex = restrictionRegex()
    return !messages.isEmpty && messages.allSatisfy {
        regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
    }
}

/// The `data` a GraphQL error response still carried.
public func graphqlPartialData(_ error: (any Error)?) -> Data? {
    if case let .graphql(_, data)? = error as? GitHubError { return data }
    return nil
}

/// Union of org names, deduplicated and sorted so the warning copy is stable.
public func mergeOrgs(_ lists: [String]...) -> [String] {
    mergeOrgs(lists)
}

public func mergeOrgs(_ lists: [[String]]) -> [String] {
    Array(Set(lists.flatMap { $0 })).sorted()
}

public func formatRestrictedOrgs(_ orgs: [String]) -> String? {
    switch orgs.count {
    case 0: nil
    case 1: "\(orgs[0]) hasn't approved Pullover"
    case 2: "\(orgs[0]) and \(orgs[1]) haven't approved Pullover"
    default: "\(orgs.dropLast().joined(separator: ", ")) and \(orgs.last!) haven't approved Pullover"
    }
}
