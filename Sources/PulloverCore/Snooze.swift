import Foundation

/// A snooze parks a PR in the "waiting" section. It stays active until its own
/// wake condition fires.
public func isSnoozeActive(_ pr: PullRequest, _ snooze: Snooze, myLogin: String, now: Date) -> Bool {
    switch snooze.type {
    case .untilTime:
        guard let until = snooze.until else { return false }
        return now < until
    case .untilActivity:
        return !hasNewReplyInMyThreads(pr, myLogin: myLogin, since: snooze.snoozedAt)
            && pr.lastCommitPushedAt <= snooze.snoozedAt
    }
}
