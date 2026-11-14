import GameAI
import GameCore
import MapGen
import MapRendering
import Observation
import Persistence
import UIKit

/// One game on screen. Owns the authoritative `GameState`; the viewer is human player 0 and
/// every read the HUD makes goes through `view` (`state.view(for: viewer)`), so it never shows
/// what the viewer does not know. Diagnostic mode (fog off) may show everything.
///
/// Commands from the HUD go through `perform(_:)` (validated by `GameEngine`); after each one the
/// renderer gets the new state with the events the viewer may see, and the world inputs
/// (`MapAdapter`) and selection overlays are rebuilt once, never per frame. Other players'
/// phases run on a background copy and are replayed here with playback
/// (`GameSession+AI.swift`); saves follow M1 §14 (`GameSession+Saves.swift`).
@Observable
@MainActor
final class GameSession {
    private(set) var state: GameState
    let viewer = PlayerID(0)
    @ObservationIgnored let renderer: MapRenderer
    @ObservationIgnored let store: SaveStore

    /// Diagnostic mode: no fog, every event shown, live cities, borders and improvements.
    var diagnostic: Bool {
        didSet {
            guard diagnostic != oldValue else { return }
            renderer.fogEnabled = !diagnostic
            syncWorld()
            refreshSelection()
        }
    }

    // MARK: Selection

    enum Selection: Hashable {
        case unit(UnitID)
        case city(CityID)
    }

    /// An attack being previewed: who strikes, the target and the tile to strike from, and the
    /// odds.
    struct AttackPlan: Equatable {
        var attacker: Combatant
        var option: AttackOption
        var preview: CombatPreview?
    }

    private(set) var selection: Selection? {
        didSet { updateFocus() }
    }
    /// The route previewed for the selected unit (tap its end again to move).
    private(set) var pendingPath: Path? {
        didSet { updateFocus() }
    }
    /// The attack previewed (tap the target again, or Attack, to strike).
    private(set) var pendingAttack: AttackPlan? {
        didSet { updateFocus() }
    }
    /// A tile whose card is open: an info card (a tap on something foreign) or the tile sheet
    /// (long-press), as `inspectMode` says.
    private(set) var inspectedHex: HexCoord? {
        // With nothing selected, the selection ring marks the tile whose card is open.
        didSet {
            updateFocus()
            if selection == nil, inspectedHex != oldValue { refreshSelection() }
        }
    }

    enum InspectMode: Equatable {
        /// A foreign unit's or city's info card (M1 §16).
        case info
        /// The tile sheet: yields for the viewer, owner, defence modifiers (long-press).
        case tile
    }

    private(set) var inspectMode = InspectMode.info
    /// The action the unit card describes (a long-press on it, or a tap on one that cannot be
    /// done now).
    var describedAction: UnitActionKind?
    /// The unit whose card lists the promotions on offer (Promote, or Next's "Promotion Due").
    var promotingUnit: UnitID?

    // MARK: Phases

    /// Another player's phase being computed or played back: input waits for it.
    struct AIPhase: Equatable {
        var player: PlayerID
        var civName: String
    }

    /// Set by the playback in `GameSession+AI.swift`.
    var aiPhase: AIPhase?
    /// Play other players' phases without waiting for their animations.
    var quickAITurns: Bool {
        didSet { UserDefaults.standard.set(quickAITurns, forKey: Self.quickAIKey) }
    }
    /// Who plays the AI players (`AIDriver`).
    var aiDriver: AIDriver
    /// Reduce Motion: events land at once, damage numbers fade in place.
    var reduceMotion = false {
        didSet {
            renderer.animatesEvents = !reduceMotion
            overlay.reduceMotion = reduceMotion
        }
    }
    /// The scene is in the foreground (playback waits for animations only then).
    @ObservationIgnored var isSceneActive = true
    @ObservationIgnored var aiTask: Task<Void, Never>?
    /// During an AI phase: the state when it began (what a background save writes), and the
    /// command count then.
    @ObservationIgnored var phaseStartState: GameState?
    @ObservationIgnored var phaseStartCommandCount = 0
    @ObservationIgnored var lastMapTouch: ContinuousClock.Instant?
    /// What the panels cover (points), for centring and deciding what is on screen.
    @ObservationIgnored private(set) var mapInsets = UIEdgeInsets.zero

    // MARK: Saves

    /// Commands applied since this session began, and the count the newest save includes.
    @ObservationIgnored var commandCount = 0
    @ObservationIgnored var savedCommandCount = 0
    /// Saves being written.
    var pendingSaves = 0
    var hasUnsavedCommands: Bool { commandCount > savedCommandCount }
    /// The default name the Save prompt opened with (`save(named:)` renames it after the
    /// snapshot).
    @ObservationIgnored var saveNameDefault = ""
    /// The game's id, which its saves carry (M1 §14; GameSession+Saves.swift).
    @ObservationIgnored var gameID: String?

    // MARK: Messages and hooks

    /// A short message over the map (a refused command, "Saved"), cleared after a while.
    private(set) var message: String?
    @ObservationIgnored private var messageTask: Task<Void, Never>?
    @ObservationIgnored private var revealTask: Task<Void, Never>?
    /// Called with the records the viewer may see after every applied command (human or AI),
    /// for notifications and the attention queue.
    @ObservationIgnored var onEvents: (([EventRecord]) -> Void)?
    /// Bumps on every state change (a cheap identity for views that cache derived data).
    private(set) var revision = 0
    /// Notifications (M1 §16): visible events as calm toasts. Important ones also reach
    /// `notices.onImportant`, the attention queue's hook.
    let notices = NoticeCenter()
    /// City banners and damage numbers over the map (`MapOverlay`), placed every frame.
    @ObservationIgnored let overlay: MapOverlay
    /// For each combat the viewer may see, whose sides were hurt and who fell, noted when the
    /// events arrive (the units may be gone when the blow is shown).
    @ObservationIgnored private var combatSides: [EventRecord: CombatSides] = [:]
    /// For each of the viewer's own takes of a tribal village, the gift the same batch gave for
    /// it, noted when the events arrive and shown as a float label when the map shows the take
    /// (`eventShown`). Kept across batches: an Explore phase applies its legs back to back.
    @ObservationIgnored private var pendingGifts: [EventRecord: TribalVillageGift] = [:]

