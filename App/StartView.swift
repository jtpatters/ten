import GameCore
import MapGen
import Persistence
import SwiftUI

/// The start screen (M1 §16): Continue (the newest save of any kind), New Game (map size, seed,
/// civ, diagnostic mode: it applies to new games only) and Load.
struct StartView: View {
    let model: AppModel

    @AppStorage("newGameSize") private var size: MapSize = .duel
    @AppStorage("newGameCiv") private var civRaw = AppModel.defaultCiv.rawValue
    @AppStorage(AppModel.diagnosticKey) private var diagnostic = false
    @State private var seedText = LaunchOptions.current.seedText ?? String(UInt64.random(in: 1...999_999))
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var civs: [CivDef] { Ruleset.standard.civs }
    private var civ: CivDef? { civs.first { $0.id.rawValue == civRaw } ?? civs.first }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: HUD.Space.xl) {
                    title
                    VStack(spacing: HUD.Space.l) {
                        if let newest = model.saves.first { continueCard(newest) }
                        newGameCard
                        if !model.saves.isEmpty || !model.unreadableSaves.isEmpty {
                            Button {
                                model.isShowingLoad = true
                            } label: {
                                Label("Load Game", systemImage: "tray.full")
                            }
                            .buttonStyle(ParchmentButtonStyle())
                        }
                    }
                    .frame(maxWidth: 460)
                }
                .padding(.horizontal, HUD.Space.l)
                .padding(.vertical, HUD.Space.xl)
                // Centred when it fits, scrolling when it does not.
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background {
            RadialGradient(colors: [HUD.seaLight, HUD.seaDark], center: .center, startRadius: 40, endRadius: 700)
                .ignoresSafeArea()
        }
        .sheet(isPresented: Binding(get: { model.isShowingLoad }, set: { model.isShowingLoad = $0 })) {
            LoadGameView(model: model) { save in
                Task { await model.load(save) }
            }
        }
        .task { await model.refreshSaves() }
    }

    private var title: some View {
        VStack(spacing: HUD.Space.s) {
            Text("Ten Thousand Years")
                .font(.system(size: sizeClass == .compact ? 38 : 52, weight: .bold, design: .serif))
                .foregroundStyle(HUD.parchmentTop)
                .multilineTextAlignment(.center)
                .shadow(color: .black.opacity(0.45), radius: 6, x: 2, y: 3)
            Text("Found a city by the river and see where the ages take it.")
                .font(HUD.body(.subheadline).italic())
                .foregroundStyle(HUD.parchmentTop.opacity(0.75))
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Continue

    private func continueCard(_ save: SaveSummary) -> some View {
        VStack(alignment: .leading, spacing: HUD.Space.m) {
            SectionHeader(title: "Continue")
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: HUD.Space.xxs) {
                    Text(save.civName).font(HUD.title(.title3))
                    Text(SaveRow.detail(of: save))
                        .font(HUD.body(.caption))
                        .foregroundStyle(HUD.inkSoft)
                }
                Spacer(minLength: HUD.Space.s)
                if let badge = SaveRow.badge(of: save) { KindBadge(text: badge) }
            }
            Button {
                Task { await model.continueNewest() }
            } label: {
                Label("Continue", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(BronzeButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .hudCard(padding: HUD.Space.l, cornerRadius: HUD.Radius.large)
    }

    // MARK: New game

    private var newGameCard: some View {
        VStack(alignment: .leading, spacing: HUD.Space.l) {
            SectionHeader(title: "New Game")

            VStack(alignment: .leading, spacing: HUD.Space.s) {
                Text("Map").font(HUD.title(.subheadline))
                Picker("Map size", selection: $size) {
                    ForEach(MapSize.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                Text("\(size.dimensions.width) × \(size.dimensions.height) tiles · \(size.defaultPlayers) civilisations")
                    .font(HUD.body(.caption))
                    .foregroundStyle(HUD.inkSoft)
            }

            VStack(alignment: .leading, spacing: HUD.Space.s) {
                Text("Civilisation").font(HUD.title(.subheadline))
                Menu {
                    Picker("Civilisation", selection: $civRaw) {
                        ForEach(civs, id: \.id) { civ in
                            Text("\(civ.name) — \(civ.leader)").tag(civ.id.rawValue)
                        }
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(civ?.name ?? "").font(HUD.title(.body))
                            Text(civ.map { "led by \($0.leader)" } ?? "")
                                .font(HUD.body(.caption))
                                .foregroundStyle(HUD.inkSoft)
                        }
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(HUD.inkSoft)
                    }
                    .padding(.horizontal, HUD.Space.m)
                    .frame(minHeight: HUD.touch)
                    .parchmentWell()
                    .contentShape(Rectangle())
                }
                .foregroundStyle(HUD.ink)
            }

            VStack(alignment: .leading, spacing: HUD.Space.s) {
                Text("Seed").font(HUD.title(.subheadline))
                HStack(spacing: HUD.Space.s) {
                    TextField("Random", text: $seedText)
                        .keyboardType(.numberPad)
                        .font(HUD.numeric(.body))
                        .padding(.horizontal, HUD.Space.m)
                        .frame(minHeight: HUD.touch)
                        .parchmentWell()
                    Button {
                        seedText = String(UInt64.random(in: 1...999_999))
                    } label: {
                        Image(systemName: "dice")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: HUD.touch, height: HUD.touch)
                            .parchmentWell()
                    }
                    .foregroundStyle(HUD.ink)
                    .accessibilityLabel("New random seed")
                }
                if let problem = Self.seedProblem(seedText) {
                    Label(problem, systemImage: "exclamationmark.circle")
                        .font(HUD.body(.caption))
                        .foregroundStyle(HUD.danger)
                } else if Self.trimmedSeed(seedText).isEmpty {
                    Text("Left empty, the game picks a random seed and shows it here.")
                        .font(HUD.body(.caption))
                        .foregroundStyle(HUD.inkSoft)
                }
            }

            Toggle(isOn: $diagnostic) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Diagnostic mode").font(HUD.title(.subheadline))
                    Text("No fog of war: see every civilisation and city.")
                        .font(HUD.body(.caption))
                        .foregroundStyle(HUD.inkSoft)
                }
            }
            .tint(HUD.bronzeBottom)

            Button {
                // An empty field picks a random seed, and shows it.
                let trimmed = Self.trimmedSeed(seedText)
                guard let seed = trimmed.isEmpty ? UInt64.random(in: 1...999_999) : UInt64(trimmed) else { return }
                seedText = String(seed)
                let setup = AppModel.NewGameSetup(size: size, seed: seed, civ: civ?.id ?? AppModel.defaultCiv, diagnostic: diagnostic)
                Task { await model.startNewGame(setup) }
            } label: {
                Label("Start", systemImage: "flag.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(BronzeButtonStyle())
            .disabled(Self.seedProblem(seedText) != nil)
        }
        .hudCard(padding: HUD.Space.l, cornerRadius: HUD.Radius.large)
    }

    static func trimmedSeed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Why the seed field cannot start a game (letters typed on a hardware keyboard, a number
    /// too large), or nil. An empty field is fine: a random seed.
    static func seedProblem(_ text: String) -> String? {
        let trimmed = trimmedSeed(text)
        guard !trimmed.isEmpty, UInt64(trimmed) == nil else { return nil }
        return trimmed.allSatisfy(\.isASCIIDigit) ? "Seed is too large" : "Seed must be a whole number"
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// The saves, newest first: tap to open, swipe to delete (M1 §14).
struct LoadGameView: View {
    let model: AppModel
    var onOpen: (SaveSummary) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.saves.isEmpty, model.unreadableSaves.isEmpty {
                    ContentUnavailableView("No Saved Games", systemImage: "tray",
                                           description: Text("Games are saved automatically at the start of each of your turns."))
                        .foregroundStyle(HUD.ink)
                } else {
                    List {
                        ForEach(model.saves) { save in
                            Button {
                                onOpen(save)
                            } label: {
                                SaveRow(save: save)
                            }
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task { await model.delete(save) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        // Files that cannot be opened stay listed, greyed, until swiped away.
                        ForEach(model.unreadableSaves) { file in
                            UnreadableSaveRow(file: file)
                                .listRowBackground(Color.clear)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        Task { await model.delete(file) }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(LinearGradient(colors: [HUD.parchmentTop, HUD.parchmentBottom], startPoint: .top, endPoint: .bottom))
            .navigationTitle("Load Game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The title in the HUD's face, not the system one (the navigation title stays for VoiceOver).
                ToolbarItem(placement: .principal) {
                    Text("Load Game").font(HUD.title(.headline)).foregroundStyle(HUD.ink)
                        .accessibilityAddTraits(.isHeader)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .font(HUD.title(.body))
                        .foregroundStyle(HUD.ink)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await model.refreshSaves() }
    }
}

/// One save in the list: its name, kind, and the game it holds.
struct SaveRow: View {
    var save: SaveSummary

    var body: some View {
        HStack(alignment: .center, spacing: HUD.Space.m) {
            VStack(alignment: .leading, spacing: HUD.Space.xxs) {
                Text(save.name).font(HUD.title(.body)).foregroundStyle(HUD.ink)
                Text(Self.detail(of: save))
                    .font(HUD.body(.caption))
                    .foregroundStyle(HUD.inkSoft)
            }
            Spacer(minLength: HUD.Space.s)
            if let badge = Self.badge(of: save) { KindBadge(text: badge) }
        }
        .frame(minHeight: HUD.touch)
        .contentShape(Rectangle())
    }

    static func badge(of save: SaveSummary) -> String? {
        switch save.kind {
        case .manual: nil
        case .auto: "Autosave"
        case .background: "Resume"
        }
    }

    /// "Turn 12 · Small map, seed 4821 · 3 minutes ago": the map and seed tell apart games of
    /// one civ, whose saves share names.
    static func detail(of save: SaveSummary) -> String {
        let when = save.savedAt.formatted(.relative(presentation: .named))
        return "Turn \(save.turn) · \(map(of: save)) · \(when)"
    }

    /// "Small map, seed 4821".
    static func map(of save: SaveSummary) -> String {
        let size = MapSize(rawValue: save.mapSizeName)?.displayName ?? save.mapSizeName.capitalized
        return "\(size) map, seed \(save.seed)"
    }
}

/// A file in the saves folder that cannot be opened: greyed, with why (M1 §14 refuses other
/// format versions), named after its game when its header still reads.
struct UnreadableSaveRow: View {
    var file: UnreadableSave

    var body: some View {
        HStack(alignment: .center, spacing: HUD.Space.m) {
            VStack(alignment: .leading, spacing: HUD.Space.xxs) {
                Text(file.summary?.name ?? file.url.lastPathComponent).font(HUD.title(.body))
                Text(Self.detail(of: file))
                    .font(HUD.body(.caption))
            }
            Spacer(minLength: HUD.Space.s)
            Image(systemName: "nosign").font(.system(size: 15, weight: .semibold))
        }
        .foregroundStyle(HUD.inkSoft)
        .frame(minHeight: HUD.touch)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Can't be opened. Swipe to delete it.")
    }

    /// "Made by another version of the game · Turn 30 · Small map, seed 4821".
    static func detail(of file: UnreadableSave) -> String {
        let why = file.isOtherVersion ? "Made by another version of the game" : "Damaged: can't be opened"
        guard let save = file.summary else { return why }
        return "\(why) · Turn \(save.turn) · \(SaveRow.map(of: save))"
    }
}
