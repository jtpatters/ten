import GameCore
import MapGen
import MapRendering
import Observation
import Persistence
import SwiftUI
import UIKit

/// The app above a single game: the save store (`Documents/Saves`), the list of saves, the game
/// on screen, and what the launch arguments asked for (M1 §14, §16).
///
/// Save policy (M1 §14): each game autosaves when the viewer's phase begins; the game's
/// background slot is written when the app leaves the foreground and when a game is closed (the
/// resume point; none for a finished game); Continue opens the newest save of any kind; after
/// any load the AI phases before the viewer's play first. While a save opens, the game on
/// screen stops where it is (`suspendAI`), so nothing it does lands after the load.
@Observable
@MainActor
final class AppModel {
    private(set) var session: GameSession?
    /// Work under way over the screen ("Preparing the world…").
    var busy: String?
    /// Every save, newest first.
    private(set) var saves: [SaveSummary] = []
    /// Files in the saves folder that cannot be opened (another version of the game, damage),
    /// listed apart in Load so a game never vanishes without a word.
    private(set) var unreadableSaves: [UnreadableSave] = []
    var alert: AppAlert?
    /// The Load Game sheet (from the start screen or the game menu).
    var isShowingLoad = false
    @ObservationIgnored let store: SaveStore
    @ObservationIgnored let savesDirectory: URL
    @ObservationIgnored let launch: LaunchOptions
    @ObservationIgnored private var launched = false
    /// The scene's phase as last reported: a game opened while the app is in the background
    /// must know it.
    @ObservationIgnored private var scenePhase = ScenePhase.active
    #if DEBUG
    @ObservationIgnored var automation: AutomationInbox?
    #endif

    /// The start screen's diagnostic-mode switch (fog off), remembered between launches. It
    /// applies to new games only (and `-autostart`, debug scenarios): Continue and Load always
    /// open with the fog on, unless `-revealMap YES` turns it off for a launch.
    static let diagnosticKey = "diagnosticMode"

    init(launch: LaunchOptions = .current) {
        self.launch = launch
        savesDirectory = URL.documentsDirectory.appending(path: "Saves", directoryHint: .isDirectory)
        store = SaveStore(directory: savesDirectory)
    }

    var diagnosticPreference: Bool {
        launch.revealMap ?? UserDefaults.standard.bool(forKey: Self.diagnosticKey)
    }

    // MARK: Launch

    /// Runs once when the window appears: launch arguments may start a game, continue the
    /// newest save, or (debug) set up a scenario.
    func launchIfNeeded() async {
        guard !launched else { return }
        launched = true
        #if DEBUG
        if launch.resetSaves {
            try? FileManager.default.removeItem(at: savesDirectory)
            NoticeLogStore.app.removeAll()
            UserDefaults.standard.removeObject(forKey: GameSession.endTurnAskedKey)
        }
        if let orientation = launch.orientation { DebugOrientation.request(orientation) }
        automation = AutomationInbox(model: self)
        automation?.start()
        #endif
        await refreshSaves()
        #if DEBUG
        if let scenario = launch.scenario {
            await startScenario(scenario)
            return
        }
        #endif
        if let size = launch.autostart {
            await startNewGame(NewGameSetup(size: size, seed: launch.seed ?? 42, civ: launch.civ ?? Self.defaultCiv,
                                            diagnostic: diagnosticPreference))
            if launch.stress > 0 { session?.spawnStressUnits(launch.stress) }
        } else if launch.continueGame {
            await continueNewest()
        } else {
            markStartScreenReady()
        }
    }

    static var defaultCiv: CivID { Ruleset.standard.civs.first?.id ?? "rome" }

    // MARK: Saves

    func refreshSaves() async {
        do {
            saves = try await store.list()
        } catch {
            saves = []
        }
        unreadableSaves = (try? await store.listUnreadable()) ?? []
    }