    struct CombatSides {
        var attackerOwn: Bool
        var defenderOwn: Bool
        var attackerKilled: Bool
        var defenderKilled: Bool
    }

    // MARK: Attention queue, cards and confirmations (GameSession+Attention.swift, +City.swift)

    /// The card of an attention item at the bottom of the screen (Keep/Raze, a peace proposal,
    /// war declared, upkeep, news).
    var attentionCard: AttentionCard?
    /// Informational items looked at in this phase: they leave the queue.
    var attentionSeen: Set<AttentionItem> = []
    /// The item Next visited last (the walk goes on after it).
    @ObservationIgnored var attentionPosition: AttentionItem?
    /// Own cities attacked, and players who declared war on the viewer, since the viewer's
    /// phase last ended (from the notices' hook).
    var citiesAttacked: Set<CityID> = []
    var warDeclaredBy: [PlayerID] = []
    /// Important notices since the viewer's phase last ended that no item kind covers.
    var news: [Notice] = []
    /// Notices being posted come from the viewer's own command.
    @ObservationIgnored var postingViewerNotices = false
    /// What the viewer knew of units before the latest events (the notices read it).
    @ObservationIgnored var unitsBefore = UnitsBefore()
    /// Cities whose waiting Settler the viewer has been shown: not shown again while the wait
    /// lasts (kept across phases).
    var settlerWaitShown: Set<CityID> = []
    /// The tech the viewer learnt last (the research panel's header).
    var lastResearched: LearntTech?
    /// Cities captured this phase that the viewer chose to keep.
    var keptCities: Set<CityID> = []
    /// "N items need attention — End Turn?" on screen, with N; asked once per game (M1 §16).
    var endTurnPrompt: Int?
    @ObservationIgnored var endTurnAsked = false
    /// A purchase waiting for confirmation (over half the treasury).
    var pendingPurchase: PurchaseRequest?
    var pendingRaze: CityID?
    var pendingWar: PlayerID?
    var pendingDisband: UnitID?
    /// "Load another game?" (commands since the newest save).
    var confirmingLoad = false
    /// The city choosing a bombard target: its panel steps aside and the map is the target picker.
    var bombardTargeting: CityID?
    /// What the city panel should show (a new city's production list); the token changes with
    /// every request.
    var cityPanelRequest = CityPanelRequest(focus: .overview, token: 0)
    /// The tech panel, diplomacy sheet or notices log, when open.
    var openPanel: Panel?
    /// The Save Game prompt and its name field.
    var isShowingSave = false
    var saveName = ""
    #if DEBUG
    /// Commands an AI player issues at the start of its next phase, before its driver plays
    /// (automation `aicommand`): to have it declare war or propose peace on cue.
    @ObservationIgnored var debugPrelude: [PlayerID: [Command]] = [:]
    #endif

    // MARK: Display and benchmarks

    /// Frame stats and tile coordinates (developer readout).
    var showStats = false
    var flyover = false {
        didSet { renderer.setFlyover(flyover) }
    }
    var tilted = true {
        didSet { renderer.tilted = tilted }
    }
    var showGrid = true {
        didSet { renderer.showGrid = showGrid }
    }
    @ObservationIgnored private var stressRNG: SplitMix64
    @ObservationIgnored private var stressSpawns: UInt64 = 0
    private(set) var mapGenMilliseconds = 0
    /// Units on the Explore order (GameSession+Explore.swift).
    var explore = ExploreOrders()

    static let quickAIKey = "quickAITurns"

    init(state: GameState, store: SaveStore, diagnostic: Bool, mapGenMilliseconds: Int = 0) {
        self.state = state
        self.store = store
        self.diagnostic = diagnostic
        self.mapGenMilliseconds = mapGenMilliseconds
        renderer = MapRenderer(state: state, viewer: PlayerID(0))
        renderer.fogEnabled = !diagnostic
        overlay = MapOverlay(frame: .zero)
        quickAITurns = UserDefaults.standard.bool(forKey: Self.quickAIKey)
        aiDriver = AIDriver.launchDefault
        stressRNG = SplitMix64(seed: state.seed, salts: 0x57E55)
        syncWorld()
        unitsBefore = UnitsBefore(view)
        centerOnViewer(animated: false)
        wireOverlay()
        notices.onImportant = { [weak self] notice in self?.noteImportant(notice) }
        endTurnAsked = Self.endTurnQuestionAsked(in: state)
    }

    /// The overlay follows the map every frame, builds its banners from the viewer's knowledge,
    /// and shows a damage number when a blow lands.
    private func wireOverlay() {
        overlay.renderer = renderer
        overlay.bannerSource = { [weak self] in self?.bannerModels() ?? [] }
        overlay.onActivateBanner = { [weak self] city in self?.tapBanner(city) }
        renderer.onFrame = { [weak overlay] in overlay?.frameDidDraw() }
        renderer.onEventShown = { [weak self] record, point in self?.eventShown(record, at: point) }
    }

    /// The banners as the viewer knows the cities (live ones in diagnostic mode).
    func bannerModels() -> [CityBannerModel] {
        // The selected city's banner wears the gilt rim; with nothing selected, the city whose
        // info card is open does (as its ring).
        let selected: CityID? = if case let .city(id)? = selection {
            id
        } else if selection == nil, let hex = inspectedHex {
            view.knownCity(at: hex)?.id
        } else {
            nil
        }
        return CityBannerModel.all(state: state, viewer: viewer, diagnostic: diagnostic, selected: selected)
    }

    /// Starts play: the viewer's phase, or first the other players' phases that come before it
    /// (a game loaded in an AI phase plays them before input is enabled, M1 §14). A new game's
    /// first phase is autosaved like every phase start; a save resumed in the viewer's phase is
    /// not saved again (no phase began).
    func begin(resumingSave: Bool = false) {
        if isViewerPhase {
            if !resumingSave {
                announceTribalVillages()
                humanPhaseBegan()
            }
        } else {
            playOtherPhases()
        }
    }

