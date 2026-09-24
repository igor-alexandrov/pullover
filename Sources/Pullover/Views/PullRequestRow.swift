import PulloverCore
import SwiftUI

/// One pull request. Comfortable is two lines — the meta line over the title;
/// compact fits one, dropping the repository, the age and the diff counts,
/// the three that least often decide whether to open a PR.
struct PullRequestRow: View {
    var model: AppModel
    var row: StackCardRow
    var compact: Bool

    private var item: ClassifiedPullRequest { row.item }
    private var pr: PullRequest { row.item.pr }
    private var isActive: Bool { model.selectedID == item.id }

    // The connector's geometry is derived from these, so changing the padding
    // or the avatar moves the line with it.
    private var avatarSize: CGFloat { compact ? 20 : 28 }
    private var leadingInset: CGFloat { compact ? 8 : 6 }
    private var rowHeight: CGFloat { compact ? 30 : 56 }

    var body: some View {
        HStack(spacing: compact ? 8 : 10) {
            AvatarView(login: pr.authorLogin, urlString: pr.authorAvatarURL, size: avatarSize)
            if compact { compactContent } else { comfortableContent }
        }
        .padding(.horizontal, leadingInset)
        .frame(height: rowHeight)
        .background(alignment: .leading) {
            StackConnector(row: row, avatarSize: avatarSize, fadeBelowLength: compact ? nil : 12)
                .frame(width: 2)
                .padding(.leading, leadingInset + avatarSize / 2 - 1)
        }
        .background(isActive ? Metrics.selection : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { inside in if inside { model.pointAt(item.id) } }
        .onTapGesture { model.open(item) }
        .contextMenu { PRMenuItems(model: model, item: item) }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { RowFrames.shared.frames[item.id] = geometry.frame(in: .global) }
                    .onChange(of: geometry.frame(in: .global)) { _, frame in RowFrames.shared.frames[item.id] = frame }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .animation(.easeOut(duration: 0.12), value: isActive)
    }

    private var comfortableContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                // The owner is dropped: it is the same for most of the list.
                // It comes back on hover, where two same-named repos differ.
                Text(repositoryName(pr.repository))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(pr.repository)
                    .layoutPriority(-1)
                HStack(spacing: 4) {
                    Text(verbatim: "#\(pr.number)")
                        .foregroundStyle(.blue)
                        .monospacedDigit()
                    if let stack = item.stack { StackBadge(stack: stack) }
                }
                .fixedSize()
                MetaDot()
                // Also what the section is sorted by, so the top row says why
                // it is the top row. The `waiting` section has no such time.
                Text(item.waitingSince.map { formatWaiting($0, now: model.now) } ?? formatAge(pr.updatedAt, now: model.now))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
                MetaDot()
                HStack(spacing: 4) {
                    Text(verbatim: "+\(pr.additions)").foregroundStyle(.green)
                    Text(verbatim: "−\(pr.deletions)").foregroundStyle(.red)
                }
                .fontWeight(.semibold)
                .monospacedDigit()
                .fixedSize()
                Spacer(minLength: 0)
                // Always in the layout, only revealed when active, so moving
                // between rows never reflows them.
                Menu {
                    PRMenuItems(model: model, item: item)
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .opacity(isActive ? 1 : 0)
                .help("Actions — M")
            }
            .font(.caption)
            .frame(height: 15)

            HStack(spacing: 8) {
                Text(pr.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(pr.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                RowStatus(ci: pr.ciStatus, reason: item.reason)
            }
            .frame(height: 20)
        }
    }

    private var compactContent: some View {
        HStack(spacing: 8) {
            Text(verbatim: "#\(pr.number)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help(pr.repository)
                .fixedSize()
            Text(pr.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(pr.title)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let stack = item.stack {
                HStack(spacing: 3) {
                    Image(systemName: "square.stack.3d.up").font(.system(size: 9, weight: .semibold))
                    Text(verbatim: "\(stack.index)/\(stack.total)").font(.caption.weight(.semibold)).monospacedDigit()
                }
                .foregroundStyle(.blue)
                .fixedSize()
            }
            RowStatus(ci: pr.ciStatus, reason: item.reason)
        }
    }
}

/// The CI chip and the reason, right-aligned on the title line. The reason is
/// never clipped — the title yields instead, and every reason is short.
struct RowStatus: View {
    var ci: CIStatus
    var reason: String

    var body: some View {
        HStack(spacing: 7) {
            CIChip(status: ci)
            if !reason.isEmpty {
                Text(reason)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusAccent(for: reason).color)
            }
        }
        .fixedSize()
    }
}

struct CIChip: View {
    var status: CIStatus

    var body: some View {
        if let (symbol, accent, label) = appearance {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(accent.color)
                .frame(width: 16, height: 16)
                .background(accent.tint, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .help(label)
                .accessibilityLabel(label)
        }
    }

    private var appearance: (String, Accent, String)? {
        switch status {
        case .success: ("checkmark", .positive, "CI green")
        case .failure: ("xmark", .critical, "CI failing")
        case .pending: ("clock", .warning, "CI running")
        case .none: nil
        }
    }
}

struct StackBadge: View {
    var stack: StackPosition

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 8, weight: .semibold))
            Text(verbatim: "\(stack.index)/\(stack.total)").font(.system(size: 10, weight: .bold)).monospacedDigit()
        }
        .foregroundStyle(.blue)
        .padding(.horizontal, 6)
        .frame(height: 16)
        .background(Accent.primary.tint, in: Capsule())
        .help("Part \(stack.index) of a stack of \(stack.total)")
    }
}

