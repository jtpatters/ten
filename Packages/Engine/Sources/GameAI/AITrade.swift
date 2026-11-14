import GameCore

extension AITurn {
    /// Each idle Trader starts the best route it can (M2 §19: route value over destinations),
    /// preferring a destination it does not trade with yet.
    mutating func useTraders() {
        let ids = view.units.filter { $0.type == .trader && $0.movesLeft > 0 }.map(\.id)
        for id in ids where live {
            let v = view
            let routed = v.myTradeRoutes.map(\.destination)
            let destinations = v.cities.map(\.id) + v.knownCities.map(\.id).filter { c in !v.cities.contains { $0.id == c } }
            var best: (value: Int, city: CityID)?
            for city in destinations where v.tradeRouteProblem(id, to: city) == nil {
                let value = v.tradeRouteValue(id, to: city) - (routed.contains(city) ? 3 : 0)
                if best == nil || value > best!.value || (value == best!.value && city < best!.city) { best = (value, city) }
            }
            guard let city = best?.city else { continue }
            note("starts a trade route to \(city)")
            issue(.startTradeRoute(unit: id, toCity: city))
        }
    }

    /// Whether `city` should build a Trader: routes, Traders and Traders queued elsewhere are
    /// below the capacity.
    func wantsTrader(_ city: City, _ v: PlayerView) -> Bool {
        guard rules.trade != nil else { return false }
        let queued = v.cities.filter { $0.id != city.id }.reduce(0) { n, c in n + c.queue.count { $0.item == .unit(.trader) } }
        return v.myTradeRoutes.count + v.units.count { $0.type == .trader } + queued < v.tradeCapacity
    }
}