    /// A new game's first phase (turn 1): the tribal villages the viewer's start units see, in
    /// one notice with the rule (M1 §7.7). Later sightings are NoticeMaker's: `unitsBefore`,
    /// taken in `init`, already holds these, so they are never named twice. A resumed save says
    /// nothing.
    private func announceTribalVillages() {
        let view = self.view
        guard state.turn == 1, let sighting = view.tribalVillageSighting(view.knownTribalVillages) else { return }
        notices.post([TribalVillageText.notice(sighting, view: view, civName: civName(of:))])
    }

    /// Stops background work (the game is closing).
    func end() {
        aiTask?.cancel()
        aiTask = nil
        messageTask?.cancel()
        revealTask?.cancel()
        notices.reset()
        overlay.clearFloaters()
        overlay.bannerSource = nil
        renderer.presentsWithTransaction = false
        renderer.onFrame = nil
        renderer.onFirstFrame = nil
        renderer.onEventShown = nil
        renderer.onAnimationsFinished = nil
    }

    // MARK: Queries

    /// Everything the viewer knows; the HUD reads only this (or live state in diagnostic mode).
    var view: PlayerView { state.view(for: viewer) }

    var mapSize: MapSize? { MapSize(rawValue: state.mapSizeName) }

    var isViewerPhase: Bool { state.outcome == nil && state.currentPlayer == viewer }

    /// The viewer may issue commands: their phase, no playback running, the game not over.
    var isInputEnabled: Bool { aiPhase == nil && isViewerPhase }

    /// The player whose phase the viewer is waiting for, if any.
    var waitingFor: AIPhase? {
        if let aiPhase { return aiPhase }
        guard state.outcome == nil, state.currentPlayer != viewer else { return nil }
        return AIPhase(player: state.currentPlayer, civName: civName(of: state.currentPlayer))
    }

    func civName(of player: PlayerID) -> String {
        guard state.players.indices.contains(player.rawValue) else { return "Unknown" }
        let p = state.players[player.rawValue]
        return state.rules.civ(p.civ)?.name ?? p.name
    }

    var viewerCivName: String { civName(of: viewer) }

    var selectedUnit: GameCore.Unit? {
        guard case let .unit(id)? = selection else { return nil }
        return view.unit(id)
    }

    var selectedCity: City? {
        guard case let .city(id)? = selection else { return nil }
        return view.city(id)
    }

    /// Own units waiting for orders (M1 §16): moves left, no orders, no activity; a Settler that
    /// can found a city where it stands, whatever its moves (founding takes none).
    var unitsNeedingOrders: [GameCore.Unit] {
        view.units.filter { ($0.movesLeft > 0 || view.standsReadyToFound($0)) && $0.destination == nil && $0.activity == .none && !explore.contains($0.id) }
    }

    var nextActionTitle: String {
        if let waiting = waitingFor { return "Waiting for \(waiting.civName)" }
        if state.outcome != nil { return "Game Over" }
        return nextAttentionItem?.title ?? "End Turn"
    }

    // MARK: Commands

    /// Applies a command for the viewer, then updates the map and overlays. Returns whether it
    /// was accepted; a refusal shows its reason.
    @discardableResult
    func perform(_ command: Command) -> Bool {
        guard isInputEnabled else {
            if let waiting = waitingFor {
                show("Waiting for \(waiting.civName)")
            } else {
                show(state.outcome != nil ? "The game is over" : "Not your turn")
            }
            return false
        }
        do {
            // A march ordered now: its goal, should it stop at once (the notice says why).
            if case let .moveUnit(unit, to) = command { unitsBefore.noteGoal(to, of: unit) }
            let events = try GameEngine.apply(command, by: viewer, to: &state)
            commandCount += 1
            exploreHeard(command)
            // The viewer's own deeds stay quiet in the notices; ending the phase is not one
            // (what follows it is news).
            let isEndTurn = if case .endTurn = command { true } else { false }
            stateChanged(events: events, byViewer: !isEndTurn)
            // A new city is selected with its production list open (M1 §16).
            if case .foundCity = command, let id = Self.foundedCity(in: events, by: viewer) {
                select(.city(id))
                requestCityPanel(.production)
            }
            // A city just taken: its Keep/Raze card, right away (M1 §16).
            if let id = Self.capturedCity(in: events, by: viewer), state.outcome == nil {
                select(.city(id))
                attentionCard = .capture(id)
            }
            // The phase ended: the other players' phases follow, with playback.
            if !isViewerPhase { playOtherPhases() }
            return true
        } catch {
            show(Self.describe(error))
            return false
        }
    }

    nonisolated static func foundedCity(in events: [EventRecord], by player: PlayerID) -> CityID? {
        for record in events {
            if case let .cityFounded(id, _, owner, _) = record.event, owner == player { return id }
        }
        return nil
    }

    nonisolated static func capturedCity(in events: [EventRecord], by player: PlayerID) -> CityID? {
        for record in events {
            if case let .cityCaptured(id, _, _, to, _) = record.event, to == player { return id }
        }
        return nil
    }

    /// Ends the viewer's phase; the other players' phases follow with playback. What the
    /// attention queue noted for this phase is cleared first: what happens from here on is
    /// news for the next one.
    func endTurn() {
        clearPreviews()
        guard isInputEnabled else {
            perform(.endTurn) // shows why not
            return
        }
        resetPhaseAttention()
        perform(.endTurn)
    }

    /// Applies another player's command (AI playback) to the authoritative state; the caller
    /// updates the map with `stateChanged`.
    func applyOthers(_ command: Command, by player: PlayerID) throws(CommandError) -> [EventRecord] {
        let events = try GameEngine.apply(command, by: player, to: &state)
        commandCount += 1
        return events
    }

    /// Adopts a state computed elsewhere for the same game (an AI's result when its replay
    /// failed); the caller updates the map.
    func adopt(_ newState: GameState) {
        state = newState
    }

