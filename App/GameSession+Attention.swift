import Foundation
import GameCore

// The attention queue (M1 §16 "Attention queue / Next"): what the viewer may want to deal with
// before ending the phase, in a fixed order. Next walks it from the item it visited last (or the
// unit selected by hand), opening the right panel or card; with nothing left it reads End Turn.
// Return with items pending asks once per game "N items need attention — End Turn?".
//
// Items come from the viewer's knowledge (`PlayerView`) and, for what only events say (a city
// attacked, war declared on the viewer, other important notices), from the notices' hook since
// the viewer's phase last ended. Items that only inform (a Settler waiting, upkeep, war declared,
// news, …) leave the queue once Next has shown them; decisions (production, research, a peace
// proposal answered or put aside, Keep/Raze) stay until made. A Settler waiting is shown once per
// wait: once Next (or the city's panel) has shown it, it stays out of the queue until that city's
// first item no longer waits.
//
// Where M1 is silent: "Settler waiting" and "production blocked" are about the first item of a
// city's queue (what the player chose to build next); "city under attack" is a city attacked
// since the viewer's last phase or with a visible enemy military unit next to it; important
// notices no kind covers (a city lost, starving, an own unit hurt or lost, a civilian captured,
// units disbanded, a civilisation fallen, peace signed, a tribal village's gift the viewer's own
// tap did not take) join the queue last as news, one item per hurt unit however many blows it
// took, its loss included (the loss replaces the item and keeps its blows). A tech learnt is not
// news: Choose Research stops for it, and the research panel's header names it.

/// The tech the viewer learnt last, and in which turn (the research panel's header says it in
/// that turn).
struct LearntTech: Equatable, Sendable {
    var tech: TechID
    var turn: Int
}

/// One thing that needs the viewer's attention, in the queue's order.
enum AttentionItem: Hashable, Sendable {
    case unit(UnitID)
    case emptyQueue(CityID)
    case research
    /// A unit (the Settler) first in the queue waits for the city to grow.
    case settlerWaiting(CityID)
    /// The unit first in the queue has no tile to appear on.
    case productionBlocked(CityID)
    /// Upkeep will disband units at the start of the viewer's next phase.
    case upkeep
    case cityUnderAttack(CityID)
    case bombard(CityID)
    case peaceProposal(PlayerID)
    case warDeclared(PlayerID)
    /// A city captured this phase: keep or raze.
    case capturedCity(CityID)
    /// An important notice no other kind covers, by notice id.
    case news(Int)
    /// An own unit has the experience for a promotion (M2 §8.3).
    case promotion(UnitID)
    /// An own city below Content (M2 §5.2).
    case unstable(CityID)

    /// The queue's order: the kind (as listed in M1 §16), then its subject.
    struct Key: Comparable {
        var rank: Int
        var subject: Int

        static func < (a: Key, b: Key) -> Bool { (a.rank, a.subject) < (b.rank, b.subject) }
    }

    var key: Key {
        switch self {
        case let .unit(id): Key(rank: 0, subject: id.rawValue)
        case let .emptyQueue(id): Key(rank: 1, subject: id.rawValue)
        case .research: Key(rank: 2, subject: 0)
        case let .settlerWaiting(id): Key(rank: 3, subject: id.rawValue)
        case let .productionBlocked(id): Key(rank: 4, subject: id.rawValue)
        case .upkeep: Key(rank: 5, subject: 0)
        case let .cityUnderAttack(id): Key(rank: 6, subject: id.rawValue)
        case let .bombard(id): Key(rank: 7, subject: id.rawValue)
        case let .peaceProposal(id): Key(rank: 8, subject: id.rawValue)
        case let .warDeclared(id): Key(rank: 9, subject: id.rawValue)
        case let .capturedCity(id): Key(rank: 10, subject: id.rawValue)
        case let .news(id): Key(rank: 11, subject: id)
        case let .promotion(id): Key(rank: 12, subject: id.rawValue)
        case let .unstable(id): Key(rank: 13, subject: id.rawValue)
        }
    }

