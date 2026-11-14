import GameCore
import Persistence
import SwiftUI

/// The game screen (M1 §16): the map as the hero, with its city banners and damage numbers
/// (`MapOverlay`); the top bar; under it the notices and short messages; one card at a time at
/// the bottom (game over, attention card, combat preview, bombard hint, info card or tile
/// sheet, unit card) beside Next / End Turn; the city panel; the game menu, the tech panel, the
/// diplomacy sheet and Load as sheets; the confirmations (Raze, Declare War, Disband, Buy over
/// half the treasury, End Turn with items pending).
///
/// Layouts: on iPad (and a phone on its side) the city panel is a trailing side panel (320 pt on
/// a phone) with Next below it; on an iPhone in portrait it is a sheet with 35% and large
/// detents, the map staying live above it, and Next rides above the sheet. The panels report
/// what they cover so the camera centres in the open part of the map.
struct GameView: View {
    @Bindable var session: GameSession
    let model: AppModel

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cover = Cover()
    @State private var cityDetent: PresentationDetent = Self.smallDetent

    static let smallDetent = PresentationDetent.fraction(0.35)

    /// Where the panels are, in the map's (full-screen) coordinates.
    private struct Cover: Equatable {
        var mapSize: CGSize = .zero
        var safeBottom: CGFloat = 0
        var topBarBottom: CGFloat = 0
        /// The bottom card's top (nil: no card) and trailing edge.
        var cardTop: CGFloat?
        var cardTrailing: CGFloat = 0
        /// The top of Next (iPhone portrait: of Next and the card stacked).
        var nextTop: CGFloat?
        /// The leading edge of the trailing column (the side panel over Next), and whether the
        /// side panel shows in it.
        var columnLeading: CGFloat = 0
        var hasSidePanel = false
        /// The city sheet's top, when it shows.
        var sheetTop: CGFloat?

        /// What the panels cover: the top bar; the bottom band (the card, and Next unless it
        /// sits under the side panel); the side panel; the city sheet (counted as at most 40%
        /// of the screen: above that it covers the map anyway). On a phone on its side
        /// (`sideCard`) a card is nearly as tall as the screen, so it covers the leading side
        /// instead and the map stays open beside it.
        func insets(sideCard: Bool) -> UIEdgeInsets {
            guard mapSize.height > 0 else { return .zero }
            var insets = UIEdgeInsets(top: topBarBottom, left: 0, bottom: 0, right: 0)
            if let panelLeading { insets.right = max(0, mapSize.width - panelLeading) }
            var band = CGFloat.infinity
            if sideCard, cardTrailing > 0 {
                insets.left = cardTrailing
            } else if let cardTop {
                band = cardTop
            }
            if panelLeading == nil, let nextTop { band = min(band, nextTop) }
            if band.isFinite { insets.bottom = max(0, mapSize.height - band) }
            if let sheetTop { insets.bottom = max(insets.bottom, min(mapSize.height - sheetTop, mapSize.height * 0.4)) }
            return insets
        }

        /// The side panel's leading edge, when one shows. Measured on the column rather than on
        /// the panel: the panel's own frame includes its slide-in transition, and reported where
        /// the slide began (a panel's width further right), so the camera centred the selected
        /// city under the panel.
        var panelLeading: CGFloat? { hasSidePanel && columnLeading > 0 ? columnLeading : nil }

        /// How far the HUD's bottom row rises to stay above the city sheet at its small detent.
        var sheetLift: CGFloat {
            guard let sheetTop, mapSize.height > 0 else { return 0 }
            return max(0, min(mapSize.height - sheetTop, mapSize.height * 0.4) - safeBottom)
        }
    }

    /// The sheets, one at a time.
    enum GameSheet: String, Identifiable {
        case city, research, civics, government, diplomacy, notices, load
        var id: String { rawValue }
    }

    /// Narrow screens (iPhone portrait, a narrow iPad window) stack the HUD and show the city
    /// panel as a sheet; a phone on its side has the width for the wide layout.
    private var compact: Bool { sizeClass == .compact && verticalSizeClass != .compact }
    /// A phone on its side: little height, so cards keep to a smaller size.
    private var short: Bool { verticalSizeClass == .compact }
    private var sidePanelWidth: CGFloat { short ? 320 : 360 }

    /// The city in the side panel (wide layouts).
    private var sidePanelCity: City? { compact ? nil : session.panelCity(compact: short) }