    /// The records the viewer may see (all of them in diagnostic mode).
    func visibleRecords(_ records: [EventRecord]) -> [EventRecord] {
        diagnostic ? records : records.filter { $0.isVisible(to: viewer) }
    }

    /// After any change of `state`: the renderer animates the visible events (or lands them at
    /// once), the world inputs, banners and selection overlays are rebuilt, the notices and
    /// listeners hear the events. `byViewer`: they come from the viewer's own command.
    func stateChanged(events: [EventRecord], animate: Bool = true, byViewer: Bool = false) {
        let visible = visibleRecords(events)
        noteCombats(visible)
        noteGifts(visible)
        if animate {
            renderer.apply(state: state, events: visible)
        } else {
            let animates = renderer.animatesEvents
            renderer.animatesEvents = false
            renderer.apply(state: state, events: visible)
            renderer.animatesEvents = animates
        }
        syncWorld()
        revision &+= 1
        refreshSelection()
        if !visible.isEmpty {
            postingViewerNotices = byViewer
            notices.post(NoticeMaker.notices(for: visible, view: view, viewerActed: byViewer, before: unitsBefore,
                                             exploring: explore.orders.map(\.unit), civName: civName(of:)))
            postingViewerNotices = false
            onEvents?(visible)
        }
        afterStateChange()
    }

    /// Notes, for each visible combat, whose sides were hurt and who fell (`combatSides`).
    private func noteCombats(_ records: [EventRecord]) {
        guard records.contains(where: { if case .combat = $0.event { true } else { false } }) else { return }
        if combatSides.count > 256 { combatSides.removeAll() }
        var killed: [UnitID: PlayerID] = [:]
        var formerOwner: [CityID: PlayerID] = [:]
        for record in records {
            switch record.event {
            case let .unitKilled(unit, _, owner, _): killed[unit] = owner
            case let .cityCaptured(city, _, from, _, _): formerOwner[city] = formerOwner[city] ?? from
            default: break
            }
        }
        func owner(_ side: Combatant) -> PlayerID? {
            switch side {
            case let .unit(id): killed[id] ?? state.unit(id)?.owner
            case let .city(id): formerOwner[id] ?? state.city(id)?.owner
            }
        }
        for (i, record) in records.enumerated() {
            guard case let .combat(attacker, defender, _, _, _, _, _) = record.event else { continue }
            // Who fell in this blow: a death recorded before the next combat.
            var fell = Set<UnitID>()
            for later in records[(i + 1)...] {
                if case .combat = later.event { break }
                if case let .unitKilled(unit, _, _, _) = later.event { fell.insert(unit) }
            }
            func died(_ side: Combatant) -> Bool { if case let .unit(id) = side { fell.contains(id) } else { false } }
            combatSides[record] = CombatSides(attackerOwn: owner(attacker) == viewer, defenderOwn: owner(defender) == viewer,
                                              attackerKilled: died(attacker), defenderKilled: died(defender))
        }
    }

    /// Notes, for each of the viewer's own visible takes of a tribal village, the gift a later
    /// record of the same batch gives for it (`pendingGifts`). A rival's take gets no label.
    private func noteGifts(_ records: [EventRecord]) {
        for (i, record) in records.enumerated() {
            guard case let .tribalVillageTaken(at, player, _, _) = record.event, player == viewer else { continue }
            for later in records[(i + 1)...] {
                guard case let .tribalVillageGift(receiver, hex, gift) = later.event, receiver == player, hex == at else { continue }
                if pendingGifts.count > 256 { pendingGifts.removeAll() }
                pendingGifts[record] = gift
                break
            }
        }
    }

    /// An event landed on the map (`onEventShown`). A blow: its damage numbers, the defender's
    /// where it was struck and the attacker's (melee retaliation) a moment later, as the map
    /// shows it. The viewer's take of a tribal village: its gift floats up from the tile.
    private func eventShown(_ record: EventRecord, at point: CGPoint) {
        if case let .tribalVillageTaken(at, _, _, _) = record.event {
            if let gift = pendingGifts.removeValue(forKey: record) {
                overlay.showGift(gift, at: point, hex: state.map.normalize(at) ?? at)
            }
            return
        }
        guard case let .combat(attacker, defender, from, to, _, dealt, taken) = record.event else { return }
        let sides = combatSides.removeValue(forKey: record) ?? CombatSides(
            attackerOwn: Self.owner(of: attacker, in: state) == viewer, defenderOwn: Self.owner(of: defender, in: state) == viewer,
            attackerKilled: false, defenderKilled: false)
        let target = state.map.normalize(to) ?? to
        overlay.showDamage(dealt, own: sides.defenderOwn, killed: sides.defenderKilled, at: point, hex: target)
        guard taken > 0 else { return }
        let origin = state.map.normalize(from) ?? from
        var p: CGPoint?
        if case let .unit(id) = attacker { p = renderer.screenPoint(ofUnit: id, lift: MapOverlay.floaterLift) }
        if let p = p ?? renderer.screenPoint(of: origin, lift: MapOverlay.floaterLift) {
            overlay.showDamage(taken, own: sides.attackerOwn, killed: sides.attackerKilled, at: p, hex: origin, delay: 0.06)
        }
    }

    private static func owner(of side: Combatant, in state: GameState) -> PlayerID? {
        switch side {
        case let .unit(id): state.unit(id)?.owner
        case let .city(id): state.city(id)?.owner
        }
    }

    func syncWorld() {
        MapAdapter.syncWorld(renderer, state: state, viewer: viewer, diagnostic: diagnostic)
    }