    /// Next's title when this item is next.
    var title: String {
        switch self {
        case .unit: "Next Unit"
        case .emptyQueue: "Choose Production"
        case .research: "Choose Research"
        case .settlerWaiting: "Settler Waiting"
        case .productionBlocked: "Production Blocked"
        case .upkeep: "Upkeep Warning"
        case .cityUnderAttack: "City Under Attack"
        case .bombard: "Bombard"
        case .peaceProposal: "Peace Proposal"
        case .warDeclared: "War Declared"
        case .capturedCity: "Keep or Raze"
        case .news: "News"
        case .promotion: "Promotion Due"
        case .unstable: "City Unrest"
        }
    }

    var systemImage: String {
        switch self {
        case .unit: "arrow.right.circle"
        case .emptyQueue: "hammer"
        case .research: "flask"
        case .settlerWaiting: "person.badge.clock"
        case .productionBlocked: "exclamationmark.triangle"
        case .upkeep: "circle.slash"
        case .cityUnderAttack: "shield.lefthalf.filled"
        case .bombard: "scope"
        case .peaceProposal: "envelope"
        case .warDeclared: "flame"
        case .capturedCity: "flag"
        case .news: "newspaper"
        case .promotion: "star.circle"
        case .unstable: "exclamationmark.bubble"
        }
    }

    /// Items that only inform: they leave the queue once shown.
    var isInformational: Bool {
        switch self {
        case .settlerWaiting, .productionBlocked, .upkeep, .cityUnderAttack, .bombard, .warDeclared, .news, .promotion, .unstable: true
        case .unit, .emptyQueue, .research, .peaceProposal, .capturedCity: false
        }
    }

    /// For automation and logs: "unit 4", "emptyQueue 2".
    var description: String {
        switch self {
        case let .unit(id): "unit \(id.rawValue)"
        case let .emptyQueue(id): "emptyQueue \(id.rawValue)"
        case .research: "research"
        case let .settlerWaiting(id): "settlerWaiting \(id.rawValue)"
        case let .productionBlocked(id): "productionBlocked \(id.rawValue)"
        case .upkeep: "upkeep"
        case let .cityUnderAttack(id): "cityUnderAttack \(id.rawValue)"
        case let .bombard(id): "bombard \(id.rawValue)"
        case let .peaceProposal(id): "peaceProposal \(id.rawValue)"
        case let .warDeclared(id): "warDeclared \(id.rawValue)"
        case let .capturedCity(id): "capturedCity \(id.rawValue)"
        case let .news(id): "news \(id)"
        case let .promotion(id): "promotion \(id.rawValue)"
        case let .unstable(id): "unstable \(id.rawValue)"
        }
    }
}

/// A card an attention item opens at the bottom of the screen.
enum AttentionCard: Hashable, Sendable {
    /// Keep or raze a city just captured.
    case capture(CityID)
    /// A peace proposal to answer.
    case peace(PlayerID)
    /// War declared on the viewer.
    case war(PlayerID)
    /// Units about to be disbanded for want of gold.
    case upkeep
    /// An important notice, by id.
    case news(Int)

    var name: String {
        switch self {
        case .capture: "keepOrRaze"
        case .peace: "peaceProposal"
        case .war: "warDeclared"
        case .upkeep: "upkeep"
        case .news: "news"
        }
    }
}

extension GameSession {
    // MARK: The queue

    /// Everything needing attention now, in the queue's order (empty outside the viewer's phase).
    var attentionItems: [AttentionItem] {
        guard isViewerPhase else { return [] }
        let view = self.view
        let cities = view.cities
        var items: [AttentionItem] = unitsNeedingOrders.map { .unit($0.id) }
        items += cities.filter(\.queue.isEmpty).map { .emptyQueue($0.id) }
        if view.me.researching == nil, view.rules.techs.contains(where: { !view.me.knows($0.id) }) {
            items.append(.research)
        }
        for city in cities {
            guard let head = city.queue.first, let wait = view.productionWait(head.item, in: city.id) else { continue }
            switch wait {
            case .population: if !settlerWaitShown.contains(city.id) { items.append(.settlerWaiting(city.id)) }
            case .noRoom, .resource: items.append(.productionBlocked(city.id))
            }
        }
        if view.upkeepForecast().disbanded > 0 { items.append(.upkeep) }
        let threatened = citiesAttacked.union(view.threatenedCities())
        items += cities.filter { threatened.contains($0.id) }.map { .cityUnderAttack($0.id) }
        items += cities.filter { !view.cityAttackOptions(for: $0.id).isEmpty }.map { .bombard($0.id) }
        items += view.peaceProposals.map { .peaceProposal($0) }
        items += warDeclaredBy.filter { view.isAtWar(with: $0) }.map { .warDeclared($0) }
        items += cities.filter { $0.capturedTurn == view.turn && !keptCities.contains($0.id) }.map { .capturedCity($0.id) }
        items += news.map { .news($0.id) }
        items += view.units.filter { !view.promotionsOffered($0.id).isEmpty }.map { .promotion($0.id) }
        items += cities.filter { (view.wellbeing(of: $0.id)?.state ?? .content) < .content }.map { .unstable($0.id) }
        return items.filter { !attentionSeen.contains($0) }
    }

