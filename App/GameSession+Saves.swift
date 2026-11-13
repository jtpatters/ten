import Foundation
import GameCore
import Persistence

// The game's side of the save policy (M1 §14): an autosave when each of the viewer's phases
// begins (after AI playback), manual saves from the game menu, and the game's background slot
// when the app leaves the foreground or the game is closed (during an AI phase: the state as of
// that phase's start, so loading it replays the phase; a finished game writes none). Encoding
// and writing run on the `SaveStore` actor, off the main thread, from a snapshot of the state.
// Each save keeps the Notices log as of its state beside it, with how much of it was read
// (`NoticeLogStore`). Every save carries the game's id (`gameID`), which keeps each game's
// autosaves and background slot apart from those of a game alike in seed, map size and civ; a
// debug scenario's game writes neither.
extension GameSession {
    /// The start of a debug scenario's game id (`AppModel.startScenario`): such a game, or one
    /// loaded from its manual saves, never autosaves or writes a background slot, so it can
    /// never push a real game's saves out of their rotation.
    static let scenarioGamePrefix = "scenario-"

    /// A new game's id (New Game) or a debug scenario's.
    static func newGameID(scenario: Bool = false) -> String {
        (scenario ? scenarioGamePrefix : "game-") + UUID().uuidString.lowercased()
    }

    /// Whether this game writes autosaves and background slots: any but a debug scenario.
    var savesAutomatically: Bool { !(gameID?.hasPrefix(Self.scenarioGamePrefix) ?? false) }

    func autosave() {
        guard savesAutomatically else { return }
        let snapshot = state, count = commandCount, logged = notices.savedThrough(phaseStart: false), explorers = explorersToSave
        let game = gameID
        Self.logInvariantProblems(of: snapshot, before: "autosave")
        pendingSaves += 1
        Task {
            defer { pendingSaves -= 1 }
            do {
                let summary = try await store.autosave(snapshot, explorers: explorers, game: game)
                savedCommandCount = count
                await keepNoticeLog(for: summary, through: logged)
            } catch {
                show("Autosave failed: \(Self.describe(error))", for: 4)
            }
        }
    }

    /// Saves the game under a name (the game menu). Returns the save, or nil after showing why
    /// it failed.
    /// During an AI phase it saves the state as of that phase's start, as the background slot
    /// does (M1 is silent on manual saves): the state mid-replay would resume with the rest of
    /// the phase recomputed from half of it. A name left empty, or still the default the
    /// prompt opened with (`saveNameDefault`), becomes the snapshot's own default name: the
    /// turn may have moved on while the prompt was open.
    @discardableResult
    func save(named name: String) async -> SaveSummary? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let (snapshot, count) = resumePoint
        let logged = notices.savedThrough(phaseStart: aiPhase != nil)
        let named = trimmed.isEmpty || trimmed == saveNameDefault ? SaveStore.defaultName(for: snapshot) : trimmed
        pendingSaves += 1
        defer { pendingSaves -= 1 }
        do {
            let summary = try await store.save(snapshot, name: named, kind: .manual, explorers: explorersToSave, game: gameID)
            savedCommandCount = count
            await keepNoticeLog(for: summary, through: logged)
            show("Saved “\(summary.name)”")
            return summary
        } catch {
            show("Couldn't save: \(Self.describe(error))", for: 4)
            return nil
        }
    }

    /// "<Civ> – Turn N" (M1 §14).
    var defaultSaveName: String { SaveStore.defaultName(for: state) }

    /// Opens the Save prompt with the default name (the game menu, automation).
    func beginSave() {
        saveName = defaultSaveName
        saveNameDefault = saveName
        isShowingSave = true
    }

    /// Writes the resume point: the current state, or during an AI phase the state as of its
    /// start (M1 §14). A finished game writes none, so Continue never reopens a game-over card;
    /// a save made while the final AI phase plays back still writes that phase's start.
    func saveForBackground() async {
        let (snapshot, count) = resumePoint
        guard snapshot.outcome == nil, savesAutomatically else { return }
        let logged = notices.savedThrough(phaseStart: aiPhase != nil)
        Self.logInvariantProblems(of: snapshot, before: "background save")
        pendingSaves += 1
        defer { pendingSaves -= 1 }
        do {
            let summary = try await store.saveBackground(snapshot, explorers: explorersToSave, game: gameID)
            savedCommandCount = count
            // Awaited: the app's background task ends after it, so iOS's extra time covers the log.
            await keepNoticeLog(for: summary, through: logged)
        } catch {
            show("Couldn't save the game: \(Self.describe(error))", for: 4)
        }
    }

    /// Keeps the Notices log with a save just written (`NoticeLogStore`): the notices up to
    /// `id` (those the saved state covers), written off the main thread; returns once written.
    /// The saves await it: a log still being written when iOS suspends the app (and kills it)
    /// would be lost, and Continue would open its save with an empty log.
    private func keepNoticeLog(for save: SaveSummary, through id: Int) async {
        let log = notices.log.filter { $0.id <= id }
        let readThrough = min(notices.readThroughID, id)
        await Task.detached(priority: .utility) {
            do {
                try NoticeLogStore.app.write(log, readThrough: readThrough, for: save)
            } catch {
                #if DEBUG
                DebugLog.write("Notices log for \(save.url.lastPathComponent) not written: \(error)")
                #endif
            }
        }.value
    }

    /// The state a save resumes from, and the command count it covers: the current state, or
    /// during an AI phase the state as of its start.
    private var resumePoint: (GameState, Int) {
        aiPhase != nil ? (phaseStartState ?? state, phaseStartCommandCount) : (state, commandCount)
    }

    /// Whether a save is being written.
    var isSaving: Bool { pendingSaves > 0 }

    /// Debug builds: a state about to be saved that fails `checkInvariants()` is logged (a
    /// save that fails them will not load). Logged, not asserted: a developer tool can cause
    /// it. Checked off the main actor.
    nonisolated static func logInvariantProblems(of snapshot: GameState, before what: String) {
        #if DEBUG
        Task.detached(priority: .utility) {
            let problems = snapshot.checkInvariants()
            guard !problems.isEmpty else { return }
            DebugLog.write("Invariants failed before the \(what) of turn \(snapshot.turn) (it will not load): "
                           + problems.prefix(5).joined(separator: "; "))
        }
        #endif
    }
}