struct MetaDot: View {
    var body: some View {
        Text("·").foregroundStyle(.secondary).opacity(0.5)
    }
}

struct PRMenuItems: View {
    var model: AppModel
    var item: ClassifiedPullRequest

    var body: some View {
        ForEach(Array(prMenuEntries(isSnoozed: item.isSnoozed).enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .separator:
                Divider()
            case let .item(label, action):
                Button(label) { model.perform(action, on: item) }
            }
        }
    }
}

struct AvatarView: View {
    var login: String
    var urlString: String
    var size: CGFloat

    var body: some View {
        AsyncImage(url: sizedURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Accent.primary.tint
                    Text(initials(of: login))
                        .font(.system(size: size * 0.36, weight: .semibold))
                        .foregroundStyle(.blue)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Metrics.hairline, lineWidth: 0.5))
    }

    /// GitHub serves avatars at any size; ask for the one drawn, at 2x.
    private var sizedURL: URL? {
        guard !urlString.isEmpty, var components = URLComponents(string: urlString) else { return nil }
        var query = components.queryItems ?? []
        query.removeAll { $0.name == "s" }
        query.append(URLQueryItem(name: "s", value: String(Int(size * 2))))
        components.queryItems = query
        return components.url
    }
}

/// The line behind the avatars joining a pull request to its stack, drawn
/// inside the row that owns it. Solid to an adjacent member, dotted across
/// members that aren't shown, fading out where the chain carries on past the
/// list with nothing to meet.
struct StackConnector: View {
    var row: StackCardRow
    var avatarSize: CGFloat
    /// Caps a fade below the avatar, where the segment is long enough that a
    /// full-length fade would smear across the row.
    var fadeBelowLength: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let avatarTop = (height - avatarSize) / 2
            let avatarBottom = avatarTop + avatarSize
            ZStack(alignment: .top) {
                if row.lineAbove {
                    segment(gap: row.gapAbove, open: row.gapAboveOpen, fadeDownward: false)
                        .frame(height: avatarTop)
                }
                if row.lineBelow {
                    let length = row.gapBelowOpen ? min(fadeBelowLength ?? .infinity, height - avatarBottom) : height - avatarBottom
                    segment(gap: row.gapBelow, open: row.gapBelowOpen, fadeDownward: true)
                        .frame(height: length)
                        .offset(y: avatarBottom)
                }
            }
            .frame(width: 2, height: height, alignment: .top)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func segment(gap: Bool, open: Bool, fadeDownward: Bool) -> some View {
        let color = Color.primary.opacity(0.18)
        if !gap {
            Rectangle().fill(color)
        } else if open {
            Rectangle().fill(LinearGradient(
                colors: [color, color.opacity(0)],
                startPoint: fadeDownward ? .top : .bottom,
                endPoint: fadeDownward ? .bottom : .top
            ))
        } else {
            DottedLine()
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.1, 4]))
                .rotationEffect(fadeDownward ? .zero : .degrees(180))
        }
    }
}

private struct DottedLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY + 2))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        }
    }
}