    /// What Next visits now: the first item after where the walk stands, around again to the
    /// first; nil when nothing needs attention (Next reads End Turn).
    var nextAttentionItem: AttentionItem? { nextAttentionItem(in: attentionItems) }

    /// What Next visits among these items (the queue just computed: it is not cheap).
    func nextAttentionItem(in items: [AttentionItem]) -> AttentionItem? {
        guard let first = items.first else { return nil }
        guard let position = walkPosition else { return first }
        return items.first { $0.key > position.key } ?? first
    }

    /// Where the walk stands: a unit selected by hand, else the item Next visited last.
    private var walkPosition: AttentionItem? {
        if case let .unit(id)? = selection, attentionPosition != .unit(id) { return .unit(id) }
        return attentionPosition
    }

    /// Next (Space, the bronze button): visits the next item, or ends the phase when none is left.
    func performNextAction() {
        notices.acknowledge()
        guard isInputEnabled else {
            if let waiting = waitingFor { show("Waiting for \(waiting.civName)") }
            return
        }
        guard let item = nextAttentionItem else {
            endTurn()
            return
        }
        visit(item)
    }

    /// Shows an item: selects and centres what it is about, opens its panel or card.
    func visit(_ item: AttentionItem) {
        attentionPosition = item
        if item.isInformational { attentionSeen.insert(item) }
        let view = self.view
        switch item {
        case let .unit(id):
            select(.unit(id))
            if let unit = view.unit(id) { lookAt(unit.position) }
        case let .settlerWaiting(id):
            settlerWaitShown.insert(id)
            showCity(id)
            requestCityPanel(.production)
        case let .emptyQueue(id), let .productionBlocked(id):
            showCity(id)
            requestCityPanel(.production)
        case let .cityUnderAttack(id):
            showCity(id)
            requestCityPanel(.defence)
        case let .unstable(id):
            showCity(id)
            requestCityPanel(.overview)
        case let .bombard(id):
            showCity(id)
            beginBombard(id)
        case .research:
            openPanel = .research
        case .upkeep:
            deselect()
            attentionCard = .upkeep
        case let .peaceProposal(player):
            deselect()
            attentionCard = .peace(player)
        case let .warDeclared(player):
            deselect()
            attentionCard = .war(player)
        case let .capturedCity(id):
            showCity(id)
            attentionCard = .capture(id)
        case let .news(id):
            // News about an own unit (blows it took) selects it; the card shows over its card.
            let notice = news.first { $0.id == id }
            if case let .unit(unit)? = notice?.subject, let hurt = view.unit(unit), hurt.owner == viewer {
                select(.unit(unit))
                lookAt(hurt.position)
            } else {
                deselect()
                if let place = notice?.place { lookAt(place) }
            }
            attentionCard = .news(id)
        case let .promotion(id):
            select(.unit(id))
            if let unit = view.unit(id) { lookAt(unit.position) }
            promotingUnit = id
        }
    }

    /// Selects an own city and brings it to the middle of the open map.
    private func showCity(_ id: CityID) {
        select(.city(id))
        if let city = view.city(id) { lookAt(city.position) }
    }

    // MARK: Events