    /// A refusal or failure as a sentence for a toast or alert.
    static func describe(_ error: Error) -> String {
        let domain = (error as NSError).domain
        // System errors read best localized; the game's own errors describe themselves.
        let text = domain == NSCocoaErrorDomain || domain == NSPOSIXErrorDomain ? error.localizedDescription : String(describing: error)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    // MARK: Map input

    /// A tap on the map (M1 §16 tap rules), in this order:
    /// 1. the end of a previewed route: move there;
    /// 2. a marked attack target of the selection: preview the attack (from its `from` tile),
    ///    and the second tap strikes;
    /// 3. a city's sprite: with an own unit selected that can move this phase and has a route
    ///    into an own city, the route (tap again to move); else an own city is selected (tapped
    ///    again, the cycle goes on to the units on it), after saying why a unit that could move
    ///    has no route there; a foreign one opens its info card. Its banner selects an own city
    ///    directly (`tapBanner`);
    /// 4. own units: select them, military first; tapping the selected tile again cycles
    ///    military → civilian → city. But with an own unit selected that can move this phase, a
    ///    tile of only own units of the other kind (civilian or military) gets its route;
    /// 4b. enemy civilians alone, at war, that the selected military unit reaches this phase:
    ///    the route that captures them (marked like attack targets);
    /// 5. anything else foreign there: its info card;
    /// 6. the ground: a route for the selected unit (tap its end again to move), else deselect.
    ///
    /// Where M1 is silent: the ground of an own city's tile (beside its sprite) is ground while
    /// an own unit is selected — the route into the city — and selects the city otherwise; and
    /// a tap on plain ground while a card about a tile is open only closes the card.
    func handleTap(_ hit: MapHit) {
        noteMapTouched()
        let raw: HexCoord
        var tappedCity: CityID?
        var onGround = false
        switch hit {
        case let .unit(h): raw = h
        case let .ground(h):
            raw = h
            onGround = true
        case let .city(id, h):
            raw = h
            tappedCity = CityID(id)
        }
        let view = self.view
        guard let hex = view.normalize(raw) else { return }
        let wasInspecting = inspectedHex != nil
        inspectedHex = nil

        // 1. The end of a previewed route: the second tap moves.
        if pendingPath?.destination == hex, selectedUnit != nil {
            confirmPath()
            return
        }
        // 2. A marked target: the combat preview, then the strike.
        if isInputEnabled, let option = attackOptions().first(where: { $0.target == hex }) {
            if pendingAttack?.option.target == hex {
                confirmAttack()
            } else {
                previewAttack(option)
            }
            return
        }
        // 3. A city's sprite (or, through `tapBanner`, a foreign city's banner): an own city
        // takes the selected unit in, else is selected.
        if let city = tappedCity {
            if view.city(city) == nil {
                showInfo(hex)
            } else if routeIntoOwnCity(city, at: hex) {
                return
            } else if selection == .city(city) {
                cycle(at: hex)
            } else {
                select(.city(city))
            }
            return
        }
        // 4. Own units (or, off a selected unit's route, the own city) on the tile; own units
        // of the other kind take the selected unit in.
        let stack = selectables(at: hex)
        let ownUnitsHere = view.units(at: hex).contains { $0.owner == viewer }
        let routing = onGround && isInputEnabled && selectedUnit.map { $0.owner == viewer && $0.position != hex } == true
        if !stack.isEmpty, ownUnitsHere || !routing {
            if ownUnitsHere, routeOntoOwnUnits(at: hex) { return }
            cycle(at: hex)
            return
        }
        // 4b. Enemy civilians the selected military unit captures this phase: the route.
        if routeToCapture(at: hex) { return }
        // 5. Anything foreign: its info card.
        if view.knownCity(at: hex).map({ $0.owner != viewer }) == true || view.units(at: hex).contains(where: { $0.owner != viewer }) {
            showInfo(hex)
            return
        }
        // 6. The ground.
        if wasInspecting {
            clearPreviews()
        } else if routing, let unit = selectedUnit {
            previewPath(for: unit, to: hex)
        } else {
            deselect()
        }
    }

    /// Selects what is on a tile: the first of its selectables, or the one after the current
    /// selection (military → civilian → city, around again).
    private func cycle(at hex: HexCoord) {
        let stack = selectables(at: hex)
        guard !stack.isEmpty else { return }
        if let current = selection, let i = stack.firstIndex(of: current) {
            select(stack[(i + 1) % stack.count])
        } else {
            select(stack[0])
        }
    }

    /// A tap at a view point of the map: a city's banner first, else what the map shows there.
    func tapMap(at point: CGPoint) {
        if let city = overlay.bannerCity(at: point) {
            tapBanner(city)
        } else if let hit = renderer.hitTest(atViewPoint: point) {
            handleTap(hit)
        }
    }

    /// A tap on a city's banner (M1 §16): an own city's selects it in one tap, even with a unit
    /// selected (whose route the sprite gives). Otherwise as a tap on its sprite: the second
    /// tap of a route into the city moves, the selected city's banner cycles to its units, and
    /// a foreign city's previews an attack on it or opens its info card.
    func tapBanner(_ city: CityID) {
        guard let hex = cityHex(city) else { return }
        if view.city(city) != nil, selection != .city(city), pendingPath?.destination != hex {
            noteMapTouched()
            select(.city(city))
            return
        }
        handleTap(.city(id: city.rawValue, hex))
    }

    /// The hint a routing tap shows with its route ("Tap again to move into Rome"), and that
    /// route's end: the hint goes as soon as the route is confirmed or dropped.
    @ObservationIgnored private var routeHint: (text: String, destination: HexCoord)?

    /// Shows a routing tap's hint for the route just previewed (`GameSession+Taps.swift`).
    func showRouteHint(_ text: String) {
        guard let destination = pendingPath?.destination else { return }
        show(text)
        routeHint = (text, destination)
    }

    /// Clears the routing hint once its route is no longer the one previewed.
    private func dropStaleRouteHint() {
        guard let hint = routeHint, pendingPath?.destination != hint.destination else { return }
        routeHint = nil
        if message == hint.text {
            messageTask?.cancel()
            message = nil
        }
    }

    /// Why the latest routing tap had no route ("That tile is water…"), kept like `routeHint`:
    /// it goes as soon as a route is previewed, so it never stands over a valid one.
    @ObservationIgnored private var routeRefusalText: String?

    /// Says why `unit` has no route to `hex` (M1 §16: a refused route says why), for 3.5 s or
    /// until a route is previewed.
    func showRouteRefusal(for unit: GameCore.Unit, to hex: HexCoord) {
        let view = self.view
        let text = RouteText.refusal(view.routeRefusal(for: unit.id, to: hex), unit: unit, goal: hex, view: view,
                                     civName: civName(of:))
        show(text, for: 3.5)
        routeRefusalText = text
    }

    /// Clears a route refusal still on screen: a route has just been previewed.
    private func dropRouteRefusal() {
        guard let text = routeRefusalText else { return }
        routeRefusalText = nil
        if message == text {
            messageTask?.cancel()
            message = nil
        }
    }

    /// Where a city the viewer knows stands.
    func cityHex(_ city: CityID) -> HexCoord? {
        if diagnostic, let live = state.city(city) { return live.position }
        return view.knownCities.first { $0.id == city }?.position
    }

    /// Long-press: the tile sheet.
    func inspect(_ hex: HexCoord) {
        noteMapTouched()
        guard let hex = view.normalize(hex) else { return }
        if pendingPath != nil || pendingAttack != nil { clearPreviews() }
        inspectedHex = hex
        inspectMode = .tile
        revealInspectedSoon()
    }

    /// A foreign unit's or city's info card.
    private func showInfo(_ hex: HexCoord) {
        clearPreviews()
        inspectedHex = hex
        inspectMode = .info
        revealInspectedSoon()
    }

    /// The tile of an open info card or tile sheet wears the ring like a selection, and the
    /// card must not hide it either (a tap low on an iPhone's screen).
    private func revealInspectedSoon() {
        revealSoon { $0.inspectedHex.map { [$0] } ?? [] }
    }

    func closeInspector() {
        inspectedHex = nil
    }

    /// Moves the selected unit along the previewed route.
    func confirmPath() {
        guard let unit = selectedUnit, let destination = pendingPath?.destination else { return }
        clearPreviews()
        perform(.moveUnit(unit: unit.id, to: destination))
    }

    /// The tile sheet's "Move here": the selected unit's route to the tile, previewed (the
    /// marked tile or the unit card's Move confirms it).
    func routeSelectedUnit(to hex: HexCoord) {
        guard let unit = selectedUnit, unit.owner == viewer, isInputEnabled else { return }
        inspectedHex = nil
        previewPath(for: unit, to: hex)
    }

    /// A unit action from the action bar or the keyboard: done, or its reason shown when it
    /// cannot be (Disband asks first, in the view).
    @discardableResult
    func performAction(_ action: UnitAction) -> Bool {
        if let problem = action.problem {
            show(problem.prefix(1).uppercased() + problem.dropFirst())
            return false
        }
        return perform(action.command)
    }

    /// The map was panned, zoomed or tapped (playback leaves the camera alone for 2 s).
    func noteMapTouched() {
        lastMapTouch = ContinuousClock.now
    }

    /// What the HUD panels cover, so the camera centres in the open part of the map.
    func setMapInsets(_ insets: UIEdgeInsets) {
        guard insets != mapInsets else { return }
        mapInsets = insets
        renderer.setViewportInsets(insets)
        overlay.coveredTop = insets.top
    }

    /// Own units (military first) and the own city on a tile, in tap-cycling order.
    func selectables(at hex: HexCoord) -> [Selection] {
        let view = self.view
        guard let hex = view.normalize(hex) else { return [] }
        let units = view.units(at: hex).filter { $0.owner == viewer }
        var list = units.filter { !$0.type.isCivilian }.map { Selection.unit($0.id) }
        list += units.filter(\.type.isCivilian).map { Selection.unit($0.id) }
        if let city = view.cities.first(where: { $0.position == hex }) { list.append(.city(city.id)) }
        return list
    }

    /// Brings a tile to the middle of the open part of the map: a glide, or with Reduce Motion
    /// a cut (M1 §16 "Reduce Motion skips animations").
    func lookAt(_ hex: HexCoord) {
        renderer.centerCamera(on: hex, animated: !reduceMotion)
    }

    /// Centres the camera on the viewer's capital, else a unit (military first).
    func centerOnViewer(animated: Bool = true) {
        let view = self.view
        let animated = animated && !reduceMotion
        if let capital = view.me.capital.flatMap(view.city) {
            renderer.centerCamera(on: capital.position, animated: animated)
        } else if let unit = view.units.first(where: { !$0.type.isCivilian }) ?? view.units.first {
            renderer.centerCamera(on: unit.position, animated: animated)
        } else if let city = view.cities.first {
            renderer.centerCamera(on: city.position, animated: animated)
        }
    }

    // MARK: Selection

    func select(_ selection: Selection) {
        clearPreviews()
        inspectedHex = nil
        describedAction = nil
        explore.described = nil
        attentionCard = nil
        if selection != self.selection {
            bombardTargeting = nil
            // Another city's panel opens on its overview.
            if case .city = selection { cityPanelRequest = CityPanelRequest(focus: .overview, token: cityPanelRequest.token &+ 1) }
        }
        self.selection = selection
        refreshSelection()
        revealSelectionSoon()
    }

    /// Where the selection stands.
    var selectionHex: HexCoord? {
        switch selection {
        case let .unit(id)?: view.unit(id)?.position
        case let .city(id)?: view.city(id)?.position
        case nil: nil
        }
    }

    /// Panels never hide the selection without reason (M1 §16): once they have settled for the
    /// new selection, a selection they cover (or off screen) is brought into the open part.
    func revealSelectionSoon() {
        revealSoon { $0.selectionHex.map { [$0] } ?? [] }
    }

    /// Once the panels have settled, brings tiles they cover (or off screen) into the open part
    /// of the map, centred on the last. A selected city counts as covered while its banner
    /// reaches under the top bar (where banners hide).
    private func revealSoon(_ places: @escaping @MainActor (GameSession) -> [HexCoord]) {
        revealTask?.cancel()
        revealTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, !Task.isCancelled else { return }
            let hexes = places(self)
            // Clear of the panels' edges by about a tile, not just inside them.
            guard let last = hexes.last else { return }
            if hexes.allSatisfy({ self.isOnScreen($0, margin: 56) }), self.selectedBannerClearsTop { return }
            self.lookAt(last)
        }
    }

