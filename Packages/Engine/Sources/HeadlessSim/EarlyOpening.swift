// p3f core-opening-tempo: the opening from player 0's seat in one `--early` summary line — when
// its second and third cities are founded and how many of turns 1–19 are quiet (before the
// second city, under the p3e rules). Observes only, from the `EarlyRecord`s.

extension EarlySummary {
    static func printOpening(_ records: [EarlyRecord]) {
        let n = records.count
        guard n > 0 else { return }
        let second = records.compactMap { $0.p0Founded.count > 1 ? $0.p0Founded[1] : nil }
        let third = records.compactMap { $0.p0Founded.count > 2 ? $0.p0Founded[2] : nil }
        let quiet = records.map { r in 19 - r.activeTurns.filter { $0 <= 19 }.count }
        Swift.print("  p0's cities: second founded median t\(median(second)) (none: \(n - second.count)), third median "
            + "t\(median(third)) (none: \(n - third.count)); quiet turns t1–t19: mean \(mean(quiet, over: n))")
    }
}
