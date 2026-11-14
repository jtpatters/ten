import GameCore

/// A purchase waiting for the player's word: it costs more than half the treasury (M1 §16).
struct PurchaseRequest: Equatable {
    var city: CityID
    var item: ProductionItem
    var name: String
    var price: Int
    var gold: Int
}

/// What the city panel opens on.
enum CityPanelFocus: Equatable {
    /// The city at a glance (on iPhone, the sheet at its 35% detent).
    case overview
    /// The production list (a city just founded, an empty queue): on iPhone, the large detent.
    case production
    /// The yields by source.
    case yields
    /// Strength, health, garrison and Bombard (a city under attack).
    case defence
}

/// A request to the city panel; the token changes with every request, so the same focus can be
/// asked for twice.
struct CityPanelRequest: Equatable {
    var focus: CityPanelFocus
    var token: Int
}

// The city panel's commands (M1 §16): the queue (add, remove, reorder), buying (asking first
// above half the treasury), focus, and bombard target mode. Each goes through `perform`, so in
// another player's phase it answers "Waiting for <civ>".
extension GameSession {
    // MARK: Panel

    /// Opens the selected city's panel on a part of it.
    func requestCityPanel(_ focus: CityPanelFocus) {
        cityPanelRequest = CityPanelRequest(focus: focus, token: cityPanelRequest.token &+ 1)
    }

    /// The own city whose panel is open: the selected city, unless its panel has stepped aside
    /// for bombard targeting. `compact`: on a phone (upright, where the panel is a sheet, or on
    /// its side, where card and side panel would leave the map a sliver between them) the panel
    /// also steps aside for a card (attention such as Keep/Raze, combat preview, tile, game over).
    func panelCity(compact: Bool) -> City? {
        guard let city = selectedCity, city.owner == viewer, bombardTargeting == nil, quarterPlacing == nil,
              tileBuying == nil else { return nil }
        if compact, attentionCard != nil || pendingAttack != nil || inspectedHex != nil || state.outcome != nil { return nil }
        return city
    }

    // MARK: Queue

    /// Adds an item at the end of a city's queue. The first item of an empty queue chosen from
    /// the production list returns the panel to its overview (the map shows again on iPhone).
    @discardableResult
    func enqueue(_ item: ProductionItem, in id: CityID) -> Bool {
        guard let city = view.city(id) else { return false }
        let wasEmpty = city.queue.isEmpty
        guard perform(.setQueue(city: id, items: city.queuedItems + [item])) else { return false }
        if wasEmpty, cityPanelRequest.focus == .production { requestCityPanel(.overview) }
        return true
    }

    /// Removes the queue entry at `index` (its progress goes to stored progress, M1 §5).
    @discardableResult
    func removeFromQueue(at index: Int, in id: CityID) -> Bool {
        guard let city = view.city(id), city.queue.indices.contains(index) else { return false }
        var items = city.queuedItems
        items.remove(at: index)
        return perform(.setQueue(city: id, items: items))
    }

    /// Moves the queue entry at `from` to `to` (entries keep their progress).
    @discardableResult
    func moveInQueue(from: Int, to: Int, in id: CityID) -> Bool {
        guard let city = view.city(id), city.queue.indices.contains(from), city.queue.indices.contains(to), from != to else { return false }
        var items = city.queuedItems
        let item = items.remove(at: from)
        items.insert(item, at: to)
        return perform(.setQueue(city: id, items: items))
    }

    // MARK: Buying

    /// Buys an item, asking first when it costs more than half the treasury; an item that cannot
    /// be bought says why.
    func buy(_ item: ProductionItem, in id: CityID) {
        guard isInputEnabled else {
            perform(.purchase(city: id, item: item)) // says why not
            return
        }
        guard let option = view.productionOptions(for: id).first(where: { $0.item == item }) else { return }
        if let problem = option.buyProblem {
            show("Can't buy \(ItemName.withArticle(item, rules: state.rules)): \(problem)")
            return
        }
        let gold = view.me.gold
        if option.buyPrice * 2 > gold {
            pendingPurchase = PurchaseRequest(city: id, item: item, name: option.name, price: option.buyPrice, gold: gold)
            return
        }
        perform(.purchase(city: id, item: item))
    }

    func confirmPurchase() {
        guard let request = pendingPurchase else { return }
        pendingPurchase = nil
        perform(.purchase(city: request.city, item: request.item))
    }

    // MARK: Focus