    /// Whether the selected city's banner (if a city is selected) is below the top bar. The
    /// banner's height is about 41 pt above its anchor; 12 more keep it off the bar's shadow.
    private var selectedBannerClearsTop: Bool {
        guard case let .city(id)? = selection, let anchor = renderer.bannerAnchor(city: id.rawValue) else { return true }
        return anchor.y - MapOverlay.bannerGap - 41 - 12 >= mapInsets.top
    }

    func deselect() {
        clearPreviews()
        inspectedHex = nil
        describedAction = nil
        explore.described = nil
        attentionCard = nil
        bombardTargeting = nil
        selection = nil
        refreshSelection()
    }

    /// The attack targets of the selection: an own unit's, or an own city's bombard targets.
    func attackOptions() -> [AttackOption] {
        let view = self.view
        switch selection {
        case let .unit(id)?:
            guard let unit = view.unit(id), unit.owner == viewer else { return [] }
            return view.attackOptions(for: id)
        case let .city(id)?:
            return view.cityAttackOptions(for: id)
        case nil:
            return []
        }
    }

    func previewPath(for unit: GameCore.Unit, to hex: HexCoord) {
        pendingAttack = nil
        if let path = view.path(for: unit.id, to: hex), !path.steps.isEmpty {
            dropRouteRefusal()
            pendingPath = path
            renderer.showPath(path, from: unit.position)
        } else {
            // The standing march route stays (`clearPreviews`); why not, as the viewer knows it.
            clearPreviews()
            showRouteRefusal(for: unit, to: hex)
        }
    }