    /// The notices' hook (important and alarm notices, as they arrive): attacks on own cities
    /// and wars declared on the viewer feed their items; notices no item kind covers become news,
    /// blows on one unit one item. The viewer's own deeds (a peace it accepted) are not news to
    /// it; nor is a tech learnt (Choose Research stops for it; the research panel names it).
    func noteImportant(_ notice: Notice) {
        switch notice.kind {
        case .cityAttacked:
            if case let .city(id)? = notice.subject { citiesAttacked.insert(id) }
        case .warOnViewer:
            if case let .player(player)? = notice.subject, !warDeclaredBy.contains(player) { warDeclaredBy.append(player) }
        case .research:
            if case let .tech(tech)? = notice.subject { lastResearched = LearntTech(tech: tech, turn: notice.turn) }
        case .peaceProposal, .cityTaken:
            break // their own items: the proposal, Keep/Raze
        case .tribalVillageGift:
            // Important only when the viewer's own tap did not take it (NoticeMaker): a gift an
            // Explore leg found is news although that leg was posted as the viewer's command.
            appendNews(notice)
        case .unitAttacked:
            guard !postingViewerNotices else { return }
            // Later blows on a unit join its item while it has not been shown.
            if let unit = notice.damage?.unit,
               let i = news.firstIndex(where: { $0.damage?.unit == unit && !attentionSeen.contains(.news($0.id)) }) {
                news[i].absorbBlows(notice)
            } else {
                appendNews(notice)
            }
        case .unitLost:
            guard !postingViewerNotices else { return }
            // A loss takes the place of its unit's item of blows while that has not been shown,
            // keeping the blows: one item per unit, whether the blows came in one batch or more.
            if case let .unit(unit)? = notice.subject,
               let i = news.firstIndex(where: { $0.damage?.unit == unit && !attentionSeen.contains(.news($0.id)) }) {
                var loss = notice
                loss.absorbEarlierBlows(news[i])
                news[i] = loss
            } else {
                appendNews(notice)
            }
        default:
            guard !postingViewerNotices else { return }
            appendNews(notice)
        }
    }

    private func appendNews(_ notice: Notice) {
        news.append(notice)
        if news.count > Self.newsLimit { news.removeFirst(news.count - Self.newsLimit) }
    }

    /// After every change of the state (the end of `stateChanged`): what the viewer knows of
    /// units is kept for the next events' notices, and a city whose first item no longer waits
    /// for population will have its next wait shown again.
    func afterStateChange() {
        let view = self.view
        unitsBefore = UnitsBefore(view)
        if !settlerWaitShown.isEmpty {
            settlerWaitShown = settlerWaitShown.filter { headWaitsForPopulation($0, view) }
        }
        watchTroops(view)
    }

    /// The first state change of a phase: if it is the viewer's (its phase has just begun),
    /// foreign troops newly near its cities get a notice (`TroopWatch`). The session's first
    /// look, in the middle of any phase (a new game, a save resumed), only notes what is near.
    private func watchTroops(_ view: PlayerView) {
        let phase = view.phaseCount
        guard notices.troopWatch.phase != phase else { return }
        let firstLook = notices.troopWatch.phase == nil
        notices.troopWatch.phase = phase
        if firstLook {
            notices.troopWatch.remember(view.foreignMilitaryNear(radius: TroopWatch.radius))
            return
        }
        guard isViewerPhase else { return }
        let near = view.foreignMilitaryNear(radius: TroopWatch.radius)
        let underAttack = citiesAttacked.union(view.threatenedCities())
        notices.post(notices.troopWatch.notices(for: near, view: view, underAttack: underAttack, civName: civName(of:)))
    }

    /// The city's panel was shown: a Settler waiting first in its queue has been seen.
    func noteCityPanelShown(_ id: CityID) {
        if headWaitsForPopulation(id, view) { settlerWaitShown.insert(id) }
    }

    private func headWaitsForPopulation(_ id: CityID, _ view: PlayerView) -> Bool {
        guard let city = view.city(id), let head = city.queue.first, case .population? = view.productionWait(head.item, in: id) else {
            return false
        }
        return true
    }

    static let newsLimit = 12

    /// The viewer's phase ends: what was noted for it is cleared, and the foreign troops near
    /// its cities are known (only troops that come near later get a notice).
    func resetPhaseAttention() {
        if isViewerPhase { notices.troopWatch.remember(view.foreignMilitaryNear(radius: TroopWatch.radius)) }
        attentionSeen = []
        attentionPosition = nil
        citiesAttacked = []
        warDeclaredBy = []
        news = []
        keptCities = []
        attentionCard = nil
        endTurnPrompt = nil
    }

    /// The notice of a news item.
    func newsNotice(_ id: Int) -> Notice? {
        news.first { $0.id == id }
    }

    // MARK: Cards

