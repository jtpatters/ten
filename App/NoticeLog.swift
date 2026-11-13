import GameCore
import SwiftUI

/// The notices log (M1 §16 "Notifications"), from the game menu: every notice the viewer has
/// received (the last `NoticeCenter.logLimit`; a save keeps its last `NoticeLogStore.limit`,
/// which Load and Continue bring back), grouped by turn, newest first.
/// A row that happened somewhere closes the log and shows the place. Opening it (and closing
/// it) reads every row: the menu's unread badge clears.
struct NoticeLog: View {
    let session: GameSession
    var onDone: () -> Void

    /// One turn's notices, newest first.
    struct Turn: Identifiable {
        var turn: Int
        var notices: [Notice]
        var id: Int { turn }
    }

    /// The log grouped by turn, newest first (the log is in arrival order, turns rising).
    static func turns(_ log: [Notice]) -> [Turn] {
        var turns: [Turn] = []
        for notice in log.reversed() {
            if let last = turns.indices.last, turns[last].turn == notice.turn {
                turns[last].notices.append(notice)
            } else {
                turns.append(Turn(turn: notice.turn, notices: [notice]))
            }
        }
        return turns
    }

    var body: some View {
        let turns = Self.turns(session.notices.log)
        let now = session.view.turn
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Notices", systemImage: "list.bullet.rectangle", onClose: onDone)
                .padding(.horizontal, HUD.Space.l)
                .padding(.top, HUD.Space.l)
                .padding(.bottom, HUD.Space.s)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: HUD.Space.m) {
                    if turns.isEmpty {
                        Text("No notices yet. What happens in the game (growth, battles, discoveries) is listed here.")
                            .font(HUD.body())
                            .foregroundStyle(HUD.inkSoft)
                            .padding(.vertical, HUD.Space.s)
                    }
                    ForEach(turns) { turn in
                        VStack(alignment: .leading, spacing: HUD.Space.xs) {
                            SectionHeader(title: turn.turn == now ? "Turn \(turn.turn) · this turn" : "Turn \(turn.turn)")
                            ForEach(turn.notices) { notice in
                                row(notice)
                            }
                        }
                    }
                    Text("The last \(NoticeCenter.logLimit) notices; a saved game keeps its last \(NoticeLogStore.limit).")
                        .font(HUD.body(.caption2))
                        .foregroundStyle(HUD.inkSoft)
                        .padding(.top, HUD.Space.xs)
                }
                .padding(.horizontal, HUD.Space.l)
                .padding(.bottom, HUD.Space.xl)
            }
        }
        .foregroundStyle(HUD.ink)
        .onAppear { session.notices.startUnreadCount() }
        .onDisappear { session.notices.startUnreadCount() }
    }

    @ViewBuilder
    private func row(_ notice: Notice) -> some View {
        let line = HStack(alignment: .firstTextBaseline, spacing: HUD.Space.s) {
            Image(systemName: notice.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint(notice.tone))
                .frame(width: 20)
            Text(notice.text)
                .font(HUD.body(.callout).weight(notice.importance >= .important ? .semibold : .regular))
                .foregroundStyle(notice.importance == .alarm ? HUD.danger : HUD.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: HUD.Space.s)
            if notice.place != nil {
                Image(systemName: "scope")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(HUD.inkSoft)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, HUD.Space.m)
        .padding(.vertical, HUD.Space.s)
        .frame(minHeight: HUD.touch)
        .background(RoundedRectangle(cornerRadius: HUD.Radius.small, style: .continuous).fill(HUD.parchmentWell))
        if notice.place != nil {
            Button {
                onDone()
                session.locate(notice)
            } label: {
                line.contentShape(Rectangle())
            }
            .buttonStyle(ChipButtonStyle())
            .accessibilityElement(children: .combine)
            .accessibilityHint("Shows where it happened.")
        } else {
            line.accessibilityElement(children: .combine)
        }
    }

    private func tint(_ tone: Notice.Tone) -> Color {
        switch tone {
        case .neutral: HUD.inkSoft
        case .good: HUD.good
        case .bad: HUD.danger
        }
    }
}

extension GameSession {
    /// A tap on a notices log row that happened somewhere (after the log closes; automation
    /// `noticelog locate`): the camera goes there.
    func locate(_ notice: Notice) {
        guard let place = notice.place else { return }
        noteMapTouched()
        lookAt(place)
    }
}

/// The count of unread notices on the game menu's button (M1 §16 "Notifications"): a small
/// red disc at its corner, "99+" beyond 99; nothing at 0.
struct UnreadBadge: View {
    var count: Int

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 5)
                .frame(minWidth: 20, minHeight: 20)
                .background(Capsule().fill(HUD.danger))
                .overlay(Capsule().stroke(HUD.parchmentTop, lineWidth: 1.5))
                .offset(x: 6, y: -6)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }
}