    func setFocus(_ focus: CityFocus, of id: CityID) {
        guard view.city(id)?.focus != focus || !isInputEnabled else { return }
        perform(.setFocus(city: id, focus: focus))
    }

    // MARK: Bombard

    /// Why a city may not bombard now (nil: it may), for the panel's Bombard button.
    func bombardProblem(_ id: CityID) -> String? {
        guard let city = view.city(id) else { return "not your city" }
        if let waiting = waitingFor { return "waiting for \(waiting.civName)" }
        if city.bombarded { return "it has bombarded this turn" }
        if view.cityAttackOptions(for: id).isEmpty { return "no enemy in range (2 tiles)" }
        return nil
    }

    /// Bombard (M1 §16): the panel steps aside and the map becomes the target picker; with a
    /// single target its combat preview opens at once.
    func beginBombard(_ id: CityID) {
        if let problem = bombardProblem(id) {
            show("Can't bombard: \(problem)")
            return
        }
        if selection != .city(id) { select(.city(id)) }
        bombardTargeting = id
        let options = view.cityAttackOptions(for: id)
        if options.count == 1 { previewAttack(options[0]) }
        refreshSelection()
    }

    /// Leaves bombard target mode; the panel returns.
    func endBombard() {
        if case .city? = pendingAttack?.attacker { cancelAttack() }
        bombardTargeting = nil
    }

    // MARK: Quarters

    /// A quarter's tile choice (M2 §18.2): the panel steps aside and the map marks the legal
    /// sites with their adjacency; a tap on one queues the quarter there.
    func beginQuarter(_ kind: QuarterKind, in id: CityID) {
        guard let option = view.quarterOptions(for: id).first(where: { $0.kind == kind }) else { return }
        if let problem = option.problem ?? (isInputEnabled ? nil : "not your turn") {
            show("Can't place a \(option.name): \(problem)")
            return
        }
        if selection != .city(id) { select(.city(id)) }
        quarterPlacing = QuarterPlacing(city: id, kind: kind)
        refreshSelection()
    }

    /// Leaves the tile choice; the panel returns.
    func endQuarter() {
        quarterPlacing = nil
        refreshSelection()
    }

    /// The legal sites of the quarter being placed, best first.
    func quarterSites() -> [QuarterSite] {
        guard let placing = quarterPlacing else { return [] }
        return view.quarterOptions(for: placing.city).first { $0.kind == placing.kind }?.sites ?? []
    }

    /// A tap while placing: a marked site queues the quarter there and the panel returns on its
    /// production; elsewhere it says to tap a marked tile.
    func placeQuarter(at hex: HexCoord) {
        guard let placing = quarterPlacing else { return }
        let name = state.rules.quarter(placing.kind)?.name ?? placing.kind.rawValue
        guard quarterSites().contains(where: { $0.tile == hex }) else {
            show("Tap a marked tile for the \(name), or Cancel")
            return
        }
        quarterPlacing = nil
        if enqueue(.quarter(placing.kind, at: hex), in: placing.city) { requestCityPanel(.production) }
        refreshSelection()
    }
}

// MARK: Buying tiles

extension GameSession {
    /// Buy tile (M2 §7.4): the panel steps aside and the map marks the tiles the city could buy,
    /// with the price; a tap on one buys it.
    func beginBuyTile(in id: CityID) {
        guard let purchase = view.tilePurchase(of: id) else { return }
        if let problem = purchase.problem ?? (isInputEnabled ? nil : "not your turn") {
            show("Can't buy a tile: \(problem)")
            return
        }
        if selection != .city(id) { select(.city(id)) }
        quarterPlacing = nil
        tileBuying = id
        refreshSelection()
    }

    /// Leaves the tile choice; the panel returns.
    func endBuyTile() {
        tileBuying = nil
        refreshSelection()
    }

    /// A tap while buying: a marked tile is bought and the panel returns; elsewhere it says to
    /// tap a marked tile.
    func buyTile(at hex: HexCoord) {
        guard let id = tileBuying, let purchase = view.tilePurchase(of: id) else {
            endBuyTile()
            return
        }
        guard purchase.tiles.contains(hex) else {
            show("Tap a marked tile to buy it, or Cancel")
            return
        }
        tileBuying = nil
        if perform(.purchaseTile(city: id, tile: hex)) { show("Bought a tile for \(purchase.price) Gold") }
        refreshSelection()
    }
}

/// A city choosing a quarter's tile.
struct QuarterPlacing: Equatable {
    var city: CityID
    var kind: QuarterKind
}