    /// Closes the attention card without a decision: what it told is seen; a peace proposal
    /// stays answerable in Diplomacy; Keep/Raze stays in the queue while the city may be razed.
    func closeAttentionCard() {
        guard let card = attentionCard else { return }
        switch card {
        case let .peace(player): attentionSeen.insert(.peaceProposal(player))
        case let .war(player): attentionSeen.insert(.warDeclared(player))
        case .upkeep: attentionSeen.insert(.upkeep)
        case let .news(id): attentionSeen.insert(.news(id))
        case .capture: break
        }
        attentionCard = nil
    }

    /// Keeps a city just captured: it joins the viewer's cities with its production list open
    /// (its queue was cleared by the capture).
    func keepCity(_ id: CityID) {
        keptCities.insert(id)
        attentionCard = nil
        if view.city(id) != nil {
            select(.city(id))
            requestCityPanel(.production)
        }
    }

    /// Asks before razing (M1 §16 confirmations).
    func askToRaze(_ id: CityID) {
        guard isInputEnabled else {
            perform(.razeCity(city: id)) // says why not
            return
        }
        if let problem = view.razeProblem(id) {
            show(problem.prefix(1).uppercased() + problem.dropFirst())
            return
        }
        pendingRaze = id
    }

    func confirmRaze() {
        guard let id = pendingRaze else { return }
        pendingRaze = nil
        if perform(.razeCity(city: id)) {
            attentionCard = nil
            keptCities.remove(id)
        }
    }

    /// Answers a peace proposal from the card or the diplomacy sheet.
    func answerPeace(from player: PlayerID, accept: Bool) {
        if perform(.respondToPeace(from: player, accept: accept)), attentionCard == .peace(player) {
            attentionCard = nil
        }
    }

    /// Asks before declaring war (M1 §16 confirmations).
    func askToDeclareWar(on player: PlayerID) {
        guard isInputEnabled else {
            perform(.declareWar(on: player)) // says why not
            return
        }
        if let problem = view.warProblem(on: player) {
            show(problem.prefix(1).uppercased() + problem.dropFirst())
            return
        }
        pendingWar = player
    }

    func confirmWar() {
        guard let player = pendingWar else { return }
        pendingWar = nil
        perform(.declareWar(on: player))
    }

    func proposePeace(to player: PlayerID) {
        if perform(.proposePeace(to: player)) { show("Peace proposed to \(civName(of: player))") }
    }

    // MARK: Disband

    /// Asks before disbanding (M1 §16 confirmations).
    func askToDisband(_ id: UnitID) {
        guard isInputEnabled else {
            perform(.disband(unit: id)) // says why not
            return
        }
        pendingDisband = id
    }

    func confirmDisband() {
        guard let id = pendingDisband else { return }
        pendingDisband = nil
        perform(.disband(unit: id))
    }

    // MARK: End Turn

    /// Return (and End Turn from Next's menu): ends the phase, but with items pending first asks
    /// once per game "N items need attention — End Turn?" (M1 §16).
    func requestEndTurn() {
        notices.acknowledge()
        guard isInputEnabled else {
            if let waiting = waitingFor { show("Waiting for \(waiting.civName)") }
            return
        }
        let pending = attentionItems.count
        if pending > 0, !endTurnAsked {
            endTurnAsked = true
            Self.noteEndTurnQuestionAsked(in: state)
            endTurnPrompt = pending
            return
        }
        endTurn()
    }

    /// The question's answer: End Turn, or keep playing.
    func answerEndTurnPrompt(endTurn: Bool) {
        endTurnPrompt = nil
        if endTurn { self.endTurn() }
    }

    /// The games (by seed, map size and civs) in which the question was asked, so it is asked
    /// once per game, across saves and launches.
    static let endTurnAskedKey = "endTurnQuestionAsked"

    private static func gameKey(_ state: GameState) -> String {
        "\(state.seed)|\(state.mapSizeName)|" + state.players.map(\.civ.rawValue).joined(separator: ",")
    }

    static func endTurnQuestionAsked(in state: GameState) -> Bool {
        (UserDefaults.standard.stringArray(forKey: endTurnAskedKey) ?? []).contains(gameKey(state))
    }

    static func noteEndTurnQuestionAsked(in state: GameState) {
        var keys = UserDefaults.standard.stringArray(forKey: endTurnAskedKey) ?? []
        keys.removeAll { $0 == gameKey(state) }
        keys.append(gameKey(state))
        UserDefaults.standard.set(Array(keys.suffix(64)), forKey: endTurnAskedKey)
    }
}