    func previewAttack(_ option: AttackOption) {
        let view = self.view
        let attacker: Combatant
        switch selection {
        case let .unit(id)?: attacker = .unit(id)
        case let .city(id)?: attacker = .city(id)
        case nil: return
        }
        let preview = view.combatPreview(attacker: attacker, target: option.target, from: option.from)
        pendingAttack = AttackPlan(attacker: attacker, option: option, preview: preview)
        pendingPath = nil
        if case let .unit(id) = attacker, let unit = view.unit(id), option.from != unit.position,
           let path = view.path(for: id, to: option.from) {
            renderer.showPath(path, from: unit.position)
        } else {
            renderer.showPath(nil, from: option.from)
        }
        // The combat card must not hide the fight.
        revealSoon { _ in [option.from, option.target] }
    }

    /// Strikes the previewed target (M1 §16): a unit first moves to the tile to strike from if
    /// needed, then attacks; a city bombards.
    func confirmAttack() {
        guard let plan = pendingAttack else { return }
        clearPreviews()
        switch plan.attacker {
        case let .unit(id):
            guard let unit = view.unit(id) else { return }
            if plan.option.from != unit.position {
                guard perform(.moveUnit(unit: id, to: plan.option.from)) else { return }
                guard view.unit(id)?.position == plan.option.from else {
                    // The march's notice says why it stopped.
                    show("No attack: the move was stopped short")
                    return
                }
                // The move may have brought the defender's supporters into sight (M1 §8.1): the
                // blow lands only with the odds the viewer saw, else the card shows the new ones.
                let view = self.view
                guard let fresh = view.attackOptions(for: id).first(where: { $0.target == plan.option.target }) else {
                    show("The target is out of reach now")
                    return
                }
                let preview = view.combatPreview(attacker: .unit(id), target: fresh.target, from: fresh.from)
                guard preview?.sameInputs(as: plan.preview) ?? (plan.preview == nil) else {
                    previewAttack(fresh)
                    show("New units in sight: check the odds")
                    return
                }
            }
            perform(.attack(unit: id, target: plan.option.target))
        case let .city(id):
            bombardTargeting = nil
            perform(.cityAttack(city: id, target: plan.option.target))
        }
    }

    /// Closes the combat preview; a city's bombard target mode ends with it (its panel returns).
    /// A selected unit's standing march route shows again.
    func cancelAttack() {
        if case .city? = pendingAttack?.attacker { bombardTargeting = nil }
        pendingAttack = nil
        showStandingRoute()
    }

    /// Drops the previewed route and attack; a selected unit's standing march route shows again.
    func clearPreviews() {
        pendingPath = nil
        pendingAttack = nil
        showStandingRoute()
    }

    /// With nothing previewed, the map shows the selected own unit's standing march route (a
    /// march under way), else no route: it goes when the order does (arrived, cancelled,
    /// fortified), when the selection changes, and during other players' phases.
    private func showStandingRoute() {
        guard pendingPath == nil, pendingAttack == nil else { return }
        var march: Path?
        var from = HexCoord(q: 0, r: 0)
        if isInputEnabled, case let .unit(id)? = selection, let unit = view.unit(id), unit.owner == viewer {
            march = unit.destination.flatMap { view.path(for: id, to: $0) }
            from = unit.position
        }
        renderer.showPath(march?.steps.isEmpty == false ? march : nil, from: from)
    }

