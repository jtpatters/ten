import Foundation
import GameCore

// p3f (ai-after-city-loss), `--early`: what an AI does after it loses a city. In the iPhone
// play-test Rome lost Antium at T35 and then kept to its capital to T50, beside an empty north.
// Observes only, like the rest of `EarlyObserver` (games hash unchanged).
//
// For each AI seat's first lost city (seat 1; seat 0 too when an AI plays it, `--p0 ai`), an entry
// in `EarlyRecord.aiLosses`: [0] player, [1] turn lost, [2] own cities right after the loss, [3] and
// [4] cities at the end of turns 50 and 80 (−1: not reached), [5] cities 20 turns after the loss
// (−1: not reached), [6] cities founded in those 20 turns, [7] the turn it took the lost city back
// (−1: not), [8] the lost city's id.

extension EarlyObserver {
    /// Seats an AI plays: player 1, and player 0 when no stand-in plays it.
    func isAISeat(_ p: PlayerID) -> Bool { p == ai || (p == human && record.p0 == "ai") }

    /// One event (attributed to turn `t`), with the state after its command.
    mutating func afterLoss(_ event: GameEvent, turn t: Int, state: GameState) {
        switch event {
        case let .cityCaptured(city, _, from, to, _):
            if isAISeat(from), !record.aiLosses.contains(where: { $0[0] == from.rawValue }) {
                let cities = state.cities.filter { $0.owner == from }.count
                record.aiLosses.append([from.rawValue, t, cities, -1, -1, -1, 0, -1, city.rawValue])
            }
            if let k = record.aiLosses.firstIndex(where: { $0[0] == to.rawValue }), record.aiLosses[k][8] == city.rawValue,
               record.aiLosses[k][7] < 0 {
                record.aiLosses[k][7] = t
            }
        case let .cityFounded(_, _, owner, _):
            if let k = record.aiLosses.firstIndex(where: { $0[0] == owner.rawValue }), t <= record.aiLosses[k][1] + 20 {
                record.aiLosses[k][6] += 1
            }
        default:
            break
        }
    }

    /// The end of a phase: at the end of a turn (the last seat's phase), the losers' city counts.
    mutating func afterLossPhaseEnd(_ player: PlayerID, turn: Int, state: GameState) {
        guard player.rawValue == state.players.count - 1, !record.aiLosses.isEmpty else { return }
        for k in record.aiLosses.indices {
            let p = PlayerID(record.aiLosses[k][0])
            let cities = state.cities.filter { $0.owner == p }.count
            if turn == 50 { record.aiLosses[k][3] = cities }
            if turn == 80 { record.aiLosses[k][4] = cities }
            if turn == record.aiLosses[k][1] + 20 { record.aiLosses[k][5] = cities }
        }
    }
}

extension EarlySummary {
    /// "AI after losing a city": AI cities at t50 and t80 after a first loss by t50, and 20 turns
    /// after a first loss by t60.
    static func printAfterLoss(_ records: [EarlyRecord]) {
        let losses = records.flatMap(\.aiLosses)
        let by50 = losses.filter { $0[1] <= 50 }
        let by60 = losses.filter { $0[1] <= 60 && $0[5] >= 0 }
        func m(_ xs: [Int]) -> String { mean(xs, over: xs.count) }
        Swift.print("  AI after losing a city (first loss, AI seats): by t50 \(by50.count) (in \(records.filter { $0.aiLosses.contains { $0[1] <= 50 } }.count) games): "
            + "cities after the loss mean \(m(by50.map { $0[2] })), at t50 \(m(by50.map { $0[3] }.filter { $0 >= 0 })), "
            + "at t80 \(m(by50.map { $0[4] }.filter { $0 >= 0 })) (\(dist_(by50.map { $0[4] }.filter { $0 >= 0 }))); "
            + "by t60 \(by60.count): 20 turns later cities mean \(m(by60.map { $0[5] })) (after the loss \(m(by60.map { $0[2] }))), "
            + "founded a city in them \(by60.filter { $0[6] > 0 }.count), retook the city \(by60.filter { $0[7] >= 0 && $0[7] <= $0[1] + 20 }.count)")
    }
}