    /// Continue (M1 §14): the newest save of any kind. A save that will not open (a damaged
    /// file, other rules) is reported and the next newest tried, so one bad file never blocks
    /// Continue.
    func continueNewest() async {
        await refreshSaves()
        guard let newest = saves.first else {
            alert = AppAlert(title: "Nothing to continue", message: "There are no saved games yet.")
            markStartScreenReady()
            return
        }
        guard busy == nil else { return }
        isShowingLoad = false
        busy = "Opening “\(newest.name)”…"
        defer { busy = nil }
        let suspended = session?.suspendAI() ?? false
        var firstError: Error?
        for save in saves {
            do {
                let loaded = try await store.open(save, rules: .standard)
                open(loaded.state, diagnostic: launch.revealMap ?? false, resumingSave: true, log: NoticeLogStore.app.read(for: save),
                     explorers: loaded.summary.explorers, game: loaded.summary.game)
                var notes = loaded.warnings.map(\.description)
                if let firstError {
                    notes.insert("\(Self.title(of: newest).capitalizedFirst) couldn't be opened. \(GameSession.describe(firstError)) "
                                 + "The game continues from \(Self.title(of: save)).", at: 0)
                }
                if !notes.isEmpty {
                    alert = AppAlert(title: firstError == nil ? "Rules Changed" : "Continued from an Older Save",
                                     message: notes.joined(separator: "\n\n"))
                }
                return
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        alert = AppAlert(title: "Couldn't open “\(newest.name)”", message: firstError.map(GameSession.describe) ?? "")
        if session == nil { markStartScreenReady() }
        if suspended { session?.resumeAI() }
    }

    /// A save as a sentence names it: “the resume point “Rome – Turn 2”” (saves of one turn
    /// share their default name, so the kind tells them apart).
    static func title(of save: SaveSummary) -> String {
        switch save.kind {
        case .manual: "“\(save.name)”"
        case .auto: "the autosave “\(save.name)”"
        case .background: "the resume point “\(save.name)”"
        }
    }

    func load(_ save: SaveSummary) async {
        guard busy == nil else { return }
        isShowingLoad = false
        busy = "Opening “\(save.name)”…"
        defer { busy = nil }
        // The game on screen must not play on (or autosave) behind the load; it goes on if the
        // save will not open.
        let suspended = session?.suspendAI() ?? false
        do {
            let loaded = try await store.open(save, rules: .standard)
            open(loaded.state, diagnostic: launch.revealMap ?? false, resumingSave: true, log: NoticeLogStore.app.read(for: save),
                 explorers: loaded.summary.explorers, game: loaded.summary.game)
            presentLoadWarnings(loaded.warnings)
        } catch {
            alert = AppAlert(title: "Couldn't open “\(save.name)”", message: GameSession.describe(error))
            if session == nil { markStartScreenReady() }
            if suspended { session?.resumeAI() }
        }
    }

    /// What the player should know about a save just opened (M1 §14: rules data changed since
    /// it was saved), as an alert over the game.
    func presentLoadWarnings(_ warnings: [SaveWarning]) {
        guard !warnings.isEmpty else { return }
        alert = AppAlert(title: "Rules Changed", message: warnings.map(\.description).joined(separator: "\n\n"))
    }

    func delete(_ save: SaveSummary) async {
        do {
            try await store.delete(save)
        } catch {
            alert = AppAlert(title: "Couldn't delete “\(save.name)”", message: GameSession.describe(error))
        }
        NoticeLogStore.app.sweep()
        await refreshSaves()
    }

    /// Deletes a file Load lists as unreadable.
    func delete(_ file: UnreadableSave) async {
        do {
            try await store.delete(fileAt: file.url)
        } catch {
            alert = AppAlert(title: "Couldn't delete the file", message: GameSession.describe(error))
        }
        NoticeLogStore.app.sweep()
        await refreshSaves()
    }

    // MARK: Games

    struct NewGameSetup: Sendable {
        var size: MapSize
        var seed: UInt64
        var civ: CivID
        var diagnostic: Bool
        /// The land pattern (M2 §3.5): Pangaea unless the player picks another.
        var script: MapScript = .pangaea
        /// Tribal villages are placed (M1 §7.7, when the rules have them). Every normal game has
        /// them; the debug scenarios turn them off (`Scenarios.make`) and place their own.
        var tribalVillages = true
    }

    func startNewGame(_ setup: NewGameSetup) async {
        guard busy == nil else { return }
        busy = "Preparing the world…"
        defer { busy = nil }
        let clock = ContinuousClock()
        let began = clock.now
        let state = await Task.detached(priority: .userInitiated) { Self.makeGame(setup) }.value
        let elapsed = clock.now - began
        open(state, diagnostic: setup.diagnostic, mapGenMilliseconds: Int(elapsed / .milliseconds(1)), game: GameSession.newGameID())
    }

    /// A new game (M1 §2): the map for the size and seed, the human's civ first and the AIs
    /// taking the others in rules order, with tribal villages unless the setup turns them off.
    nonisolated static func makeGame(_ setup: NewGameSetup) -> GameState {
        let rules = Ruleset.standard
        let civ = rules.civ(setup.civ) != nil ? setup.civ : (rules.civs.first?.id ?? setup.civ)
        let generated = MapGenerator.generate(MapGenSettings(size: setup.size, seed: setup.seed, script: setup.script))
        let civs = GameState.civOrder(human: civ, players: generated.startPositions.count, rules: rules)
        return GameState.newGame(seed: setup.seed, map: generated.map, startPositions: generated.startPositions, rules: rules,
                                 civs: civs, mapSizeName: setup.size.rawValue, placeTribalVillages: setup.tribalVillages,
                                 placeMinors: true)
    }

    /// Puts a game on screen and starts play (`resumingSave`: the state came from a save, with
    /// the Notices log it kept, `log`, and the Explore orders its header kept, `explorers`).
    /// `game`: the game's id, which its saves carry (nil for a game saved before ids, M1 §14).
    @discardableResult
    func open(_ state: GameState, diagnostic: Bool, mapGenMilliseconds: Int = 0, resumingSave: Bool = false,
              log: NoticeLogStore.Kept = .init(), explorers: [SavedExplorer] = [], game: String?) -> GameSession {
        session?.end()
        let session = GameSession(state: state, store: store, diagnostic: diagnostic, mapGenMilliseconds: mapGenMilliseconds)
        session.gameID = game
        session.notices.restore(log.notices, readThrough: log.readThrough)
        session.reduceMotion = UIAccessibility.isReduceMotionEnabled
        session.isSceneActive = scenePhase == .active
        applyLaunchDisplayOptions(to: session)
        self.session = session
        session.resumeExploring(explorers)
        session.begin(resumingSave: resumingSave)
        // Opened after the app left the foreground (a load that finished late): its resume
        // point now, as on leaving.
        if scenePhase == .background { saveInBackground(session) }
        return session
    }

    /// Closes the game, back to the start screen, normally keeping a resume point (the
    /// background slot) for Continue when anything happened since the newest save; a finished
    /// game keeps none.
    func quitToMenu(keepingResumePoint: Bool = true) async {
        guard let session else { return }
        isShowingLoad = false
        // Nothing plays on (or autosaves) behind the quit; the resume point is an AI phase's start.
        session.suspendAI()
        if keepingResumePoint, session.hasUnsavedCommands { await session.saveForBackground() }
        session.end()
        self.session = nil
        await refreshSaves()
        markStartScreenReady()
    }

    // MARK: Scene

    /// The scene went to the background: write the resume point while iOS allows (M1 §14).
    func scenePhaseChanged(_ phase: ScenePhase) {
        scenePhase = phase
        session?.isSceneActive = phase == .active
        guard phase == .background, let session else { return }
        saveInBackground(session)
    }

    /// Writes a game's resume point with extra time from iOS to finish it.
    private func saveInBackground(_ session: GameSession) {
        let task = BackgroundTask(name: "Save the game")
        Task {
            await session.saveForBackground()
            task.end()
        }
    }

    // MARK: Launch display options

    private func applyLaunchDisplayOptions(to session: GameSession) {
        if launch.topDown { session.tilted = false }
        if launch.showStats { session.showStats = true }
        if let scale = launch.cameraScale { session.renderer.setCameraScale(scale) }
        if launch.showSeam { // centre on the east-west wrap seam
            session.renderer.setCameraPosition(CGPoint(x: 0, y: session.renderer.layout.worldHeight / 2))
        }
        if launch.markReady {
            // Automation: a marker file once the game's first frame is drawn.
            let marker = URL.documentsDirectory.appending(path: "rendered")
            try? FileManager.default.removeItem(at: marker)
            session.renderer.onFirstFrame = { try? Data("game".utf8).write(to: marker) }
        }
    }

    /// Automation: the marker file once the start screen shows.
    func markStartScreenReady() {
        guard launch.markReady else { return }
        let marker = URL.documentsDirectory.appending(path: "rendered")
        try? Data("start".utf8).write(to: marker)
    }
}

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

/// Extra time to finish a save after the app leaves the foreground.
@MainActor
final class BackgroundTask {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// Launch arguments (the argument domain of `UserDefaults`): `-autostart large -seed 42`
/// skip the start screen, and so on (App/AUTOMATION.md lists them all). Release builds read only
/// `-continue` and `-revealMap`: the rest are developer and benchmark tools.
struct LaunchOptions: Sendable {
    var autostart: MapSize?
    var seed: UInt64?
    var civ: CivID?
    /// `-revealMap YES|NO`: diagnostic mode (fog off) for games opened this launch.
    var revealMap: Bool?
    var stress = 0
    var cameraScale: CGFloat?
    var topDown = false
    var showStats = false
    var showSeam = false
    var markReady = false
    var continueGame = false
    var scenario: String?
    var orientation: String?
    var resetSaves = false
    /// Debug: what the New Game card's seed field starts with (its validation, in screenshots).
    var seedText: String?

    static var current: LaunchOptions {
        let d = UserDefaults.standard
        var o = LaunchOptions()
        o.revealMap = d.object(forKey: "revealMap") == nil ? nil : d.bool(forKey: "revealMap")
        o.continueGame = d.bool(forKey: "continue")
        #if DEBUG
        o.autostart = d.string(forKey: "autostart").flatMap(MapSize.init(rawValue:))
        o.seed = d.string(forKey: "seed").flatMap { UInt64($0) }
        o.civ = d.string(forKey: "civ").map { CivID($0) }
        o.stress = d.integer(forKey: "stress")
        let scale = d.double(forKey: "cameraScale")
        o.cameraScale = scale > 0 ? scale : nil
        o.topDown = d.bool(forKey: "topDown")
        o.showStats = d.bool(forKey: "showStats")
        o.showSeam = d.bool(forKey: "showSeam")
        o.markReady = d.bool(forKey: "markReady")
        o.scenario = d.string(forKey: "scenario")
        o.orientation = d.string(forKey: "orientation")
        o.resetSaves = d.bool(forKey: "resetSaves")
        o.seedText = d.string(forKey: "seedText")
        #endif
        return o
    }
}

private extension String {
    /// "The autosave …" at the start of a sentence.
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