    /// Re-derives the selection overlays from the current state (after a command or a change of
    /// selection): the ring, an own unit's movement range and attack targets (a Settler's site
    /// scores, a Builder's job tiles), or an own city's worked tiles and bombard targets. A selection that is gone (or
    /// out of sight) is cleared.
    func refreshSelection() {
        overlay.invalidateBanners()
        let view = self.view
        switch selection {
        case let .unit(id)?:
            guard let unit = view.unit(id) else {
                selection = nil
                clearPreviews()
                return refreshSelection()
            }
            let own = unit.owner == viewer
            let targets = own && isInputEnabled ? view.attackOptions(for: id) : []
            renderer.setSelection(unit.position, kind: .unit)
            renderer.setMovementRange(own && isInputEnabled && unit.movesLeft > 0 ? view.reachableTiles(for: id) : [])
            renderer.setAttackTargets(targets.map(\.target) + captureTargets(for: unit))
            renderer.setWorkedTiles([])
            let settles = own && state.rules.unit(unit.type).foundsCity
            renderer.setTileScores(settles ? MapAdapter.settlerScores(view, around: unit.position, radius: MapAdapter.siteRadius) : [],
                                   jobs: own ? MapAdapter.builderJobMarks(view, for: id) : [])
            if let plan = pendingAttack, plan.attacker != .unit(id) || !targets.contains(plan.option) {
                cancelAttack()
            } else {
                // A march under way shows its standing route while nothing else is previewed.
                showStandingRoute()
            }
        case let .city(id)?:
            guard let city = view.city(id) else {
                selection = nil
                clearPreviews()
                return refreshSelection()
            }
            let targets = isInputEnabled ? view.cityAttackOptions(for: id) : []
            if bombardTargeting == id, targets.isEmpty { bombardTargeting = nil }
            renderer.setSelection(city.position, kind: .city)
            renderer.setMovementRange([])
            renderer.setAttackTargets(targets.map(\.target))
            renderer.setWorkedTiles(city.workedTiles)
            renderer.setTileScores([])
            if let plan = pendingAttack, plan.attacker != .city(id) || !targets.contains(plan.option) {
                cancelAttack()
            } else {
                showStandingRoute() // a unit's route goes with its selection
            }
        case nil:
            // The tile of an open info card or tile sheet wears the ring (round a city's
            // settlement when one is known there), so the card says which tile it is about.
            let city = inspectedHex.flatMap { view.knownCity(at: $0) } != nil
            renderer.setSelection(inspectedHex, kind: city ? .city : .unit)
            renderer.setMovementRange([])
            renderer.setAttackTargets([])
            renderer.setWorkedTiles([])
            renderer.setTileScores([])
            showStandingRoute()
        }
        updateFocus()
    }

    /// Tells the overlay which tiles the player is working with, so taps on them under a city
    /// banner (off its name row) reach the map: the selected unit's, a previewed route's and
    /// attack's, and the tile of an open card. City tiles are left out: there the banner names
    /// the city.
    private func updateFocus() {
        dropStaleRouteHint()
        let view = self.view
        var hexes: [HexCoord] = []
        if case let .unit(id)? = selection, let unit = view.unit(id) { hexes.append(unit.position) }
        if let path = pendingPath { hexes += path.steps.map(\.hex) }
        if let plan = pendingAttack { hexes += [plan.option.from, plan.option.target] }
        if let hex = inspectedHex { hexes.append(hex) }
        overlay.focusHexes = hexes.filter { view.knownCity(at: $0) == nil }
    }

    // MARK: Panels and keys

    /// The panels presented over the map on request (the tech panel, the diplomacy sheet, the
    /// notices log).
    enum Panel: Equatable {
        case research, diplomacy, notices
    }

    /// Esc: closes the combat preview, else leaves bombard target mode, else drops the
    /// previewed route, else closes the open tile card, else the attention card, else deselects.
    func escape() {
        if pendingAttack != nil {
            cancelAttack()
        } else if bombardTargeting != nil {
            endBombard()
        } else if pendingPath != nil {
            clearPreviews()
        } else if inspectedHex != nil {
            closeInspector()
        } else if attentionCard != nil {
            closeAttentionCard()
        } else {
            deselect()
        }
    }

    // MARK: Messages

    /// A tap on the notice toast: looks where its first line happened, and dismisses it.
    func lookAt(_ card: NoticeCenter.Card) {
        if let place = card.lines.lazy.compactMap(\.place).first {
            noteMapTouched()
            lookAt(place)
        }
        notices.dismiss()
    }

    func show(_ text: String, for seconds: Double = 2.5) {
        message = text
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    // MARK: Developer tools

    /// Whether a developer tool may change the state now (not during playback: the replay must
    /// match the AI's computation; not once the game is over).
    private var mayTamper: Bool {
        guard aiTask == nil else {
            show("Wait for the other players")
            return false
        }
        guard state.outcome == nil else {
            show("The game is over")
            return false
        }
        return true
    }

    func spawnStressUnits(_ count: Int) {
        guard mayTamper else { return }
        stressSpawns += 1
        let before = state.units.count
        DebugTools.spawnUnits(count: count, seed: state.seed &+ stressSpawns, in: &state)
        stateChanged(events: [])
        // How many were placed, not how many there are: the total counts units out of sight.
        show("\(state.units.count - before) units spawned")
    }

    /// Every unit on the map (all players) moves to a random nearby tile. The message counts
    /// only the units the viewer saw move.
    func randomWalkAll() {
        guard mayTamper else { return }
        let events = DebugTools.moveAllUnchecked(in: &state, rng: &stressRNG)
        stateChanged(events: events)
        var seen: [UnitID] = []
        for record in visibleRecords(events) {
            if case let .unitMoved(unit, _, _) = record.event, !seen.contains(unit) { seen.append(unit) }
        }
        show("\(seen.count) unit\(seen.count == 1 ? "" : "s") moved in sight")
    }
}

#if DEBUG
extension GameSession {
    /// Automation `testgift` (App/AUTOMATION.md): a tribal village's gift to the viewer, shown as
    /// a take shows it, for builds whose rules take none yet (phase 3g H1 brings the takes). The
    /// records of a take by own `unit` or `city` on `hex`, and of its gift, go through
    /// `stateChanged`: the notice, the float label, an attention item when important. Nothing in
    /// the state changes. `byViewer`: as the viewer's own command (a tap; an Explore leg when the
    /// unit explores), else as at its phase start (a standing order, border growth).
    func debugTribalVillageGift(_ gift: TribalVillageGift, at hex: HexCoord, unit: UnitID?, city: CityID?, byViewer: Bool) {
        let audience = UInt16(1) << viewer.rawValue
        stateChanged(events: [EventRecord(.tribalVillageTaken(at: hex, player: viewer, unit: unit, city: city), audience: audience),
                              EventRecord(.tribalVillageGift(player: viewer, at: hex, gift: gift), audience: audience)],
                     byViewer: byViewer)
    }
}
#endif