    /// Whether `card` shows anything.
    private var showsCard: Bool {
        session.state.outcome != nil || session.attentionCard != nil || session.pendingAttack != nil
            || session.bombardTargeting != nil || session.quarterPlacing != nil || session.tileBuying != nil || session.inspectedHex != nil || session.selectedUnit != nil
    }

    var body: some View {
        ZStack {
            MapView(session: session)
                .ignoresSafeArea()

            Group {
                if compact { compactHUD } else { wideHUD }
            }
            // The keyboard (the Save prompt's name) never pushes the panels about.
            .ignoresSafeArea(.keyboard)
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { cover.safeBottom = $0 }
            // The map fills the screen, safe areas included. Measured here, as the HUD's size plus
            // the safe area around it: the map's own geometry reports only its safe-area part.
            .onGeometryChange(for: CGSize.self) { proxy in
                let safe = proxy.safeAreaInsets
                return CGSize(width: proxy.size.width + safe.leading + safe.trailing, height: proxy.size.height + safe.top + safe.bottom)
            } action: { cover.mapSize = $0 }

            keyboardCommands
        }
        // The HUD lies over the map: past the second accessibility size its chips and cards
        // would cover most of it (and the top bar would not fit a phone), so text stops there.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .animation(.easeInOut(duration: 0.2), value: session.message)
        .animation(.easeInOut(duration: 0.25), value: session.notices.card)
        .animation(.easeInOut(duration: 0.2), value: session.selection)
        .animation(.easeInOut(duration: 0.2), value: session.waitingFor)
        .animation(.easeInOut(duration: 0.2), value: session.attentionCard)
        .animation(.easeInOut(duration: 0.2), value: session.bombardTargeting)
        .animation(.easeInOut(duration: 0.2), value: session.quarterPlacing)
        .animation(.easeInOut(duration: 0.2), value: session.tileBuying)
        // At this level so that turning a phone upright (no side panel there) clears it too.
        .onChange(of: sidePanelCity != nil, initial: true) { _, shows in cover.hasSidePanel = shows }
        .onChange(of: cover.insets(sideCard: short && showsCard), initial: true) { _, insets in session.setMapInsets(insets) }
        .onChange(of: reduceMotion, initial: true) { _, reduce in session.reduceMotion = reduce }
        .onChange(of: session.cityPanelRequest) { _, request in
            cityDetent = request.focus == .production ? .large : Self.smallDetent
        }
        // A side panel or city sheet that has just appeared (or moved to another detent) must not
        // hide the selection; the reveal waits until it has settled.
        .onChange(of: cover.panelLeading) { _, edge in if edge != nil { session.revealSelectionSoon() } }
        .onChange(of: cover.sheetTop) { _, top in if top != nil { session.revealSelectionSoon() } }
        .sheet(item: sheetBinding) { sheet in
            sheetContent(sheet)
        }
        .alert("Save Game", isPresented: $session.isShowingSave) {
            TextField("Name", text: $session.saveName)
            Button("Save") {
                let name = session.saveName
                Task {
                    await session.save(named: name)
                    await model.refreshSaves()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved games appear in Load Game, newest first.")
        }
        // An alert rather than a confirmation dialog: on iPad a dialog hides its cancel button.
        .alert("Load another game?", isPresented: $session.confirmingLoad) {
            Button("Keep Playing", role: .cancel) {}
            Button("Choose a Save…") { model.isShowingLoad = true }
        } message: {
            Text("Moves made since the last save will be lost.")
        }
        .alert(disbandTitle, isPresented: Binding(get: { session.pendingDisband != nil }, set: { if !$0 { session.pendingDisband = nil } })) {
            Button("Disband", role: .destructive) { session.confirmDisband() }
            Button("Keep", role: .cancel) { session.pendingDisband = nil }
        } message: {
            Text("The unit will be gone for good.")
        }
        .alert(razeTitle, isPresented: Binding(get: { session.pendingRaze != nil }, set: { if !$0 { session.pendingRaze = nil } })) {
            Button("Raze", role: .destructive) { session.confirmRaze() }
            Button("Cancel", role: .cancel) { session.pendingRaze = nil }
        } message: {
            Text("The city will be destroyed and its lands left unowned. This cannot be undone.")
        }
        .alert(endTurnTitle, isPresented: Binding(get: { session.endTurnPrompt != nil }, set: { if !$0 { session.endTurnPrompt = nil } })) {
            Button("End Turn") { session.answerEndTurnPrompt(endTurn: true) }
            Button("Keep Playing", role: .cancel) { session.answerEndTurnPrompt(endTurn: false) }
        } message: {
            Text("Next shows each of them in turn. You won't be asked again this game.")
        }
    }

    private var disbandTitle: String {
        session.pendingDisband.flatMap { session.view.unit($0) }.map { "Disband the \($0.type.displayName)?" } ?? ""
    }

    private var razeTitle: String {
        session.pendingRaze.flatMap { session.view.city($0) }.map { "Raze \($0.name)?" } ?? ""
    }

    private var endTurnTitle: String {
        guard let n = session.endTurnPrompt else { return "" }
        return n == 1 ? "1 item needs attention — End Turn?" : "\(n) items need attention — End Turn?"
    }

    // MARK: Layouts

    /// iPhone portrait: the top bar, messages, then Next and the card at the bottom (above the
    /// city sheet when it shows).
    private var compactHUD: some View {
        VStack(spacing: HUD.Space.s) {
            TopBar(session: session, compact: true, onResearch: { session.openPanel = .research }) { menu }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { cover.topBarBottom = $0 }
            messages
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: HUD.Space.s) {
                NextButton(session: session)
                card.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { top in
                cover.nextTop = top
                cover.cardTop = nil
            }
        }
        .padding(.horizontal, HUD.Space.s)
        .padding(.top, HUD.Space.s)
        .padding(.bottom, HUD.Space.s + cover.sheetLift)
    }

    /// iPad and a phone on its side: the card at the bottom left; on the right the city panel
    /// (when a city is selected) with Next under it.
    private var wideHUD: some View {
        let panelCity = sidePanelCity
        return VStack(spacing: HUD.Space.s) {
            TopBar(session: session, compact: false, onResearch: { session.openPanel = .research }) { menu }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { cover.topBarBottom = $0 }
            ZStack(alignment: .top) {
                HStack(alignment: .bottom, spacing: HUD.Space.m) {
                    card.frame(maxWidth: HUD.cardWidth, alignment: .leading)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                            cover.cardTrailing = frame.height > 1 ? frame.maxX : 0
                            cover.cardTop = frame.height > 1 ? frame.minY : nil
                        }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: HUD.Space.s) {
                        if let city = panelCity {
                            CityPanel(session: session, city: city, style: .side)
                                .frame(width: sidePanelWidth)
                                .frame(maxHeight: .infinity, alignment: .top)
                                .transition(slide(.trailing))
                        }
                        NextButton(session: session)
                            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { cover.nextTop = $0 }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { cover.columnLeading = $0 }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
                messages
                    .padding(.trailing, panelCity == nil ? 0 : sidePanelWidth + HUD.Space.m)
            }
        }
        .padding(.horizontal, HUD.Space.l)
        .padding(.vertical, HUD.Space.s)
        .animation(.easeInOut(duration: 0.22), value: panelCity?.id)
    }

    /// Panels and toasts slide in from their edge, or (Reduce Motion) fade in place.
    private func slide(_ edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    /// The message toast, the notice card and the developer readout under the top bar.
    private var messages: some View {
        VStack(spacing: HUD.Space.s) {
            if let message = session.message {
                Toast(text: message)
                    .transition(slide(.top))
            }
            if let card = session.notices.card {
                NoticeToast(card: card) { session.lookAt(card) }
                    .frame(maxWidth: 440)
                    .id(card.id)
                    .transition(slide(.top))
            }
            if session.showStats { renderStats }
        }
    }

    /// One card at a time, the most pressing first.
    @ViewBuilder
    private var card: some View {
        if let outcome = session.state.outcome {
            GameOverCard(session: session, outcome: outcome) {
                Task { await model.quitToMenu(keepingResumePoint: false) }
            }
        } else if let attention = session.attentionCard {
            AttentionCardView(session: session, card: attention)
        } else if let plan = session.pendingAttack {
            AttackCard(session: session, plan: plan, compact: compact)
        } else if let city = session.bombardTargeting {
            BombardHintCard(session: session, city: city)
        } else if let placing = session.quarterPlacing {
            QuarterHintCard(session: session, placing: placing)
        } else if let city = session.tileBuying {
            BuyTileHintCard(session: session, city: city)
        } else if let hex = session.inspectedHex {
            if session.inspectMode == .tile {
                TileSheet(session: session, hex: hex)
            } else {
                InfoCard(session: session, hex: hex)
            }
        } else if let unit = session.selectedUnit {
            UnitCard(session: session, unit: unit, compact: short) { session.askToDisband($0.id) }
        }
    }

    // MARK: Sheets

    /// The sheet that should show: Load, the tech panel or diplomacy when asked for, else (on
    /// an iPhone in portrait) the selected city's panel.
    private var wantedSheet: GameSheet? {
        if model.isShowingLoad { return .load }
        switch session.openPanel {
        case .research?: return .research
        case .civics?: return .civics
        case .government?: return .government
        case .diplomacy?: return .diplomacy
        case .notices?: return .notices
        case nil: break
        }
        if compact, session.panelCity(compact: true) != nil { return .city }
        return nil
    }

    /// Dismissing a sheet by hand closes what it shows (the city sheet deselects the city).
    private var sheetBinding: Binding<GameSheet?> {
        Binding(get: { wantedSheet }, set: { sheet in
            guard sheet == nil, let shown = wantedSheet else { return }
            switch shown {
            case .load: model.isShowingLoad = false
            case .research, .civics, .government, .diplomacy, .notices: session.openPanel = nil
            case .city:
                cover.sheetTop = nil
                // Turning the phone on its side also closes the sheet (the side panel takes
                // the city over): only a sheet closed by hand, still upright, deselects. This
                // closure may be from before the turn, so the layout is UIKit's, now.
                guard Self.windowIsCompactNow else { return }
                session.deselect()
            }
        })
    }

    /// Whether the window has the compact layout's size classes at this moment (UIKit's
    /// traits, which change before SwiftUI's environment reaches older closures).
    private static var windowIsCompactNow: Bool {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let traits = (scene?.keyWindow ?? scene?.windows.first)?.traitCollection else { return true }
        return traits.horizontalSizeClass == .compact && traits.verticalSizeClass != .compact
    }

    @ViewBuilder
    private func sheetContent(_ sheet: GameSheet) -> some View {
        switch sheet {
        case .city:
            Group {
                if let city = session.panelCity(compact: true) {
                    CityPanel(session: session, city: city, style: .sheet)
                } else {
                    Color.clear
                }
            }
            .presentationDetents([Self.smallDetent, .large], selection: $cityDetent)
            .presentationBackgroundInteraction(.enabled(upThrough: Self.smallDetent))
            .presentationBackground(HUD.parchmentTop)
            .presentationDragIndicator(.visible)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { cover.sheetTop = $0 }
            .onDisappear { cover.sheetTop = nil }
        case .research:
            TechPanel(session: session) { session.openPanel = nil }
                .presentationDetents([.large])
                .presentationSizing(.page)
                .presentationBackground(HUD.parchmentTop)
        case .civics:
            CivicPanel(session: session) { session.openPanel = nil }
                .presentationDetents([.large])
                .presentationSizing(.page)
                .presentationBackground(HUD.parchmentTop)
        case .government:
            GovernmentPanel(session: session) { session.openPanel = nil }
                .presentationDetents(compact ? [.medium, .large] : [.large])
                .presentationSizing(.form)
                .presentationBackground(HUD.parchmentTop)
        case .diplomacy:
            DiplomacySheet(session: session) { session.openPanel = nil }
                .presentationDetents(compact ? [.medium, .large] : [.large])
                .presentationSizing(.form)
                .presentationBackground(HUD.parchmentTop)
        case .notices:
            NoticeLog(session: session) { session.openPanel = nil }
                .presentationDetents(compact ? [.medium, .large] : [.large])
                .presentationSizing(.form)
                .presentationBackground(HUD.parchmentTop)
        case .load:
            LoadGameView(model: model) { save in
                Task { await model.load(save) }
            }
        }
    }

    // MARK: Menu

    private var menu: some View {
        Menu {
            Section {
                Button {
                    session.beginSave()
                } label: {
                    Label("Save Game…", systemImage: "square.and.arrow.down")
                }
                Button {
                    if session.hasUnsavedCommands {
                        session.confirmingLoad = true
                    } else {
                        model.isShowingLoad = true
                    }
                } label: {
                    Label("Load Game…", systemImage: "tray.full")
                }
                Button {
                    session.openPanel = .diplomacy
                } label: {
                    Label("Diplomacy…", systemImage: "globe.europe.africa")
                }
                Button {
                    session.openPanel = .research
                } label: {
                    Label("Research…", systemImage: YieldChip.Kind.science.systemImage)
                }
                if !session.view.rules.civics.isEmpty {
                    Button {
                        session.openPanel = .civics
                    } label: {
                        Label("Civics…", systemImage: YieldChip.Kind.culture.systemImage)
                    }
                }
                if session.view.government != nil {
                    Button {
                        session.openPanel = .government
                    } label: {
                        Label("Government…", systemImage: "building.columns")
                    }
                }
                Button {
                    session.openPanel = .notices
                } label: {
                    // The unread count as the entry's subtitle.
                    Text("Notices…")
                    if session.notices.unread > 0 { Text("\(session.notices.unread) unread") }
                    Image(systemName: "list.bullet.rectangle")
                }
            }
            Menu {
                Toggle(isOn: $session.tilted) { Label("Tilted Camera", systemImage: "perspective") }
                Toggle(isOn: $session.showGrid) { Label("Hex Grid", systemImage: "hexagon") }
                Toggle(isOn: $session.quickAITurns) { Label("Quick AI Turns", systemImage: "hare") }
            } label: {
                Label("Display", systemImage: "eye")
            }
            Menu {
                Toggle(isOn: $session.diagnostic) { Label("Diagnostic Mode (No Fog)", systemImage: "eye.trianglebadge.exclamationmark") }
                // The rest are debug builds' tools: they change every player's units or measure.
                #if DEBUG
                Toggle(isOn: $session.showStats) { Label("Render Stats", systemImage: "speedometer") }
                Picker(selection: $session.aiDriver) {
                    ForEach(AIDriver.allCases) { driver in
                        Text(driver.title).tag(driver)
                    }
                } label: {
                    Label("AI Players", systemImage: "cpu")
                }
                Button("Spawn 100 Units") { session.spawnStressUnits(100) }
                Button("Spawn 300 Units") { session.spawnStressUnits(300) }
                Button("Move All Units") { session.randomWalkAll() }
                Toggle("Flyover Pan", isOn: $session.flyover)
                Text(statsSummary)
                #endif
            } label: {
                Label("Developer", systemImage: "hammer")
            }
            Section {
                Button(role: .destructive) {
                    Task { await model.quitToMenu() }
                } label: {
                    Label("Quit to Menu", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        } label: {
            RoundelLabel(systemName: "line.3.horizontal")
                .overlay(alignment: .topTrailing) { UnreadBadge(count: session.notices.unread) }
        }
        .accessibilityLabel("Game menu")
        .accessibilityValue(session.notices.unread > 0 ? "\(session.notices.unread) unread notices" : "")
    }

    #if DEBUG
    private var statsSummary: String {
        let mb = Double(session.renderer.textureMemoryBytes) / 1_048_576
        let size = session.mapSize?.displayName ?? session.state.mapSizeName
        // Units in sight (all of them only with the fog off): the readout never counts hidden ones.
        let view = session.view
        let units = session.diagnostic ? session.state.units.count : view.units.count + view.visibleForeignUnits.count
        return String(format: "%@ · seed %llu · %d units in sight · setup %.0f ms · textures %.1f MB · mapgen %d ms", size, session.state.seed,
                      units, session.renderer.setupMilliseconds, mb, session.mapGenMilliseconds)
    }
    #endif

    /// Live frame stats, refreshed twice a second: the renderer's, and the overlay's banners
    /// and time spent placing them per frame.
    private var renderStats: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            Text(session.renderer.statsLine + String(format: " · %d banners · overlay %.2f ms", session.overlay.shownBanners,
                                                     session.overlay.layoutMilliseconds))
                .font(.caption.monospacedDigit())
                .padding(.horizontal, HUD.Space.m)
                .padding(.vertical, HUD.Space.xs + 2)
                .parchmentCapsule()
        }
    }

    // MARK: Keyboard (M1 §16)

    /// Space Next (on the button), Return End Turn (asking once per game with items pending),
    /// F Fortify, S Sleep, K Skip, B Found City, Esc deselect (or close the open card first).
    private var keyboardCommands: some View {
        Group {
            Button("End Turn") { session.requestEndTurn() }
                .keyboardShortcut(.return, modifiers: [])
            Button("Deselect") { session.escape() }
                .keyboardShortcut(.escape, modifiers: [])
            Button("Fortify") { unitAction(.fortify) }
                .keyboardShortcut("f", modifiers: [])
            Button("Sleep") { unitAction(.sleep) }
                .keyboardShortcut("s", modifiers: [])
            Button("Skip") { unitAction(.skip) }
                .keyboardShortcut("k", modifiers: [])
            Button("Found City") { unitAction(.foundCity) }
                .keyboardShortcut("b", modifiers: [])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func unitAction(_ kind: UnitActionKind) {
        guard let unit = session.selectedUnit, unit.owner == session.viewer,
              let action = session.view.unitActions(for: unit.id).first(where: { $0.kind == kind }) else { return }
        if kind == .disband {
            session.askToDisband(unit.id)
        } else {
            session.performAction(action)
        }
    }
}
