import CoreGraphics
import CoreText
import Foundation
import GameCore
import Synchronization

// The shared painting toolkit (`FigurePaint.swift`).
private typealias Tone = FigurePaint.Tone
private typealias Ink = FigurePaint.Ink
private typealias Grain = FigurePaint.Grain
private typealias Material = FigurePaint.Material
private typealias Step = FigurePaint.Step
private typealias Figure = FigurePaint.Figure
private typealias Pass = FigurePaint.Pass
private typealias Canvas = FigurePaint.Canvas


/// Unit art, drawn procedurally with Core Graphics into the unit atlas at startup.
///
/// - `body`: each unit type facing west and facing east (256 px), shared by every player. Both
///   facings are painted with the sun at the upper left, so a unit heading east is still lit
///   from the west (ART.md §1). Team-colored parts are painted in a neutral grey.
/// - `teamMask`: a body's data, one value per channel: red is how much of each pixel is team
///   paint (the unit shader multiplies the owner's color into the grey there), green how near
///   it is to the body's silhouette (`rimField`), from which the shader draws the rim around
///   the figure. Data has no light in it, so only the west-facing body's is painted and the
///   east-facing body reads it mirrored (the figure instance says where it is, `maskCode`).
///   Its alpha is zero and its border empty, so nothing sampling a neighboring cell picks it up.
/// - `escortedBody`, `escortedMask`: the settler without its banner pole, for when the unit
///   escorting it carries the standard.
/// - `emblem`: each player's emblem in its ink, laid onto shields as its own instance, and into
///   the badges of strategic medallions and city tokens.
/// - `standard`: each player's banner hanging from a crossbar, with its emblem. It stands on the
///   body's pole top and the unit shader sways it. Every standard has the same outline, so one
///   `standardField` (data like a team mask's) gives all of them their rim.
/// - `badge`: a unit type's pictogram on a cream disc. The strategic medallion is composed in
///   the shader around its middle (the pictogram on the cream field, inside a ring in the
///   owner's color and ring pattern, `unitMedallion`), and an escort wears its civilian's whole.
/// - `marker`, `digit`: path turn markers, a pin medallion plus white numerals.
/// - `job`: a Builder job's glyph on a cream disc, like a badge: a sheaf (farm), a pick (mine)
///   or a paw print (pasture), laid on its job ring (`MapRenderer+Guidance.swift`).
/// - `tribalVillage`: a tribal village's strategic token, a round hut with a wisp of smoke on an
///   ivory disc in a dark rim (`MapRenderer+TribalVillages.swift`): never a player's colour.
///
/// Bases, shadows, the selection ring and medallion frames are procedural (`ShaderUnits.swift`);
/// instances are built in `MapRenderer+Units.swift`, trimmed to each sprite's painted extent
/// (`bounds`).
enum UnitSprite: SpriteSet {
    case body(UnitType, east: Bool)
    /// The data of a type's west-facing body (east-facing bodies read it mirrored).
    case teamMask(UnitType)
    /// A settler without its banner pole, for when its escort carries the standard.
    case escortedBody(east: Bool)
    case escortedMask
    case standard(player: Int)
    case standardField
    case emblem(player: Int)
    case badge(UnitType)
    case marker(final: Bool)
    case digit(Int)
    case job(Improvement)
    case tribalVillage

    static var all: [UnitSprite] {
        var keys: [UnitSprite] = []
        for type in UnitType.allCases {
            if sharesWestBody(type) {
                keys += [.body(type, east: false)] + (dataCell(type).key == type ? [.teamMask(type)] : [])
            } else {
                keys += [.body(type, east: false), .body(type, east: true), .teamMask(type)]
            }
        }
        keys += [.escortedBody(east: false), .escortedBody(east: true), .escortedMask]
        let players = Palette.playerStyles.indices
        for p in players { keys.append(.standard(player: p)) }
        for p in players { keys.append(.emblem(player: p)) }
        for type in UnitType.allCases { keys.append(.badge(type)) }
        keys += [.marker(final: false), .marker(final: true)]
        for d in 0...9 { keys.append(.digit(d)) }
        // The atlas is as tall as its cells need (`SpriteSheet.height`), and the unit shader
        // is built for that height.
        keys.append(.standardField)
        // After every older cell, so none of theirs moves.
        for kind in Improvement.allCases { keys.append(.job(kind)) }
        keys.append(.tribalVillage)
        return keys
    }

    /// The M2 types have no east-facing body cell: facing east they show the west-facing body
    /// mirrored (lit from the upper right), which keeps the atlas within its budget (ART.md §10).
    static func sharesWestBody(_ type: UnitType) -> Bool {
        switch type {
        case .settler, .builder, .scout, .warrior, .archer, .spearman: false
        case .horseman, .heavyChariot, .swordsman, .catapult, .manAtArms, .crossbowman, .pikeman, .knight, .trebuchet: true
        }
    }

    /// The M2 types' data cells hold two types each: the first in red and green, the second
    /// in blue and alpha (the same budget, ART.md §10).
    static let pairedData: [(UnitType, UnitType?)] = [(.horseman, .heavyChariot), (.swordsman, .catapult),
                                                      (.manAtArms, .crossbowman), (.pikeman, .knight), (.trebuchet, nil)]

    /// The type whose `teamMask` cell holds `type`'s data, and whether in blue and alpha.
    static func dataCell(_ type: UnitType) -> (key: UnitType, high: Bool) {
        for (first, second) in pairedData {
            if first == type { return (first, false) }
            if second == type { return (first, true) }
        }
        return (type, false)
    }

    /// Body cell edge in pixels (every other cell is 128).
    static let bodyCell = 256

    var cellSize: Int {
        switch self {
        case .body, .teamMask, .escortedBody, .escortedMask: Self.bodyCell
        default: 128
        }
    }

    func draw(in r: CGRect, ctx: CGContext) {
        // Art is laid out in fractions of the whole cell and kept inside the 1/20 margin, so
        // mipmaps never pull in a neighbor.
        let cell = r.insetBy(dx: -r.width / 18, dy: -r.height / 18)
        if case .digit = self {
            paint(cell: cell, ctx: ctx)
        } else if let image = Prerendered.take(self, for: ctx) {
            if isData, let bytes = image.dataProvider?.data as Data? {
                Self.write(bytes, rowBytes: image.bytesPerRow, size: image.width, into: ctx, at: cell)
            } else {
                ctx.draw(image, in: cell)
            }
        } else {
            paint(cell: cell, ctx: ctx)
        }
    }

    /// Data cells (read as numbers, not drawn as color).
    var isData: Bool {
        switch self {
        case .teamMask, .escortedMask, .standardField: true
        default: false
        }
    }

    /// Paints the sprite into `cell` (the whole atlas cell).
    fileprivate func paint(cell: CGRect, ctx: CGContext) {
        let canvas = Canvas(ctx: ctx, origin: cell.origin, size: cell.width)
        switch self {
        case let .body(type, east):
            canvas.paint(Self.recorded(type, east: east).steps, pass: .body)
        case let .teamMask(type):
            let partner = Self.pairedData.first { $0.0 == type }?.1
            Self.paintData(Self.recorded(type, east: false).steps, team: true, cell: cell, ctx: ctx,
                           high: partner.map { Self.recorded($0, east: false).steps })
        case let .escortedBody(east):
            canvas.paint(Self.recorded(.settler, east: east, pole: false).steps, pass: .body)
        case .escortedMask:
            Self.paintData(Self.recorded(.settler, east: false, pole: false).steps, team: true, cell: cell, ctx: ctx)
        case let .standard(player):
            canvas.paint(Self.standardFigure(size: cell.width).steps, pass: .player(Palette.playerStyle(player)))
        case .standardField:
            Self.paintData(Self.standardFigure(size: cell.width).steps, team: false, cell: cell, ctx: ctx)
        case let .emblem(player):
            canvas.emblem(Palette.playerStyle(player), center: CGPoint(x: cell.width / 2, y: cell.width / 2), size: cell.width * 0.8,
                          clip: nil, crisp: true)
        case let .badge(type):
            var f = Figure(size: cell.width)
            Self.badge(type, &f)
            canvas.paint(f.steps, pass: .body)
        case let .marker(final):
            var f = Figure(size: cell.width)
            Self.marker(&f, final: final)
            canvas.paint(f.steps, pass: .body)
        case let .digit(d):
            Self.digit(d, cell: cell, ctx: ctx)
        case let .job(kind):
            var f = Figure(size: cell.width)
            Self.jobBadge(kind, &f)
            canvas.paint(f.steps, pass: .body)
        case .tribalVillage:
            var f = Figure(size: cell.width)
            Self.tribalVillageBadge(&f)
            canvas.paint(f.steps, pass: .body)
        }
    }

    // MARK: Geometry shared with instance building (fractions of the cell, y up)

    /// Height where figures stand (feet, hooves, wheels) in a body cell.
    static let groundLine: Float = 0.1

    /// How far above `groundLine` the bodies' legs, hooves and wheels reach (cell fractions):
    /// trees standing in front may cover a figure up to here, never its shield, wagon bed,
    /// rider or standard (ART.md §5).
    static let legTop: Float = 0.17

    /// Where a unit's standard stands on its pole (body cell fractions): the standard's pole
    /// foot, `standardFoot` in its own cell, goes here.
    static func standardMount(_ type: UnitType, east: Bool) -> SIMD2<Float> {
        let x: Float = switch type {
        case .settler: 0.5
        case .builder: 0.684 // the surveyor's rod
        case .warrior, .archer, .spearman, .swordsman, .manAtArms, .crossbowman, .pikeman: 0.596
        case .scout, .horseman, .knight, .heavyChariot: 0.612
        case .catapult, .trebuchet: siegeBearer.x - 0.09 * siegeBearer.k
        }
        let k = bodyFit(type), fx = 0.5 + (x - 0.5) * k
        return [east ? 1 - fx : fx, groundLine + (standardMountY - groundLine) * k]
    }
    static let standardMountY: Float = 0.8

    /// How much each body is shrunk about its feet so its widest parts (the ox's muzzle and the
    /// tail barrel, the horse's tail) stay inside the cell's margin.
    static func bodyFit(_ type: UnitType) -> Float {
        switch type {
        case .settler: 0.93
        case .builder, .warrior, .archer, .spearman, .swordsman, .manAtArms, .crossbowman, .pikeman: 1
        case .scout, .horseman, .knight, .heavyChariot: 0.97
        case .catapult, .trebuchet: 0.95
        }
    }

    /// Where a siege engine's standard-bearer stands (feet x, build), beside the engine.
    private static let siegeBearer: (x: Float, k: Float) = (0.2, 0.86)

    /// The standard is painted in a frame of its own (`standard`, fractions, y up) and fitted
    /// into the middle of its cell by this scale about this point, so its rim has room all
    /// around even zoomed out, where a cell texel is a small part of a point and the rim's
    /// distance field (which ends at the cell's border) needs many texels.
    static let standardArtFit: Float = 0.7
    private static let standardArtPivot: SIMD2<Float> = [0.5, 0.47]
    private static func standardCell(_ x: Float, _ y: Float) -> SIMD2<Float> {
        standardArtPivot + (SIMD2(x, y) - standardArtPivot) * standardArtFit
    }
    /// The standard's frame: the pole's foot, the cloth's top and its swallowtail's tips, and
    /// the emblem's size.
    private static let standardArtFoot: CGFloat = 0.1, standardArtTop: CGFloat = 0.71, standardArtTips: CGFloat = 0.13
    private static let standardArtEmblem: CGFloat = 0.38

    /// Standard cell edge, in body cell edges (the standard itself is `standardArtFit` of it).
    static let standardSize: Float = 0.4 / standardArtFit
    /// The standard's pole foot (x, y) and the cloth's top and bottom (swallowtail tips), as
    /// fractions of the standard cell; the shader sways the cloth below its top.
    static let standardFoot: SIMD2<Float> = standardCell(0.5, Float(standardArtFoot))
    static let standardClothTop: Float = standardCell(0.5, Float(standardArtTop)).y
    static let standardClothBottom: Float = standardCell(0.5, Float(standardArtTips)).y
    /// The emblem on a standard's cloth, as a fraction of the standard cell.
    static let standardEmblemSize: Float = Float(standardArtEmblem) * standardArtFit

    /// Emblems painted on a body (shield faces): center x, y and the emblem cell's width and
    /// height, as fractions of the body cell, for the facing given. Drawn as instances in the
    /// owner's emblem, so bodies stay shared.
    static func emblemSpots(_ type: UnitType, east: Bool) -> [SIMD4<Float>] {
        recorded(type, east: east).emblems
    }

    /// The pin point of a marker (bottom center) and the center of its round face, as
    /// fractions of the cell from the bottom.
    static let markerPin: Float = 0.09
    static let markerFace: Float = 0.58

    /// Strategic medallions (`unitMedallion` in `ShaderUnits.swift`), in frame widths: the
    /// frame's rings from the outside in (its dark rim, the band in the owner's color and ring
    /// pattern, the dark keyline inside it) end at `medallionField`, the cream field's radius,
    /// which shows the middle of the type's `badge` cell scaled so `badgeField` of the cell
    /// fills it. Its badges (the owner's emblem on the lower right, the civilian an escort
    /// wears on the upper right) are centered `medallionBadge` from the frame's center, toward
    /// the hex's corners (x right, y up), and `medallionBadgeSize` wide.
    static let medallionRim: Float = 0.022 / 0.72
    static let medallionBand: Float = 0.064 / 0.72
    static let medallionKey: Float = 0.014 / 0.72
    static var medallionField: Float { 0.5 - medallionRim - medallionBand - medallionKey }
    static let badgeField: Float = 0.294
    static let medallionBadge: SIMD2<Float> = [0.33, 0.19]
    static let medallionBadgeSize: Float = 0.5
    /// An emblem cell's emblem spans 0.8 of the cell; on a badge it spans this much of the
    /// badge's colored disc.
    static let badgeEmblem: Float = 0.75
    /// A medallion's quad and an emblem badge's, in their frames' widths: room for the outer
    /// ink outline and its antialiasing (`kUnitMedallionQuad`, `kUnitBadgeQuad`).
    static let medallionQuad: Float = 1.1
    static let badgeQuad: Float = 1.16
    /// A badge cell's disc, as a fraction of the cell.
    static let badgeDisc: Float = 0.8

    /// A unit base's quad: its ellipse's radii times `baseMargin` (room for the contact shadow
    /// and the selected glow) plus `baseBandRoom` band widths (the band, its keylines and rim
    /// stay screen-constant). The base itself is procedural (`unitBase` in `ShaderUnits.swift`).
    static let baseMargin: Float = 1.3
    static let baseBandRoom: Float = 2.2
    /// The base band's width in view points (screen-constant, so it never gets heavy up close;
    /// wide enough for every ring pattern's features to be a point or more).
    static let baseBandPoints: Float = 3

    /// The rim around figures and standards (ART.md §3): the cream's width and the dark line's
    /// outside it (on lighter ground) in view points, and how far out (texels of the cell at
    /// full size) the silhouette distance fields reach, which bounds the rim far out.
    static let rimPoints: Float = 1.75
    static let rimLinePoints: Float = 1.25
    static let rimRange: Float = 32

    /// The painted extent of a body or standard, outline included (lo x, lo y, hi x, hi y, as
    /// fractions of its cell, y up). Instances are trimmed to it (plus the rim around it), so
    /// the unit pass shades no empty texels. Other sprites fill their cell.
    static func bounds(_ key: UnitSprite) -> SIMD4<Float> {
        switch key {
        case let .body(type, east): recorded(type, east: east).bounds
        case let .escortedBody(east): recorded(.settler, east: east, pole: false).bounds
        case .standard: standardBounds
        default: [0, 0, 1, 1]
        }
    }

    private static let standardBounds: SIMD4<Float> = {
        standardFigure(size: 128).steps.bounds(size: 128)
    }()

    // MARK: Materials

    // Muted natural colors, so the player color and the figure out-contrast the terrain without
    // competing with each other.
    fileprivate static let wood = Tone(0.55, 0.38, 0.22), darkWood = Tone(0.36, 0.24, 0.15)
    fileprivate static let iron = Tone(0.55, 0.57, 0.62), bronze = Tone(0.82, 0.6, 0.3)
    fileprivate static let skin = Tone(0.9, 0.67, 0.5), linen = Tone(0.9, 0.85, 0.72)
    fileprivate static let leather = Tone(0.54, 0.35, 0.2), darkLeather = Tone(0.3, 0.2, 0.13)
    fileprivate static let canvas = Tone(0.95, 0.9, 0.78), gold = Tone(0.93, 0.74, 0.32)
    fileprivate static let ink = Tone(0.1, 0.07, 0.05), cream = Tone(0.98, 0.94, 0.84)
    fileprivate static let rimBrown = Tone(0.27, 0.17, 0.1)

    // MARK: Recorded bodies

    private struct FigureKey: Hashable {
        var type: UnitType
        var east: Bool
        var pole = true
    }

    /// Every body recorded once (both facings), shared by the atlas build and instance building.
    private static let recordings: [FigureKey: RecordedFigure] = {
        let keys = UnitType.allCases.flatMap { type in [false, true].map { FigureKey(type: type, east: $0) } }
            + [false, true].map { FigureKey(type: .settler, east: $0, pole: false) }
        let done = Mutex<[FigureKey: RecordedFigure]>([:])
        DispatchQueue.concurrentPerform(iterations: keys.count) { i in
            let key = keys[i]
            var figure = Figure(size: 256, mirrored: key.east, fit: CGFloat(bodyFit(key.type)))
            switch key.type {
            case .settler: settler(&figure, pole: key.pole)
            case .builder: builder(&figure)
            case .warrior: warrior(&figure)
            case .archer: archer(&figure)
            case .spearman: spearman(&figure)
            case .scout: scout(&figure)
            case .horseman: scout(&figure, coat: Tone(0.38, 0.27, 0.2), kit: .lance)
            case .knight: scout(&figure, coat: Tone(0.82, 0.8, 0.76), kit: .armored)
            case .heavyChariot: scout(&figure, coat: Tone(0.5, 0.32, 0.2), kit: .chariot)
            case .swordsman: swordsman(&figure)
            case .manAtArms: manAtArms(&figure)
            case .crossbowman: crossbowman(&figure)
            case .pikeman: pikeman(&figure)
            case .catapult: siege(&figure, trebuchet: false)
            case .trebuchet: siege(&figure, trebuchet: true)
            }
            let recorded = RecordedFigure(steps: figure.steps, emblems: figure.emblems, size: figure.size)
            done.withLock { $0[key] = recorded }
        }
        return done.withLock { $0 }
    }()

    fileprivate static func recorded(_ type: UnitType, east: Bool, pole: Bool = true) -> RecordedFigure {
        recordings[FigureKey(type: type, east: east, pole: pole)]!
    }

    /// Touches the recordings so they are built before parallel work needs them.
    fileprivate static func prepareRecordings() { _ = recordings.count }

    // MARK: Bodies

    /// Banner pole from `bottom` to just above the standard's foot (which overlaps it).
    private static func pole(_ f: inout Figure, x: CGFloat, from bottom: CGFloat, width: CGFloat = 0.02) {
        let top = CGFloat(standardMountY) + 0.05
        f.add(f.limb([(x, bottom), (x, top)], width * 1.1, width), Material(darkWood, grain: .wood), outline: 0.011)
    }

    /// A draft ox hauling a covered wagon with its driver. The team color is the hood's painted
    /// band and the driver's tunic.
    private static func settler(_ f: inout Figure, pole hasPole: Bool) {
        let hide = Tone(0.5, 0.33, 0.21), hideDark = Tone(0.36, 0.24, 0.16), hoof = Tone(0.19, 0.14, 0.1)
        let horn = Tone(0.95, 0.89, 0.74), muzzle = Tone(0.78, 0.64, 0.54)

        // Far-side wheels peek out under the bed.
        for (cx, cy, rad) in [(0.545, 0.19, 0.074), (0.858, 0.2, 0.086)] as [(CGFloat, CGFloat, CGFloat)] {
            f.add(f.ellipse(cx, cy, rad, rad), Material(darkWood.scaled(0.7), shade: 0.5, light: 0.3), outline: 0.014)
        }
        // Wagon tongue from the yoke to the bed, mostly behind the ox.
        f.add(f.limb([(0.2, 0.43), (0.47, 0.27)], 0.016, 0.016), Material(darkWood, grain: .wood), outline: 0.01)
        // Ox: far legs, far horn and tail first, in the body's shade.
        let farLeg = Material(hideDark.scaled(0.86), grain: .hide)
        f.add(f.limb([(0.2, 0.3), (0.196, 0.2), (0.198, 0.122)], 0.058, 0.036), farLeg)
        f.add(f.limb([(0.352, 0.31), (0.36, 0.21), (0.352, 0.122)], 0.066, 0.036), farLeg)
        for x in [0.198, 0.352] as [CGFloat] {
            f.add(f.blob([(x - 0.024, 0.1), (x + 0.022, 0.1), (x + 0.019, 0.13), (x - 0.02, 0.13)]), Material(hoof.scaled(0.8)), outline: 0.01)
        }
        f.add(f.limb([(0.122, 0.47), (0.118, 0.515), (0.142, 0.548)], 0.026, 0.01), Material(horn.scaled(0.78)), outline: 0.009)
        f.add(f.limb([(0.396, 0.43), (0.414, 0.36), (0.41, 0.24)], 0.018, 0.012), Material(hideDark), outline: 0.009)
        f.add(f.blob([(0.398, 0.258), (0.418, 0.26), (0.424, 0.208), (0.41, 0.19), (0.395, 0.214)]), Material(Tone(0.22, 0.15, 0.1)), outline: 0.009)
        // One silhouette for the barrel, the hump over the shoulders, the thick neck and dewlap,
        // and the upper legs, so only knees and hocks show as joints.
        let barrel = f.blob([(0.16, 0.3), (0.13, 0.36), (0.138, 0.43), (0.172, 0.49), (0.215, 0.52), (0.262, 0.505),
                             (0.33, 0.47), (0.39, 0.462), (0.418, 0.42), (0.416, 0.33), (0.38, 0.272), (0.3, 0.262), (0.22, 0.27)])
        let neck = f.blob([(0.2, 0.495), (0.16, 0.5), (0.118, 0.468), (0.098, 0.42), (0.112, 0.36), (0.14, 0.31), (0.175, 0.3),
                           (0.185, 0.4)])
        let dewlap = f.blob([(0.118, 0.37), (0.122, 0.31), (0.142, 0.272), (0.168, 0.28), (0.16, 0.33)])
        let foreArm = f.limb([(0.17, 0.33), (0.162, 0.25), (0.158, 0.2)], 0.074, 0.05)
        let thigh = f.limb([(0.385, 0.38), (0.398, 0.29), (0.392, 0.215)], 0.1, 0.05)
        let ox = barrel.union(neck).union(dewlap).union(foreArm).union(thigh)
        f.add(ox, Material(hide, grain: .hide))
        f.decal(f.blob([(0.19, 0.29), (0.28, 0.275), (0.37, 0.285), (0.33, 0.31), (0.23, 0.31)]), hide.lit, alpha: 0.22, clip: ox)
        f.decal(f.blob([(0.21, 0.505), (0.25, 0.49), (0.3, 0.47), (0.26, 0.5)]), hide.lit, alpha: 0.35, clip: ox)
        // Near lower legs (knee, cannon, cloven hoof).
        let leg = Material(hide.scaled(0.96), grain: .hide)
        f.add(f.limb([(0.158, 0.22), (0.154, 0.16), (0.152, 0.124)], 0.042, 0.036), leg)
        f.add(f.limb([(0.392, 0.235), (0.402, 0.17), (0.396, 0.124)], 0.046, 0.036), leg)
        for x in [0.152, 0.396] as [CGFloat] {
            f.add(f.blob([(x - 0.027, 0.098), (x + 0.025, 0.098), (x + 0.022, 0.13), (x - 0.023, 0.13)]), Material(hoof), outline: 0.012)
            f.decal(f.rectPath(x - 0.002, 0.099, 0.004, 0.028), ink, alpha: 0.5)
        }
        // Head carried low and forward: broad brow, pale muzzle, ear, eye, horns sweeping up.
        let head = f.blob([(0.13, 0.465), (0.1, 0.476), (0.072, 0.452), (0.056, 0.4), (0.046, 0.35), (0.05, 0.31), (0.074, 0.294),
                           (0.1, 0.31), (0.122, 0.36), (0.14, 0.42)])
        f.add(head, Material(hide, grain: .hide))
        f.add(f.ellipse(0.066, 0.318, 0.03, 0.03), Material(muzzle), outline: 0)
        f.add(f.ellipse(0.054, 0.326, 0.0075, 0.0065), Material(ink, shade: 0, light: 0), outline: 0)
        f.add(f.ellipse(0.093, 0.414, 0.011, 0.012), Material(ink, shade: 0, light: 0), outline: 0)
        f.decal(f.ellipse(0.09, 0.418, 0.004, 0.004), Tone(1, 0.95, 0.85), alpha: 0.9)
        f.add(f.blob([(0.13, 0.448), (0.168, 0.452), (0.188, 0.434), (0.15, 0.426)]), Material(hideDark), outline: 0.008)
        f.add(f.limb([(0.118, 0.47), (0.094, 0.502), (0.096, 0.54), (0.116, 0.566)], 0.03, 0.01), Material(horn), outline: 0.01)
        f.decal(f.ellipse(0.114, 0.561, 0.008, 0.009), Tone(0.3, 0.24, 0.18), alpha: 0.85)
        // Yoke across the neck in front of the hump.
        f.add(f.limb([(0.142, 0.488), (0.21, 0.51)], 0.032, 0.032), Material(wood, grain: .wood), outline: 0.012)
        f.decalStroke(f.limb([(0.158, 0.48), (0.148, 0.43), (0.166, 0.38)], 0.012, 0.012), wood.scaled(0.8), width: 0.012)

        // Banner pole at the front of the bed, behind the driver.
        if hasPole { pole(&f, x: 0.5, from: 0.24) }
        // Wagon bed with plank lines and a rail.
        f.add(f.poly([(0.46, 0.222), (0.93, 0.232), (0.94, 0.338), (0.455, 0.33)]), Material(wood, grain: .planks))
        f.decal(f.poly([(0.455, 0.316), (0.94, 0.324), (0.94, 0.338), (0.455, 0.33)]), darkWood, alpha: 0.7)
        // Canvas hood over its hoops: a dark opening at the front and the team's painted band.
        let hood = f.blob([(0.48, 0.325), (0.468, 0.43), (0.492, 0.54), (0.574, 0.625), (0.7, 0.655), (0.826, 0.625),
                           (0.912, 0.54), (0.932, 0.43), (0.926, 0.333)])
        f.add(hood, Material(canvas, grain: .cloth))
        f.add(hood.intersection(f.rectPath(0.3, 0.436, 0.8, 0.066)), Material(team: 1, grain: .cloth), outline: 0)
        for x in [0.62, 0.738, 0.846] as [CGFloat] {
            f.decal(f.limb([(x - 0.012, 0.335), (x - 0.02, 0.48), (x - 0.008, 0.63)], 0.012, 0.01), Tone(0.48, 0.4, 0.3), alpha: 0.32, clip: hood)
        }
        f.add(f.ellipse(0.503, 0.448, 0.03, 0.104), Material(Tone(0.27, 0.19, 0.14), shade: 0.4, light: 0.2), outline: 0)
        // Driver on the front board in a straw hat, tunic in the team color.
        func dr(_ x: CGFloat, _ y: CGFloat) -> (CGFloat, CGFloat) { (0.478 + (x - 0.465) * 1.15, 0.333 + (y - 0.355) * 1.15) }
        f.add(f.blob([dr(0.424, 0.355), dr(0.418, 0.435), dr(0.433, 0.497), dr(0.476, 0.508), dr(0.506, 0.462), dr(0.506, 0.355)]),
              Material(team: 1, grain: .cloth))
        f.add(f.limb([dr(0.445, 0.468), dr(0.408, 0.428), dr(0.382, 0.432)], 0.034, 0.028), Material(team: 0.82), outline: 0.01)
        let hand = dr(0.38, 0.432)
        f.add(f.ellipse(hand.0, hand.1, 0.018, 0.018), Material(skin), outline: 0.008)
        let face = dr(0.463, 0.543)
        f.add(f.ellipse(face.0, face.1, 0.039, 0.044), Material(skin))
        f.add(f.poly([dr(0.433, 0.55), dr(0.423, 0.535), dr(0.435, 0.529)]), Material(skin), outline: 0.006)
        let eye = dr(0.447, 0.55)
        f.add(f.ellipse(eye.0, eye.1, 0.007, 0.008), Material(ink, shade: 0, light: 0), outline: 0)
        let straw = Tone(0.88, 0.76, 0.45)
        let brim = dr(0.463, 0.568)
        f.add(f.ellipse(brim.0, brim.1, 0.078, 0.018), Material(straw, grain: .cloth))
        f.add(f.blob([dr(0.436, 0.572), dr(0.44, 0.61), dr(0.463, 0.622), dr(0.488, 0.61), dr(0.492, 0.572)]), Material(straw), outline: 0.008)
        let band = dr(0.437, 0.574)
        f.decal(f.rectPath(band.0, band.1, 0.062, 0.013), Tone(0.5, 0.3, 0.15), alpha: 0.75)
        // Reins to the ox.
        f.decal(f.limb([hand, (0.26, 0.45), (0.1, 0.4)], 0.006, 0.005), ink, alpha: 0.55)
        // Water barrel lashed to the back.
        f.add(f.blob([(0.888, 0.262), (0.884, 0.318), (0.892, 0.372), (0.946, 0.372), (0.954, 0.318), (0.948, 0.262)]),
              Material(wood, grain: .planks))
        f.decal(f.rectPath(0.884, 0.29, 0.07, 0.011), iron.scaled(0.75), alpha: 0.9)
        f.decal(f.rectPath(0.886, 0.34, 0.066, 0.011), iron.scaled(0.75), alpha: 0.9)
        // Spoked wheels.
        f.wheel(0.53, 0.178, 0.078)
        f.wheel(0.814, 0.19, 0.09)
    }

    /// One figure of an infantry group (warriors, archers, spearmen, builders): where its feet
    /// stand (`x`, `y`, cell fractions), its build (`k`, `skin`) and its kit. Each group poses
    /// its three figures differently, so a squad never looks stamped (ART.md §6); kit and
    /// silhouette tell the groups apart at a glance: bronze helmets, big round shields and long
    /// spears (spearmen); bare heads, fur, axes and small shields (warriors); hoods, bows and
    /// quivers (archers); straw hats, tools and a wheelbarrow (builders).
    private struct Person {
        enum Head { case helmet(Crest), hood, strawHat, cap, hair, headband }
        enum Crest { case tall, plume, ridge }
        enum Torso { case cuirass(Tone), tunic, jerkin(Tone), fur }
        enum Lower { case skirt, tunic, kilt }
        enum Legs { case greaves, wraps, bare }
        /// What the hands hold: a spear upright or leveled, the standard's pole, a long axe
        /// raised in both hands, a club cocked over the shoulder, a bow drawn or held ready,
        /// a pick raised overhead, a wheelbarrow's handles, a surveyor's rod (which carries the
        /// standard).
        enum Gear { case spearUp, spearLevel, standard, axeRaised, club, bowDrawn, bowReady, pickRaised, barrow, rod }
        enum Shield { case none, front, turned, slung, buckler }
        var x: CGFloat, y: CGFloat, k: CGFloat
        var skin: CGFloat = 1
        var head: Head
        var torso: Torso
        var lower: Lower
        var legs: Legs
        var gear: Gear
        var shield: Shield = .none
        var beard = true
        /// A quiver of arrows on the back (archers), and a bow slung across it.
        var quiver = false
        var slungBow = false
        /// How far the stride opens (1 standing, more striding forward).
        var stride: CGFloat = 1
        /// Sleeves of the tunic or jerkin to the wrist (archers, builders); else bare arms.
        var sleeves = false
    }

    /// Three spearmen: a rear guard with his spear upright and his shield turned, the
    /// standard-bearer with his shield slung, and a front-rank soldier behind his big round
    /// shield, spear leveled.
    private static func spearman(_ f: inout Figure) {
        person(&f, Person(x: 0.29, y: 0.205, k: 0.86, skin: 0.9, head: .helmet(.tall), torso: .cuirass(leather), lower: .skirt,
                          legs: .greaves, gear: .spearUp, shield: .turned))
        person(&f, Person(x: 0.672, y: 0.215, k: 0.84, skin: 1.04, head: .helmet(.plume), torso: .cuirass(Tone(0.62, 0.44, 0.27)),
                          lower: .skirt, legs: .greaves, gear: .standard, shield: .slung, stride: 0.8))
        person(&f, Person(x: 0.462, y: 0.1, k: 1.0, skin: 0.97, head: .helmet(.ridge), torso: .cuirass(leather.scaled(0.92)),
                          lower: .skirt, legs: .greaves, gear: .spearLevel, shield: .front, stride: 1.25))
    }

    /// Three warriors, bareheaded in furs: one swinging a long axe overhead, the
    /// standard-bearer with a small shield slung, and a front-rank fighter behind a small round
    /// shield with a club cocked over his shoulder.
    private static func warrior(_ f: inout Figure) {
        person(&f, Person(x: 0.285, y: 0.205, k: 0.86, skin: 0.92, head: .headband, torso: .fur, lower: .kilt, legs: .bare,
                          gear: .axeRaised, stride: 1.15))
        person(&f, Person(x: 0.672, y: 0.215, k: 0.84, skin: 1.03, head: .hair, torso: .tunic, lower: .kilt, legs: .bare,
                          gear: .standard, shield: .slung, stride: 0.8))
        person(&f, Person(x: 0.47, y: 0.1, k: 1.0, skin: 0.95, head: .headband, torso: .tunic, lower: .kilt, legs: .bare,
                          gear: .club, shield: .buckler, stride: 1.3))
    }

    /// Three hooded archers in leather: one drawing his bow at the sky, the standard-bearer
    /// with his bow slung, and one in front with an arrow nocked, bow held low and ready.
    private static func archer(_ f: inout Figure) {
        person(&f, Person(x: 0.27, y: 0.205, k: 0.86, skin: 0.95, head: .hood, torso: .jerkin(Tone(0.42, 0.36, 0.22)), lower: .tunic,
                          legs: .wraps, gear: .bowDrawn, beard: false, quiver: true, stride: 1.2, sleeves: true))
        person(&f, Person(x: 0.672, y: 0.215, k: 0.84, skin: 1.02, head: .cap, torso: .tunic, lower: .tunic, legs: .wraps,
                          gear: .standard, quiver: true, slungBow: true, stride: 0.8, sleeves: true))
        person(&f, Person(x: 0.462, y: 0.1, k: 1.0, skin: 0.9, head: .hood, torso: .jerkin(leather.scaled(0.9)), lower: .tunic,
                          legs: .wraps, gear: .bowReady, beard: false, quiver: true, stride: 1.15, sleeves: true))
    }

    /// Three workers in straw hats and work tunics: one swinging a pick, a surveyor with his
    /// striped rod (which carries the standard), and one in front pushing a wheelbarrow of
    /// building stone.
    private static func builder(_ f: inout Figure) {
        person(&f, Person(x: 0.26, y: 0.205, k: 0.86, skin: 0.93, head: .strawHat, torso: .tunic, lower: .tunic, legs: .wraps,
                          gear: .pickRaised, beard: false, stride: 1.2, sleeves: true))
        person(&f, Person(x: 0.76, y: 0.215, k: 0.84, skin: 1.03, head: .cap, torso: .tunic, lower: .tunic, legs: .wraps,
                          gear: .rod, stride: 0.75, sleeves: true))
        person(&f, Person(x: 0.6, y: 0.1, k: 1.0, skin: 0.9, head: .strawHat, torso: .tunic, lower: .tunic, legs: .wraps,
                          gear: .barrow, stride: 1.35, sleeves: true))
    }

    /// Three swordsmen in iron caps and leather cuirasses (M2 §8.1): the blade cocked over the
    /// shoulder, the standard-bearer, and a front-rank fighter behind his round shield.
    private static func swordsman(_ f: inout Figure) {
        person(&f, Person(x: 0.285, y: 0.205, k: 0.86, skin: 0.94, head: .helmet(.ridge), torso: .cuirass(leather), lower: .skirt,
                          legs: .greaves, gear: .club, shield: .turned, stride: 1.1))
        person(&f, Person(x: 0.672, y: 0.215, k: 0.84, skin: 1.02, head: .helmet(.ridge), torso: .cuirass(leather.scaled(0.9)),
                          lower: .skirt, legs: .greaves, gear: .standard, shield: .slung, stride: 0.8))
        person(&f, Person(x: 0.47, y: 0.1, k: 1.0, skin: 0.96, head: .helmet(.ridge), torso: .cuirass(leather.scaled(0.95)),
                          lower: .skirt, legs: .greaves, gear: .club, shield: .front, stride: 1.25))
    }

    /// Three men-at-arms in iron, plumed: long axes raised, the standard-bearer, a front rank
    /// behind his shield.
    private static func manAtArms(_ f: inout Figure) {
        person(&f, Person(x: 0.285, y: 0.205, k: 0.86, skin: 0.9, head: .helmet(.plume), torso: .cuirass(iron), lower: .skirt,
                          legs: .greaves, gear: .axeRaised, stride: 1.1))
        person(&f, Person(x: 0.672, y: 0.215, k: 0.84, skin: 1.0, head: .helmet(.plume), torso: .cuirass(iron.scaled(0.9)),
                          lower: .skirt, legs: .greaves, gear: .standard, shield: .slung, stride: 0.8))
        person(&f, Person(x: 0.47, y: 0.1, k: 1.0, skin: 0.95, head: .helmet(.tall), torso: .cuirass(iron.scaled(0.95)),
                          lower: .skirt, legs: .greaves, gear: .axeRaised, shield: .front, stride: 1.25))
    }

    /// Three crossbowmen in iron caps and quilted jerkins, weapons leveled.
    private static func crossbowman(_ f: inout Figure) {
        person(&f, Person(x: 0.27, y: 0.205, k: 0.86, skin: 0.95, head: .helmet(.ridge), torso: .jerkin(Tone(0.5, 0.44, 0.34)), lower: .tunic,
                          legs: .wraps, gear: .bowReady, quiver: true, stride: 1.1, sleeves: true))
        person(&f, Person(x: 0.672, y: 0.215, k: 0.84, skin: 1.02, head: .helmet(.ridge), torso: .tunic, lower: .tunic, legs: .wraps,
                          gear: .standard, shield: .slung, quiver: true, stride: 0.8, sleeves: true))
        person(&f, Person(x: 0.462, y: 0.1, k: 1.0, skin: 0.9, head: .helmet(.ridge), torso: .jerkin(Tone(0.46, 0.4, 0.3)), lower: .tunic,
                          legs: .wraps, gear: .bowReady, quiver: true, stride: 1.15, sleeves: true))
    }

    /// Three pikemen in tall helmets, pikes up and leveled, no shields.
    private static func pikeman(_ f: inout Figure) {
        person(&f, Person(x: 0.29, y: 0.205, k: 0.86, skin: 0.92, head: .helmet(.tall), torso: .cuirass(iron), lower: .skirt,
                          legs: .greaves, gear: .spearUp))
        person(&f, Person(x: 0.672, y: 0.215, k: 0.84, skin: 1.03, head: .helmet(.tall), torso: .cuirass(iron.scaled(0.9)),
                          lower: .skirt, legs: .greaves, gear: .standard, stride: 0.8))
        person(&f, Person(x: 0.462, y: 0.1, k: 1.0, skin: 0.97, head: .helmet(.tall), torso: .cuirass(iron.scaled(0.95)),
                          lower: .skirt, legs: .greaves, gear: .spearLevel, stride: 1.25))
    }

    /// A siege engine on its wheels, its timbers draped in the team color, with a crewman
    /// carrying the standard in front: a catapult (a throwing arm with its bucket) or a
    /// trebuchet (a tall A-frame, a long arm with its sling and a counterweight).
    private static func siege(_ f: inout Figure, trebuchet: Bool) {
        let grey = Tone(0.62, 0.6, 0.56)
        if trebuchet {
            f.add(f.limb([(0.5, 0.2), (0.64, 0.7)], 0.04, 0.032), Material(darkWood, grain: .wood))
            f.add(f.poly([(0.36, 0.17), (0.92, 0.17), (0.92, 0.24), (0.36, 0.24)]), Material(wood, grain: .planks))
            f.add(f.limb([(0.79, 0.22), (0.64, 0.7)], 0.04, 0.032), Material(wood, grain: .wood))
            f.add(f.limb([(0.4, 0.86), (0.86, 0.5)], 0.032, 0.026), Material(wood, grain: .wood))
            f.add(f.ellipse(0.64, 0.7, 0.024, 0.024), Material(iron, grain: .metal, gloss: 0.5), outline: 0.008)
            f.add(f.poly([(0.8, 0.5), (0.92, 0.5), (0.9, 0.35), (0.82, 0.35)]), Material(team: 1, grain: .cloth))
            f.decal(f.limb([(0.4, 0.86), (0.35, 0.72)], 0.007, 0.006), ink, alpha: 0.6)
            f.add(f.ellipse(0.35, 0.71, 0.028, 0.026), Material(grey), outline: 0.008)
            f.wheel(0.44, 0.15, 0.055)
            f.wheel(0.84, 0.15, 0.055)
        } else {
            f.add(f.limb([(0.52, 0.25), (0.54, 0.47)], 0.036, 0.03), Material(darkWood, grain: .wood))
            f.add(f.poly([(0.33, 0.2), (0.9, 0.2), (0.9, 0.28), (0.33, 0.28)]), Material(wood, grain: .planks))
            f.add(f.rectPath(0.56, 0.205, 0.18, 0.07), Material(team: 1, grain: .cloth))
            f.add(f.limb([(0.64, 0.27), (0.58, 0.47)], 0.036, 0.03), Material(wood, grain: .wood))
            f.add(f.limb([(0.5, 0.46), (0.62, 0.46)], 0.03, 0.03), Material(wood, grain: .wood))
            f.add(f.limb([(0.84, 0.29), (0.44, 0.62)], 0.032, 0.024), Material(wood, grain: .wood))
            f.add(f.ellipse(0.43, 0.63, 0.05, 0.032), Material(darkWood, grain: .wood))
            f.add(f.ellipse(0.43, 0.665, 0.03, 0.027), Material(grey), outline: 0.008)
            f.wheel(0.42, 0.18, 0.08)
            f.wheel(0.8, 0.18, 0.08)
        }
        person(&f, Person(x: CGFloat(siegeBearer.x), y: 0.1, k: CGFloat(siegeBearer.k), skin: 0.96, head: .cap, torso: .tunic, lower: .tunic,
                          legs: .wraps, gear: .standard, beard: false, stride: 0.9, sleeves: true))
    }

    private static func person(_ f: inout Figure, _ s: Person) {
        let k = s.k
        func p(_ x: CGFloat, _ y: CGFloat) -> (CGFloat, CGFloat) { (s.x + x * k, s.y + y * k) }
        func oval(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGPath {
            let c = p(x, y)
            return f.ellipse(c.0, c.1, rx * k, ry * k)
        }
        func limb(_ pts: [(CGFloat, CGFloat)], _ w0: CGFloat, _ w1: CGFloat) -> CGPath {
            f.limb(pts.map { p($0.0, $0.1) }, w0 * k, w1 * k)
        }
        func blob(_ pts: [(CGFloat, CGFloat)]) -> CGPath { f.blob(pts.map { p($0.0, $0.1) }) }
        func poly(_ pts: [(CGFloat, CGFloat)]) -> CGPath { f.poly(pts.map { p($0.0, $0.1) }) }
        let skinTone = skin.scaled(s.skin), farSkin = skin.scaled(s.skin * 0.84)
        /// An arm along `pts` ending in a hand.
        func arm(_ pts: [(CGFloat, CGFloat)], far: Bool, sleeve: Material? = nil, hand: Bool = true) {
            let material = sleeve ?? Material(far ? farSkin : skinTone)
            f.add(limb(pts, far ? 0.044 : 0.048, far ? 0.034 : 0.036), material, outline: far ? 0.011 : 0.012)
            if hand, let end = pts.last {
                f.add(oval(end.0, end.1, 0.022, 0.022), Material(far ? farSkin : skinTone), outline: 0.008)
            }
        }
        let sleeve: Material? = switch s.torso {
        case .tunic where s.sleeves: Material(team: 0.9, grain: .cloth)
        case let .jerkin(tone) where s.sleeves: Material(tone.scaled(0.95), grain: .hide)
        default: nil
        }

        // On the back, behind everything: a slung shield, a slung bow, a quiver.
        if s.shield == .slung {
            let small = s.gear != .standard || !isHoplite(s)
            let back = small ? oval(0.07, 0.35, 0.045, 0.1) : oval(0.074, 0.34, 0.05, 0.13)
            f.add(back, Material(team: 0.9, grain: .hide))
            f.decalStroke(back, small ? darkWood : bronze, width: 0.012 * k, clip: back)
        }
        if s.slungBow {
            f.add(limb([(0.1, 0.2), (0.122, 0.33), (0.1, 0.46), (0.05, 0.56)], 0.016, 0.012), Material(darkWood, grain: .wood), outline: 0.009)
            f.decal(limb([(0.1, 0.2), (0.05, 0.56)], 0.004, 0.004), linen, alpha: 0.8)
        }
        if s.quiver {
            let tilt: CGFloat = s.gear == .bowDrawn ? 0.03 : 0.0
            for (dx, h) in [(0.0, 0.0), (0.016, 0.012), (-0.014, 0.006)] as [(CGFloat, CGFloat)] {
                f.add(limb([(0.07 + dx + tilt, 0.5 + h), (0.08 + dx + tilt, 0.6 + h)], 0.012, 0.01), Material(linen, shade: 0.4), outline: 0.007)
            }
            let quiver = blob([(0.045 + tilt, 0.52), (0.1 + tilt, 0.53), (0.11, 0.3), (0.07, 0.29)])
            f.add(quiver, Material(darkLeather, grain: .hide), outline: 0.011)
            f.decal(limb([(0.052 + tilt, 0.49), (0.104 + tilt * 0.7, 0.5)], 0.012, 0.012), leather.scaled(1.2), alpha: 0.8, clip: quiver)
        }

        // The far arm and what it carries, behind the body.
        switch s.gear {
        case .spearUp:
            f.add(limb([(-0.03, 0.02), (-0.092, 0.74)], 0.018, 0.015), Material(wood, grain: .wood), outline: 0.01)
            spearhead(&f, at: p(-0.092, 0.73), angle: .pi / 2 + 0.086, k: k)
            arm([(0.028, 0.43), (-0.02, 0.37), (-0.072, 0.4)], far: true, sleeve: nil, hand: false)
            f.add(oval(-0.074, 0.4, 0.022, 0.022), Material(farSkin), outline: 0.008)
        case .spearLevel:
            // Shaft from behind the hip, through the far hand, angled forward and up.
            let butt = p(0.26, 0.25), tip = p(-0.3, 0.57)
            f.add(f.limb([butt, tip], 0.018 * k, 0.015 * k), Material(wood, grain: .wood), outline: 0.01)
            spearhead(&f, at: tip, angle: atan2(tip.1 - butt.1, tip.0 - butt.0), k: k)
            arm([(0.03, 0.43), (0.07, 0.36), (0.086, 0.335)], far: true, hand: false)
            f.add(oval(0.088, 0.334, 0.022, 0.022), Material(farSkin), outline: 0.008)
        case .standard, .rod:
            if s.gear == .rod {
                rod(&f, x: p(-0.09, 0).0, from: s.y + 0.02 * k)
            } else {
                pole(&f, x: p(-0.09, 0).0, from: s.y + 0.03 * k, width: 0.022)
            }
            arm([(0.03, 0.43), (-0.03, 0.47), (-0.08, 0.5)], far: true, sleeve: sleeve, hand: false)
            f.add(oval(-0.09, 0.5, 0.022, 0.022), Material(farSkin), outline: 0.008)
        case .axeRaised:
            // Wound up to strike: both hands behind the head, the haft rising up and back from
            // them, the blade high over the shoulders (the face stays clear).
            arm([(0.03, 0.43), (0.104, 0.52), (0.084, 0.652)], far: true, sleeve: sleeve, hand: false)
            axe(&f, haft: [p(0.03, 0.55), p(0.08, 0.66), p(0.14, 0.8)], k: k)
            f.add(oval(0.084, 0.652, 0.021, 0.021), Material(farSkin), outline: 0.008)
        case .club:
            // The club rests cocked on the far shoulder, ready to swing.
            arm([(0.03, 0.43), (0.075, 0.38), (0.06, 0.45)], far: true, sleeve: sleeve, hand: false)
            club(&f, from: p(0.055, 0.43), to: p(0.17, 0.66), k: k)
            f.add(oval(0.058, 0.448, 0.022, 0.022), Material(farSkin), outline: 0.008)
        case .bowDrawn:
            // The bow arm reaches forward and up to the grip.
            arm([(0.03, 0.44), (-0.07, 0.53), (-0.165, 0.563)], far: true, sleeve: sleeve, hand: false)
        case .bowReady:
            arm([(0.03, 0.43), (-0.06, 0.37), (-0.126, 0.339)], far: true, sleeve: sleeve, hand: false)
        case .pickRaised:
            // The same wind-up as the axe: hands behind the hat, the pick high over the back.
            arm([(0.03, 0.43), (0.104, 0.52), (0.084, 0.652)], far: true, sleeve: sleeve, hand: false)
            pick(&f, haft: [p(0.03, 0.55), p(0.08, 0.66), p(0.13, 0.78)], k: k)
            f.add(oval(0.084, 0.652, 0.021, 0.021), Material(farSkin), outline: 0.008)
        case .barrow:
            arm([(0.03, 0.42), (-0.03, 0.34), (-0.1, 0.28)], far: true, sleeve: sleeve, hand: false)
            f.add(limb([(-0.07, 0.29), (-0.2, 0.25)], 0.02, 0.02), Material(wood.scaled(0.8), grain: .wood), outline: 0.008)
            f.add(oval(-0.1, 0.285, 0.021, 0.021), Material(farSkin), outline: 0.008)
        }

        // Legs in a stride: thighs, lower legs and feet (far leg in shade).
        let stride = s.stride
        for (hip, knee, foot, tint) in [((0.024, 0.24), (0.046 * stride, 0.15), (0.06 * stride, 0.03), 0.8),
                                        ((-0.012, 0.24), (-0.032 * stride, 0.15), (-0.05 * stride, 0.03), 1.0)]
            as [((CGFloat, CGFloat), (CGFloat, CGFloat), (CGFloat, CGFloat), CGFloat)] {
            let thigh: Material = switch s.legs {
            case .wraps: Material(Tone(0.46, 0.38, 0.28).scaled(tint), grain: .cloth)
            default: Material(skinTone.scaled(tint))
            }
            f.add(limb([hip, knee], 0.056, 0.046), thigh)
            let shin = limb([(knee.0, knee.1 + 0.006), (foot.0, foot.1 + 0.012)], 0.05, 0.034)
            switch s.legs {
            case .greaves:
                f.add(shin, Material(bronze.scaled(tint), grain: .metal, gloss: 0.6))
            case .wraps:
                f.add(shin, Material(linen.scaled(0.86 * tint), grain: .cloth))
                for t in [0.3, 0.55, 0.8] as [CGFloat] {
                    let a = (knee.0 + (foot.0 - knee.0) * t, knee.1 + (foot.1 - knee.1) * t)
                    f.decal(limb([(a.0 - 0.024, a.1 - 0.012), (a.0 + 0.024, a.1 + 0.01)], 0.006, 0.006), darkLeather, alpha: 0.45, clip: shin)
                }
            case .bare:
                f.add(shin, Material(skinTone.scaled(tint * 0.96)))
                f.add(limb([(foot.0 + 0.002, 0.11), (foot.0, 0.04)], 0.052, 0.05), Material(Tone(0.5, 0.42, 0.33).scaled(tint), grain: .hide),
                      outline: 0.01)
            }
            f.add(blob([(foot.0 - 0.038, -0.002), (foot.0 + 0.026, -0.002), (foot.0 + 0.022, 0.026), (foot.0 - 0.012, 0.036)]),
                  Material(darkLeather.scaled(tint)), outline: 0.012)
        }

        // What hangs from the waist, then the torso and belt.
        switch s.lower {
        case .skirt:
            f.add(blob([(-0.076, 0.16), (-0.064, 0.256), (0.064, 0.256), (0.084, 0.16), (0.0, 0.14)]), Material(linen, grain: .cloth))
            for x in [-0.046, -0.015, 0.016, 0.047] as [CGFloat] {
                f.decal(limb([(x, 0.25), (x * 1.15, 0.166)], 0.016, 0.019), leather, alpha: 0.85)
            }
        case .tunic:
            let hem = blob([(-0.082, 0.15), (-0.066, 0.262), (0.066, 0.262), (0.088, 0.15), (0.0, 0.135)])
            f.add(hem, Material(team: 0.92, grain: .cloth))
            f.decal(limb([(-0.084, 0.158), (0.0, 0.142), (0.09, 0.158)], 0.012, 0.012), teamShade: 0.6, alpha: 0.7, clip: hem)
        case .kilt:
            let fur = Tone(0.47, 0.38, 0.28)
            f.add(poly([(-0.08, 0.26), (-0.086, 0.17), (-0.06, 0.15), (-0.04, 0.17), (-0.02, 0.142), (0.004, 0.166), (0.03, 0.14),
                        (0.052, 0.164), (0.076, 0.146), (0.09, 0.17), (0.076, 0.26)]),
                  Material(fur, grain: .hide), outline: 0.012)
        }
        let torsoPath = blob([(-0.06, 0.245), (-0.074, 0.335), (-0.056, 0.42), (-0.02, 0.455), (0.036, 0.455), (0.066, 0.406),
                              (0.06, 0.3), (0.054, 0.245)])
        switch s.torso {
        case let .cuirass(tone):
            f.add(torsoPath, Material(tone, grain: .hide))
        case .tunic:
            f.add(torsoPath, Material(team: 0.95, grain: .cloth))
            f.decal(limb([(-0.03, 0.45), (-0.012, 0.41), (0.012, 0.45)], 0.01, 0.01), teamShade: 0.55, alpha: 0.7, clip: torsoPath)
        case let .jerkin(tone):
            f.add(torsoPath, Material(tone, grain: .hide))
            for y in [0.3, 0.36, 0.42] as [CGFloat] {
                f.decal(limb([(-0.05, y), (0.05, y + 0.004)], 0.004, 0.004), tone.shadow, alpha: 0.6, clip: torsoPath)
            }
        case .fur:
            f.add(torsoPath, Material(team: 0.92, grain: .cloth))
            let pelt = blob([(-0.03, 0.46), (0.04, 0.462), (0.074, 0.41), (0.066, 0.3), (0.03, 0.27), (0.0, 0.34), (-0.04, 0.4)])
            f.add(pelt, Material(Tone(0.55, 0.45, 0.33), grain: .hide), outline: 0.01)
            f.decal(limb([(0.0, 0.44), (0.05, 0.3)], 0.008, 0.006), Tone(0.3, 0.24, 0.17), alpha: 0.4, clip: pelt)
        }
        f.decal(f.rectPath(s.x - 0.085 * k, s.y + 0.238 * k, 0.17 * k, 0.034 * k), darkLeather, alpha: 0.95, clip: torsoPath)

        // Head in profile: face, nose, eye and maybe a beard, under what it wears.
        let hair = Tone(0.3, 0.19, 0.12).scaled(s.skin)
        switch s.head {
        case .hair, .headband:
            // Hair first, so the face's outline sits over it.
            f.add(blob([(-0.04, 0.54), (-0.012, 0.574), (0.03, 0.576), (0.066, 0.55), (0.078, 0.49), (0.074, 0.44), (0.04, 0.45),
                        (0.03, 0.5)]), Material(hair, grain: .hide), outline: 0.011)
        default: break
        }
        f.add(oval(-0.008, 0.5, 0.052, 0.058), Material(skinTone))
        f.add(poly([(-0.052, 0.512), (-0.076, 0.488), (-0.052, 0.478)]), Material(skinTone), outline: 0.006)
        if s.beard {
            f.add(blob([(-0.056, 0.48), (-0.042, 0.446), (0.0, 0.44), (0.026, 0.47), (-0.01, 0.478)]),
                  Material(Tone(0.34, 0.21, 0.13).scaled(s.skin), grain: .hide), outline: 0.008)
        }
        f.add(oval(-0.034, 0.512, 0.008, 0.009), Material(ink, shade: 0, light: 0), outline: 0)
        switch s.head {
        case let .helmet(crest):
            let helmet = blob([(-0.07, 0.527), (-0.064, 0.574), (-0.031, 0.608), (0.02, 0.614), (0.063, 0.59), (0.078, 0.53),
                               (0.09, 0.476), (0.057, 0.47), (0.047, 0.52), (0.008, 0.53), (-0.02, 0.528)])
            f.add(helmet, Material(bronze, grain: .metal, gloss: 1))
            f.add(blob([(-0.027, 0.533), (-0.019, 0.468), (0.012, 0.46), (0.025, 0.531)]), Material(bronze.scaled(0.92), grain: .metal, gloss: 0.5),
                  outline: 0.006)
            f.decalStroke(limb([(-0.068, 0.529), (0.0, 0.537), (0.071, 0.521)], 0.001, 0.001), bronze.shadow, width: 0.006 * k)
            switch crest {
            case .tall:
                f.add(blob([(-0.07, 0.59), (-0.064, 0.66), (-0.02, 0.712), (0.05, 0.71), (0.112, 0.654), (0.13, 0.586),
                            (0.094, 0.6), (0.04, 0.636), (-0.02, 0.61)]), Material(team: 1, grain: .hide), outline: 0.012)
            case .plume:
                f.add(limb([(0.03, 0.6), (0.05, 0.66), (0.1, 0.69), (0.15, 0.67)], 0.05, 0.018), Material(team: 1, grain: .cloth), outline: 0.011)
            case .ridge:
                f.add(blob([(-0.062, 0.586), (-0.048, 0.64), (0.0, 0.676), (0.062, 0.666), (0.108, 0.618), (0.08, 0.6),
                            (0.03, 0.618), (-0.022, 0.6)]), Material(team: 1, grain: .hide), outline: 0.012)
            }
        case .hood:
            // A hood over the head and shoulders, open at the face, its point hanging behind.
            f.add(limb([(0.05, 0.56), (0.1, 0.52), (0.124, 0.44)], 0.04, 0.012), Material(team: 0.8, grain: .cloth), outline: 0.01)
            let hood = blob([(-0.05, 0.548), (-0.034, 0.59), (0.012, 0.61), (0.06, 0.588), (0.084, 0.53), (0.082, 0.44), (0.06, 0.41),
                             (0.0, 0.42), (-0.004, 0.46), (0.014, 0.5), (0.0, 0.54), (-0.03, 0.552)])
            f.add(hood, Material(team: 0.95, grain: .cloth))
            f.decal(limb([(-0.046, 0.55), (-0.004, 0.535), (0.01, 0.5), (-0.004, 0.452)], 0.012, 0.012), teamShade: 0.5, alpha: 0.75, clip: hood)
        case .strawHat:
            let straw = Tone(0.88, 0.76, 0.45)
            f.add(oval(-0.004, 0.556, 0.094, 0.02), Material(straw, grain: .cloth), outline: 0.01)
            f.add(blob([(-0.046, 0.56), (-0.04, 0.6), (-0.004, 0.616), (0.034, 0.6), (0.04, 0.56)]), Material(straw), outline: 0.009)
            f.decal(f.rectPath(s.x - 0.045 * k, s.y + 0.558 * k, 0.086 * k, 0.014 * k), Tone(0.5, 0.3, 0.15), alpha: 0.75)
        case .cap:
            let cap = blob([(-0.058, 0.53), (-0.05, 0.572), (-0.01, 0.6), (0.04, 0.596), (0.074, 0.56), (0.07, 0.52), (0.03, 0.536)])
            f.add(cap, Material(team: 0.9, grain: .cloth), outline: 0.011)
            f.decal(limb([(-0.058, 0.532), (0.0, 0.54), (0.07, 0.524)], 0.012, 0.012), teamShade: 0.55, alpha: 0.7, clip: cap)
            if s.quiver {
                // An archer's feather.
                f.add(limb([(0.03, 0.59), (0.08, 0.64), (0.13, 0.66)], 0.012, 0.022), Material(cream.scaled(0.95), grain: .cloth), outline: 0.008)
            }
        case .headband:
            f.add(limb([(-0.06, 0.538), (0.0, 0.552), (0.066, 0.53)], 0.018, 0.016), Material(team: 1, grain: .cloth), outline: 0.008)
            f.add(limb([(0.06, 0.53), (0.09, 0.5), (0.1, 0.46)], 0.014, 0.008), Material(team: 0.85, grain: .cloth), outline: 0.007)
        case .hair:
            f.add(limb([(0.06, 0.53), (0.098, 0.5), (0.106, 0.45)], 0.026, 0.014), Material(hair, grain: .hide), outline: 0.008)
        }

        // The near arm and what it holds, then the shield in front.
        switch s.gear {
        case .standard, .rod:
            arm([(-0.004, 0.43), (-0.03, 0.36), (-0.08, 0.34)], far: false, sleeve: sleeve)
        case .spearUp, .spearLevel:
            arm([(-0.004, 0.43), (-0.03, 0.36), (-0.05, 0.33)], far: false, sleeve: sleeve, hand: false)
        case .axeRaised, .pickRaised:
            // Up past the back of the head to the haft.
            arm([(0.0, 0.43), (0.078, 0.49), (0.058, 0.61)], far: false, sleeve: sleeve)
        case .club:
            arm([(-0.004, 0.43), (-0.03, 0.36), (-0.05, 0.33)], far: false, sleeve: sleeve, hand: false)
        case .bowDrawn:
            // Aimed at the sky: the near hand draws the string back to the cheek.
            bow(&f, nock: p(0.0, 0.468), aim: 2.62, reach: 0.19, k: k, hand: farSkin)
            arm([(-0.004, 0.43), (0.05, 0.44), (0.0, 0.468)], far: false, sleeve: sleeve)
        case .bowReady:
            // An arrow nocked, the bow held low and forward, the string barely drawn.
            bow(&f, nock: p(-0.01, 0.37), aim: 3.4, reach: 0.12, k: k, hand: farSkin)
            arm([(-0.004, 0.43), (0.012, 0.385), (-0.01, 0.37)], far: false, sleeve: sleeve)
        case .barrow:
            wheelbarrow(&f, at: p(0, 0), k: k)
            arm([(-0.004, 0.42), (-0.06, 0.33), (-0.12, 0.27)], far: false, sleeve: sleeve)
        }
        switch s.shield {
        case .front:
            let c = p(-0.058, 0.3), rx = 0.128 * k, ry = 0.148 * k
            let shield = f.ellipse(c.0, c.1, rx, ry)
            f.add(shield, Material(team: 1, grain: .hide))
            f.emblem(center: (c.0 - 0.003 * k, c.1 + 0.004 * k), size: 0.155 * k)
            f.decalStroke(f.ellipse(c.0, c.1, rx - 0.009 * k, ry - 0.009 * k), bronze, width: 0.018 * k)
            f.decalStroke(f.ellipse(c.0, c.1, rx - 0.009 * k, ry - 0.009 * k), bronze.lit, width: 0.006 * k, offset: (-0.003, 0.003))
        case .turned:
            // Seen three-quarters on: a narrower oval with its rim's thickness on the near side.
            let c = p(-0.07, 0.31), rx = 0.082 * k, ry = 0.142 * k
            f.add(f.ellipse(c.0 + 0.012 * k, c.1, rx, ry), Material(bronze.scaled(0.78), grain: .metal, gloss: 0.4))
            let shield = f.ellipse(c.0, c.1, rx, ry)
            f.add(shield, Material(team: 0.94, grain: .hide))
            f.emblem(center: (c.0, c.1 + 0.004 * k), size: 0.12 * k, aspect: 0.62)
            f.decalStroke(f.ellipse(c.0, c.1, rx - 0.008 * k, ry - 0.008 * k), bronze, width: 0.015 * k)
        case .buckler:
            // A small round hide shield on a wooden rim, held out at the chest.
            let c = p(-0.08, 0.35), r = 0.09 * k
            let shield = f.ellipse(c.0, c.1, r * 0.92, r)
            f.add(shield, Material(team: 1, grain: .hide))
            f.emblem(center: (c.0, c.1 + 0.003 * k), size: 0.11 * k)
            f.decalStroke(f.ellipse(c.0, c.1, r * 0.92 - 0.007 * k, r - 0.007 * k), darkWood, width: 0.014 * k)
            f.add(f.ellipse(c.0, c.1, 0.016 * k, 0.016 * k).subtracting(f.ellipse(c.0, c.1, 0.0, 0.0)), Material(iron, grain: .metal, gloss: 0.8),
                  outline: 0.006)
        case .none, .slung:
            break
        }
    }

    /// Whether a person is kitted as a spearman (bronze helmet), whose slung shield is the
    /// big round one.
    private static func isHoplite(_ s: Person) -> Bool {
        if case .helmet = s.head { return true }
        return false
    }

    /// Leaf-shaped iron spearhead whose base is at `p`, pointing along `angle`.
    private static func spearhead(_ f: inout Figure, at p: (CGFloat, CGFloat), angle: CGFloat, k: CGFloat) {
        let c = cos(angle), s = sin(angle)
        func q(_ along: CGFloat, _ across: CGFloat) -> (CGFloat, CGFloat) {
            (p.0 + (c * along - s * across) * k, p.1 + (s * along + c * across) * k)
        }
        f.add(f.blob([q(-0.012, 0.011), q(0.03, 0.021), q(0.1, 0.0), q(0.03, -0.021), q(-0.012, -0.011)]),
              Material(iron, grain: .metal, gloss: 0.9), outline: 0.01)
    }

    /// A long-hafted axe along `haft` (cell fractions, butt first): a bearded iron blade just
    /// below the top, its cutting edge on the haft's left (forward and up when the axe is
    /// raised behind the head), the haft standing a little proud of it.
    private static func axe(_ f: inout Figure, haft: [(CGFloat, CGFloat)], k: CGFloat) {
        f.add(f.limb(haft, 0.02 * k, 0.018 * k), Material(wood, grain: .wood), outline: 0.01)
        let top = haft[haft.count - 1], before = haft[haft.count - 2]
        let a = atan2(top.1 - before.1, top.0 - before.0)
        let c = cos(a), s = sin(a)
        // Blade frame: along the haft (0 at its top) and across it, toward the edge.
        func q(_ along: CGFloat, _ across: CGFloat) -> (CGFloat, CGFloat) {
            (top.0 + (c * along - s * across) * k, top.1 + (s * along + c * across) * k)
        }
        // The edge sweeps in a shallow arc from the toe (level with the eye's top) down to the
        // beard, which hooks back toward the hands; the neck narrows to the eye round the haft.
        let edge = (0...6).map { i -> (CGFloat, CGFloat) in
            let t = CGFloat(i) / 6
            return (-0.028 - 0.104 * t, 0.112 - 0.016 * t + 0.03 * sin(.pi * t))
        }
        let blade = f.poly([(-0.024, -0.022), (-0.026, 0.024), (-0.012, 0.06), (-0.016, 0.1)].map { q($0.0, $0.1) }
                           + edge.map { q($0.0, $0.1) }
                           + [(-0.11, 0.066), (-0.084, 0.04), (-0.074, 0.024), (-0.076, -0.022)].map { q($0.0, $0.1) })
        f.add(blade, Material(iron, grain: .metal, gloss: 0.9), outline: 0.011)
        // A bright bevel along the edge.
        f.decal(f.limb(edge.map { q($0.0, $0.1 - 0.012) }, 0.012 * k, 0.012 * k), iron.lit, alpha: 0.9, clip: blade)
    }

    /// A knobbed wooden club from its grip to its head.
    private static func club(_ f: inout Figure, from a: (CGFloat, CGFloat), to b: (CGFloat, CGFloat), k: CGFloat) {
        f.add(f.limb([a, b], 0.022 * k, 0.05 * k), Material(darkWood.scaled(1.15), grain: .wood), outline: 0.011)
        for t in [0.72, 0.86] as [CGFloat] {
            let c = (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t)
            f.add(f.ellipse(c.0 - 0.012 * k, c.1 + 0.006 * k, 0.012 * k, 0.01 * k), Material(iron.scaled(0.8), gloss: 0.6), outline: 0.006)
        }
    }

    /// A pick on a long haft (butt first), its double-pointed iron head across the top.
    private static func pick(_ f: inout Figure, haft: [(CGFloat, CGFloat)], k: CGFloat) {
        f.add(f.limb(haft, 0.02 * k, 0.018 * k), Material(wood, grain: .wood), outline: 0.01)
        let top = haft[haft.count - 1], before = haft[haft.count - 2]
        let a = atan2(top.1 - before.1, top.0 - before.0)
        let c = cos(a), s = sin(a)
        func q(_ along: CGFloat, _ across: CGFloat) -> (CGFloat, CGFloat) {
            (top.0 + (c * along - s * across) * k, top.1 + (s * along + c * across) * k)
        }
        // Curved, tapering to points either side of the haft.
        let head = f.limb([q(-0.07, 0.11), q(-0.005, 0.06), q(0.012, 0.0), q(-0.01, -0.06), q(-0.06, -0.11)], 0.008 * k, 0.008 * k)
            .union(f.ellipse(top.0, top.1, 0.024 * k, 0.024 * k))
        f.add(head, Material(iron, grain: .metal, gloss: 0.8), outline: 0.011)
    }

    /// A bow with an arrow nocked: the arrow leaves `nock` along `aim` (radians, cell space),
    /// the grip `reach` ahead of the nock in the far hand, the bow standing across the arrow
    /// with its limbs bent back toward the archer and the string drawn to the nock.
    private static func bow(_ f: inout Figure, nock: (CGFloat, CGFloat), aim: CGFloat, reach: CGFloat, k: CGFloat, hand: Tone) {
        let ax = cos(aim), ay = sin(aim)
        let grip = (nock.0 + ax * reach * k, nock.1 + ay * reach * k)
        // Along the bow: the arrow's direction turned a quarter clockwise, so the bow's top
        // leans back over the archer.
        let dx = ay, dy = -ax
        let up = dy >= 0 ? (dx, dy) : (-dx, -dy)
        let half: CGFloat = 0.2 * k, bend: CGFloat = 0.055 * k
        func at(_ t: CGFloat) -> (CGFloat, CGFloat) {
            let back = bend * t * t
            return (grip.0 + up.0 * half * t - ax * back, grip.1 + up.1 * half * t - ay * back)
        }
        let limbs = [at(-1), at(-0.55), at(0), at(0.55), at(1)]
        f.add(f.limb(limbs, 0.014 * k, 0.014 * k), Material(Tone(0.42, 0.27, 0.15), grain: .wood, gloss: 0.3), outline: 0.009)
        f.decal(f.limb([at(1), nock, at(-1)], 0.0045, 0.0045), linen, alpha: 0.95)
        arrow(&f, from: nock, to: (nock.0 + ax * (reach + 0.075) * k, nock.1 + ay * (reach + 0.075) * k), k: k)
        f.add(f.ellipse(grip.0, grip.1, 0.022 * k, 0.022 * k), Material(hand), outline: 0.008)
    }

    /// An arrow from its nock to its head, fletched.
    private static func arrow(_ f: inout Figure, from a: (CGFloat, CGFloat), to b: (CGFloat, CGFloat), k: CGFloat) {
        f.add(f.limb([a, b], 0.008 * k, 0.008 * k), Material(wood.scaled(1.1), grain: .wood), outline: 0.006)
        let angle = atan2(b.1 - a.1, b.0 - a.0)
        let c = cos(angle), s = sin(angle)
        func q(_ along: CGFloat, _ across: CGFloat, from o: (CGFloat, CGFloat)) -> (CGFloat, CGFloat) {
            (o.0 + (c * along - s * across) * k, o.1 + (s * along + c * across) * k)
        }
        f.add(f.poly([q(-0.006, 0.014, from: b), q(0.036, 0, from: b), q(-0.006, -0.014, from: b)]), Material(iron, gloss: 0.8), outline: 0.006)
        f.add(f.poly([q(0.0, 0.0, from: a), q(0.012, 0.016, from: a), q(0.046, 0.014, from: a), q(0.04, 0.0, from: a),
                      q(0.046, -0.014, from: a), q(0.012, -0.016, from: a)]), Material(cream.scaled(0.92)), outline: 0.006)
    }

    /// A surveyor's rod, striped in measured lengths, from `bottom` to the standard's foot
    /// (which carries the standard when the builder carries its own; escorted, it stands bare).
    private static func rod(_ f: inout Figure, x: CGFloat, from bottom: CGFloat) {
        let top = CGFloat(standardMountY) + 0.05
        let shaft = f.limb([(x, bottom), (x, top)], 0.022, 0.02)
        f.add(shaft, Material(cream.scaled(0.92), grain: .wood), outline: 0.011)
        var y = bottom + 0.07
        while y < top - 0.03 {
            f.decal(f.rectPath(x - 0.014, y, 0.028, 0.045), Tone(0.62, 0.2, 0.14), alpha: 0.95, clip: shaft)
            y += 0.09
        }
        f.add(f.ellipse(x, top - 0.005, 0.013, 0.013), Material(iron, gloss: 0.6), outline: 0.007)
    }

    /// A wheelbarrow pushed by the person whose feet are at `o`: its wheel at the front, the
    /// tray heaped with dressed stone, the near handle (the far one is drawn with the far arm).
    private static func wheelbarrow(_ f: inout Figure, at o: (CGFloat, CGFloat), k: CGFloat) {
        func p(_ x: CGFloat, _ y: CGFloat) -> (CGFloat, CGFloat) { (o.0 + x * k, o.1 + y * k) }
        // Legs and the near handle under the tray.
        f.add(f.limb([p(-0.2, 0.17), p(-0.19, 0.03)], 0.016 * k, 0.014 * k), Material(darkWood, grain: .wood), outline: 0.008)
        f.add(f.limb([p(-0.12, 0.27), p(-0.34, 0.16)], 0.022 * k, 0.02 * k), Material(wood.scaled(0.9), grain: .wood), outline: 0.009)
        // Tray: a deep wooden box, wider at the top.
        let tray = f.poly([p(-0.43, 0.25), p(-0.18, 0.25), p(-0.21, 0.14), p(-0.38, 0.13)])
        // Stone blocks heaped above the rim.
        let stone = Tone(0.66, 0.63, 0.58)
        for (x, y, w, h, t) in [(-0.41, 0.24, 0.08, 0.05, 0.95), (-0.33, 0.245, 0.09, 0.06, 1.05), (-0.25, 0.24, 0.07, 0.05, 0.9),
                                (-0.37, 0.28, 0.08, 0.05, 1.0), (-0.29, 0.29, 0.07, 0.045, 0.92)]
            as [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] {
            let a = p(x, y)
            f.add(f.rectPath(a.0, a.1, w * k, h * k), Material(stone.scaled(t), grain: .hide), outline: 0.009)
        }
        f.add(tray, Material(wood, grain: .planks))
        f.decal(f.poly([p(-0.43, 0.25), p(-0.18, 0.25), p(-0.185, 0.232), p(-0.425, 0.232)]), darkWood, alpha: 0.7)
        // The wheel at the front, iron-shod.
        f.wheel(p(-0.42, 0.07).0, p(-0.42, 0.07).1, 0.07 * k)
    }

    /// What a mounted body carries besides its rider (M2 §8.1): nothing (the scout), a lance
    /// (horseman), an iron helm and a caparison in the team color (knight), or a chariot.
    private enum Mount { case scout, lance, armored, chariot }

    /// A rider on a cantering horse, cloaked and hooded in the team color, carrying the standard.
    private static func scout(_ f: inout Figure, coat: Tone = Tone(0.6, 0.36, 0.2), kit: Mount = .scout) {
        let points = Tone(0.21, 0.14, 0.1), mane = Tone(0.18, 0.11, 0.07)
        let hoof = Tone(0.15, 0.11, 0.08), farCoat = coat.scaled(0.72)
        func hoofAt(_ x: CGFloat, _ y: CGFloat, _ k: CGFloat = 1, tilt: CGFloat = 0) {
            f.add(f.blob([(x - 0.023, y + tilt), (x + 0.02, y - tilt), (x + 0.016, y + 0.026 - tilt), (x - 0.016, y + 0.026 + tilt)]),
                  Material(hoof.scaled(k)), outline: 0.01)
        }

        // Far legs in shade: foreleg planted ahead, hind leg reaching under the belly.
        f.add(f.limb([(0.33, 0.39), (0.315, 0.27), (0.3, 0.22)], 0.07, 0.044), Material(farCoat, grain: .hide))
        f.add(f.limb([(0.3, 0.23), (0.29, 0.16), (0.284, 0.125)], 0.036, 0.03), Material(points.scaled(0.85)))
        hoofAt(0.28, 0.103, 0.85)
        f.add(f.limb([(0.64, 0.42), (0.6, 0.31), (0.585, 0.25)], 0.09, 0.05), Material(farCoat, grain: .hide))
        f.add(f.limb([(0.586, 0.26), (0.59, 0.18), (0.572, 0.128)], 0.036, 0.028), Material(points.scaled(0.85)))
        hoofAt(0.566, 0.105, 0.85)
        // Tail streaming back.
        f.add(f.limb([(0.752, 0.5), (0.81, 0.49), (0.852, 0.43), (0.87, 0.35), (0.896, 0.28)], 0.062, 0.022), Material(mane, grain: .hide))
        // Banner pole in the rider's far hand.
        pole(&f, x: 0.612, from: 0.43)
        // Barrel, deep chest, arched neck and the upper legs as one silhouette, so the legs
        // join the body without seams; only knees and hocks show as joints.
        let barrel = f.blob([(0.27, 0.44), (0.282, 0.375), (0.33, 0.33), (0.45, 0.322), (0.58, 0.33), (0.68, 0.36),
                             (0.752, 0.41), (0.765, 0.48), (0.73, 0.53), (0.64, 0.545), (0.54, 0.53), (0.44, 0.545),
                             (0.37, 0.56), (0.3, 0.52)])
        let neck = f.blob([(0.3, 0.44), (0.27, 0.5), (0.22, 0.58), (0.18, 0.66), (0.196, 0.722), (0.24, 0.73),
                           (0.3, 0.68), (0.37, 0.6), (0.42, 0.55), (0.36, 0.5)])
        let foreArm = f.limb([(0.33, 0.4), (0.28, 0.33), (0.252, 0.3)], 0.084, 0.05)
        let gaskin = f.limb([(0.7, 0.44), (0.74, 0.35), (0.77, 0.29)], 0.11, 0.054)
        let horse = barrel.union(neck).union(foreArm).union(gaskin)
        f.add(horse, Material(coat, grain: .hide))
        f.decal(f.blob([(0.34, 0.345), (0.46, 0.33), (0.62, 0.345), (0.55, 0.37), (0.4, 0.37)]), coat.lit, alpha: 0.2, clip: horse)
        f.decal(f.blob([(0.25, 0.56), (0.3, 0.52), (0.33, 0.54), (0.28, 0.6)]), coat.shadow, alpha: 0.22, clip: horse)
        // Head: a long wedge from the poll to a soft muzzle, with eye, nostril and ear.
        let head = f.blob([(0.205, 0.735), (0.17, 0.728), (0.124, 0.684), (0.082, 0.628), (0.064, 0.594), (0.074, 0.566),
                           (0.104, 0.562), (0.146, 0.588), (0.196, 0.63), (0.23, 0.68)])
        f.add(head, Material(coat, grain: .hide))
        f.add(f.ellipse(0.082, 0.582, 0.024, 0.022), Material(Tone(0.42, 0.27, 0.19)), outline: 0)
        f.add(f.ellipse(0.071, 0.586, 0.007, 0.006), Material(ink, shade: 0, light: 0), outline: 0)
        f.add(f.ellipse(0.162, 0.67, 0.012, 0.013), Material(ink, shade: 0, light: 0), outline: 0)
        f.decal(f.ellipse(0.159, 0.674, 0.004, 0.004), Tone(1, 0.95, 0.85), alpha: 0.9)
        f.add(f.blob([(0.2, 0.728), (0.205, 0.79), (0.23, 0.736)]), Material(coat), outline: 0.01)
        // Mane along the crest of the neck, forelock.
        f.add(f.limb([(0.21, 0.74), (0.27, 0.72), (0.33, 0.66), (0.38, 0.6), (0.43, 0.555)], 0.044, 0.022), Material(mane, grain: .hide),
              outline: 0.01)
        f.add(f.limb([(0.206, 0.736), (0.18, 0.716), (0.164, 0.69)], 0.022, 0.01), Material(mane), outline: 0.008)
        // Near legs: lead foreleg folded high, hind leg pushing off.
        f.add(f.limb([(0.252, 0.31), (0.262, 0.24), (0.282, 0.205)], 0.04, 0.03), Material(points))
        f.add(f.blob([(0.27, 0.19), (0.302, 0.196), (0.298, 0.222), (0.276, 0.216)]), Material(hoof), outline: 0.01)
        f.add(f.limb([(0.772, 0.3), (0.8, 0.2), (0.818, 0.13)], 0.04, 0.03), Material(points))
        hoofAt(0.822, 0.104)
        // Bridle and reins.
        f.decal(f.limb([(0.18, 0.71), (0.13, 0.63), (0.092, 0.586)], 0.009, 0.009), darkLeather, alpha: 0.9)
        // Saddle cloth in the team color, trimmed, and the saddle.
        let cloth = f.blob([(0.45, 0.555), (0.434, 0.46), (0.49, 0.42), (0.62, 0.43), (0.646, 0.5), (0.61, 0.555)])
        f.add(cloth, Material(team: 1, grain: .cloth))
        f.decalStroke(cloth, gold, width: 0.009, clip: cloth)
        f.add(f.blob([(0.466, 0.572), (0.486, 0.54), (0.584, 0.546), (0.604, 0.584), (0.546, 0.572)]), Material(darkLeather, gloss: 0.4),
              outline: 0.01)
        // Rider: cloak streaming back, torso leaning in, near leg, hooded head.
        f.add(f.blob([(0.52, 0.765), (0.61, 0.758), (0.69, 0.68), (0.744, 0.58), (0.684, 0.598), (0.62, 0.616), (0.552, 0.64)]),
              Material(team: 1, grain: .cloth))
        f.add(f.blob([(0.478, 0.572), (0.468, 0.64), (0.478, 0.718), (0.51, 0.758), (0.56, 0.742), (0.576, 0.664), (0.568, 0.574)]),
              Material(leather, grain: .hide))
        f.decal(f.rectPath(0.456, 0.594, 0.13, 0.022), darkLeather, alpha: 0.9)
        f.add(f.limb([(0.548, 0.59), (0.47, 0.54), (0.478, 0.455)], 0.054, 0.04), Material(Tone(0.42, 0.34, 0.24), grain: .cloth))
        f.add(f.blob([(0.45, 0.418), (0.51, 0.418), (0.506, 0.462), (0.468, 0.474)]), Material(darkLeather), outline: 0.01)
        f.add(f.limb([(0.506, 0.716), (0.446, 0.646), (0.392, 0.646)], 0.04, 0.03), Material(leather), outline: 0.012)
        f.add(f.ellipse(0.386, 0.646, 0.018, 0.018), Material(skin), outline: 0.008)
        f.decal(f.limb([(0.382, 0.644), (0.26, 0.648), (0.11, 0.584)], 0.006, 0.005), ink, alpha: 0.55)
        f.add(f.ellipse(0.494, 0.806, 0.043, 0.047), Material(skin))
        f.add(f.poly([(0.455, 0.814), (0.443, 0.796), (0.459, 0.792)]), Material(skin), outline: 0.006)
        f.add(f.ellipse(0.469, 0.814, 0.008, 0.009), Material(ink, shade: 0, light: 0), outline: 0)
        f.add(f.blob([(0.464, 0.83), (0.478, 0.866), (0.518, 0.882), (0.55, 0.858), (0.566, 0.818), (0.562, 0.758), (0.53, 0.778), (0.502, 0.822)]),
              Material(team: 0.84, grain: .cloth))
        switch kit {
        case .scout:
            break
        case .lance:
            let butt: (CGFloat, CGFloat) = (0.58, 0.6), tip: (CGFloat, CGFloat) = (0.1, 0.8)
            f.add(f.limb([butt, tip], 0.018, 0.015), Material(wood, grain: .wood), outline: 0.01)
            spearhead(&f, at: tip, angle: atan2(tip.1 - butt.1, tip.0 - butt.0), k: 1)
        case .armored:
            let caparison = f.blob([(0.3, 0.46), (0.42, 0.42), (0.66, 0.43), (0.76, 0.45), (0.75, 0.36), (0.6, 0.33), (0.34, 0.34)])
            f.add(caparison, Material(team: 1, grain: .cloth))
            f.decalStroke(caparison, gold, width: 0.008, clip: caparison)
            f.add(f.blob([(0.456, 0.79), (0.47, 0.87), (0.52, 0.895), (0.565, 0.86), (0.57, 0.79), (0.512, 0.77)]),
                  Material(iron, grain: .metal, gloss: 0.6))
            f.decal(f.rectPath(0.455, 0.815, 0.06, 0.01), ink, alpha: 0.8)
        case .chariot:
            f.add(f.poly([(0.64, 0.3), (0.93, 0.3), (0.91, 0.5), (0.67, 0.47)]), Material(team: 1, grain: .cloth))
            f.decal(f.poly([(0.64, 0.3), (0.93, 0.3), (0.93, 0.33), (0.64, 0.33)]), darkWood, alpha: 0.8)
            f.wheel(0.8, 0.2, 0.1)
        }
    }

    // MARK: Standards

    /// A broad banner hanging from a crossbar on its pole, ending in a short swallowtail, the
    /// emblem large on it; gilt finial and crossbar caps. Kept low (wide rather than tall, a
    /// small finial) so a standing unit stays below the hex centers of the row behind it,
    /// where taps select that row (`UnitTapTests`). The pole foot is at `standardFoot`.
    private static func standard(_ f: inout Figure) {
        let foot = standardArtFoot, top = standardArtTop, tips = standardArtTips
        let bar: CGFloat = top + 0.012, l: CGFloat = 0.21, r: CGFloat = 0.79, notch = tips + 0.12
        let k = f.fit  // outlines and strokes are not fitted with the shapes
        f.add(f.limb([(0.5, foot), (0.5, bar + 0.04)], 0.05, 0.044), Material(darkWood, grain: .wood), outline: 0.022 * k)
        let cloth = f.blob([(l, top), (0.5, top + 0.004), (r, top), (r + 0.006, tips + 0.2), (r, tips), (0.5, notch), (l, tips),
                            (l - 0.006, tips + 0.2)])
        let squared = cloth.intersection(f.rectPath(l - 0.02, tips - 0.02, r - l + 0.04, top - tips + 0.05))
        f.add(squared, Material(team: 1, grain: .cloth), outline: 0.026 * k)
        f.decalStroke(squared, teamShade: 0.62, width: 0.05 * k, clip: squared)
        // Soft vertical folds, clear of the emblem.
        for (x, a) in [(0.27, 0.3), (0.73, 0.24)] as [(CGFloat, CGFloat)] {
            f.decal(f.limb([(x, top - 0.02), (x + 0.008, tips + 0.08)], 0.04, 0.055), teamShade: 0.7, alpha: a, clip: squared)
        }
        f.emblem(center: (0.5, top - 0.05 - standardArtEmblem / 2), size: standardArtEmblem)
        f.add(f.limb([(l - 0.025, bar), (r + 0.025, bar)], 0.034, 0.034), Material(wood, grain: .wood), outline: 0.02 * k)
        for x in [l - 0.025, r + 0.025] {
            f.add(f.ellipse(x, bar, 0.024, 0.024), Material(gold, grain: .metal, gloss: 0.8), outline: 0.016 * k)
        }
        f.add(f.blob([(0.472, bar + 0.04), (0.5, bar + 0.1), (0.528, bar + 0.04), (0.5, bar + 0.026)]), Material(gold, gloss: 1),
              outline: 0.016 * k)
    }

    /// The standard as recorded for its cell (`standardArtFit`).
    private static func standardFigure(size: CGFloat) -> Figure {
        let pivot = standardArtPivot
        var f = Figure(size: size, fit: CGFloat(standardArtFit), pivot: (CGFloat(pivot.x), CGFloat(pivot.y)))
        standard(&f)
        return f
    }

    // MARK: Badges

    /// A unit type's pictogram on a cream disc in a dark rim: the field of its strategic
    /// medallion (`badgeField` of the cell around the middle), and whole, the badge an escort's
    /// medallion wears for its civilian.
    private static func badge(_ type: UnitType, _ f: inout Figure) {
        let r = CGFloat(badgeDisc) / 2
        f.add(f.ellipse(0.5, 0.5, r, r), Material(rimBrown, gloss: 0.2), outline: 0.03)
        f.add(f.ellipse(0.5, 0.5, r - 0.075, r - 0.075), Material(cream, shade: 0.5), outline: 0)
        f.glyph(type, center: (0.5, 0.5), size: 0.5)
    }

    // MARK: Job badges

    /// A Builder job's glyph on a cream disc in a dark rim, drawn like a unit type's badge: a
    /// sheaf of wheat (farm), a pick (mine) or a paw print (pasture), each a silhouette that
    /// stays clear on a badge 12 points across.
    private static func jobBadge(_ kind: Improvement, _ f: inout Figure) {
        let r = CGFloat(badgeDisc) / 2
        f.add(f.ellipse(0.5, 0.5, r, r), Material(rimBrown, gloss: 0.2), outline: 0.03)
        f.add(f.ellipse(0.5, 0.5, r - 0.075, r - 0.075), Material(cream, shade: 0.5), outline: 0)
        let c = f.pt((0.5, 0.5)), h = f.size * 0.25
        func q(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x + x * h, y: c.y + y * h) }
        /// A thick polyline with round ends, as a filled shape.
        func line(_ points: [CGPoint], width: CGFloat) -> CGPath {
            let path = CGMutablePath()
            path.addLines(between: points)
            return path.copy(strokingWithWidth: width * h, lineCap: .round, lineJoin: .round, miterLimit: 4)
        }
        /// An ellipse with radii `rx`, `ry` about (x, y), its `ry` axis turned `angle` radians
        /// from straight up (counterclockwise).
        func oval(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat, angle: CGFloat) -> CGPath {
            var t = CGAffineTransform(translationX: q(x, y).x, y: q(x, y).y).rotated(by: angle)
            return CGPath(ellipseIn: CGRect(x: -rx * h, y: -ry * h, width: 2 * rx * h, height: 2 * ry * h), transform: &t)
        }
        var shapes: [CGPath] = []
        switch kind {
        case .farm:
            // Stalks gathered at a band, fanning out below and up to four ears.
            for x in [-0.42, 0, 0.42] as [CGFloat] { shapes.append(line([q(x * 0.25, -0.12), q(x, -0.92)], width: 0.1)) }
            for (top, bottom) in [((-0.5, 0.4), -0.1), ((-0.18, 0.54), -0.04), ((0.18, 0.54), 0.04), ((0.5, 0.4), 0.1)] as [((CGFloat, CGFloat), CGFloat)] {
                shapes.append(line([q(bottom, -0.12), q(top.0, top.1)], width: 0.09))
                let dx = top.0 - bottom, dy = top.1 + 0.12, l = (dx * dx + dy * dy).squareRoot()
                shapes.append(oval(top.0 + dx / l * 0.2, top.1 + dy / l * 0.2, 0.12, 0.25, angle: -atan2(dx, dy)))
            }
            shapes.append(CGPath(roundedRect: CGRect(x: q(-0.32, 0).x, y: q(0, -0.23).y, width: 0.64 * h, height: 0.2 * h),
                                 cornerWidth: 0.08 * h, cornerHeight: 0.08 * h, transform: nil))
        case .mine:
            // A pick: the handle up to the right, a broad curved head across its top.
            shapes.append(line([q(-0.74, -0.74), q(0.42, 0.42)], width: 0.2))
            let head = CGMutablePath()
            head.move(to: q(-0.32, 0.88))
            head.addQuadCurve(to: q(0.88, -0.32), control: q(0.94, 0.94))
            head.addQuadCurve(to: q(-0.32, 0.88), control: q(0.42, 0.42))
            head.closeSubpath()
            shapes.append(head)
        case .pasture:
            // A paw print: a broad pad below four toes.
            shapes.append(oval(0, -0.4, 0.5, 0.38, angle: 0))
            for (x, y, angle) in [(-0.7, 0.12, 0.42), (-0.26, 0.52, 0.12), (0.26, 0.52, -0.12), (0.7, 0.12, -0.42)] as [(CGFloat, CGFloat, CGFloat)] {
                shapes.append(oval(x, y, 0.19, 0.26, angle: angle))
            }
        }
        f.glyph(shapes: shapes, halo: h * 0.14)
    }

    // MARK: Tribal villages

    /// Ivory: a tribal village token's field, paler and cooler than the badges' cream, and no
    /// player's colour.
    fileprivate static let ivory = Tone(0.99, 0.97, 0.9)

    /// A tribal village's strategic token: a round hut (a conical thatch over a low round wall
    /// with a dark doorway) with a wisp of smoke rising beside its peak, in ink on an ivory disc
    /// in a dark rim, drawn like a badge so it stays clear 13 points across.
    private static func tribalVillageBadge(_ f: inout Figure) {
        let r = CGFloat(badgeDisc) / 2
        f.add(f.ellipse(0.5, 0.5, r, r), Material(rimBrown, gloss: 0.2), outline: 0.03)
        f.add(f.ellipse(0.5, 0.5, r - 0.07, r - 0.07), Material(ivory, shade: 0.45), outline: 0)
        let c = f.pt((0.5, 0.47)), h = f.size * 0.25
        func q(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x + x * h, y: c.y + y * h) }
        var shapes: [CGPath] = []
        // The thatch: a tall cone with hollow flanks, its eave curving round the hut and
        // overhanging the wall.
        let cone = CGMutablePath()
        cone.move(to: q(-0.94, -0.1))
        cone.addQuadCurve(to: q(-0.05, 0.84), control: q(-0.42, 0.26))
        cone.addLine(to: q(0.05, 0.84))
        cone.addQuadCurve(to: q(0.94, -0.1), control: q(0.42, 0.26))
        cone.addQuadCurve(to: q(-0.94, -0.1), control: q(0, -0.4))
        cone.closeSubpath()
        shapes.append(cone)
        // The low round wall under it, its foot curving with the hut, round an open doorway.
        let wall = CGMutablePath()
        wall.move(to: q(-0.6, -0.2))
        wall.addLine(to: q(-0.6, -0.6))
        wall.addQuadCurve(to: q(-0.19, -0.78), control: q(-0.42, -0.76))
        wall.addLine(to: q(-0.19, -0.42))
        wall.addQuadCurve(to: q(0.17, -0.42), control: q(-0.01, -0.24))
        wall.addLine(to: q(0.17, -0.78))
        wall.addQuadCurve(to: q(0.6, -0.6), control: q(0.42, -0.76))
        wall.addLine(to: q(0.6, -0.2))
        wall.closeSubpath()
        shapes.append(wall)
        // A wisp of smoke from the fire beside the hut, curling up past the peak.
        let wisp = CGMutablePath()
        wisp.move(to: q(0.62, 0.3))
        wisp.addCurve(to: q(0.66, 0.92), control1: q(0.98, 0.5), control2: q(0.38, 0.7))
        wisp.addCurve(to: q(0.74, 1.24), control1: q(0.86, 1.04), control2: q(0.9, 1.14))
        shapes.append(wisp.copy(strokingWithWidth: 0.15 * h, lineCap: .round, lineJoin: .round, miterLimit: 4))
        f.glyph(shapes: shapes, halo: h * 0.14)
    }

    // MARK: Turn markers

    /// Map-pin medallion: dark enamel in a cream rim, or (final step) a cream face in a dark
    /// rim; numerals are separate `digit` instances.
    private static func marker(_ f: inout Figure, final: Bool) {
        let cx: CGFloat = 0.5, cy = CGFloat(markerFace), rad: CGFloat = 0.32
        let disc = f.ellipse(cx, cy, rad, rad)
        let shape = disc.union(f.poly([(cx - 0.14, cy - rad + 0.07), (cx, CGFloat(markerPin)), (cx + 0.14, cy - rad + 0.07)]))
        f.add(shape, Material(final ? rimBrown : cream, gloss: final ? 0.3 : 0.5), outline: 0.035)
        f.add(f.ellipse(cx, cy, rad - 0.055, rad - 0.055), Material(final ? cream : Tone(0.24, 0.17, 0.12), shade: 0.5), outline: 0)
    }

    // CTFont is immutable and documented thread-safe; creating the system font per digit
    // costs about a millisecond each.
    nonisolated(unsafe) private static let digitFont: CTFont = CTFontCreateUIFontForLanguage(.emphasizedSystem, 80, nil)
        ?? CTFontCreateWithName("Helvetica-Bold" as CFString, 80, nil)

    /// White numeral, tinted per instance.
    private static func digit(_ d: Int, cell: CGRect, ctx: CGContext) {
        let font = CTFontCreateCopyWithAttributes(digitFont, cell.height * 0.62, nil, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "\(d)", attributes: attributes))
        ctx.textPosition = .zero // image bounds are measured relative to the current text position
        let bounds = CTLineGetImageBounds(line, ctx)
        ctx.textPosition = CGPoint(x: cell.midX - bounds.width / 2 - bounds.minX, y: cell.midY - bounds.height / 2 - bounds.minY)
        CTLineDraw(line, ctx)
    }
}

// MARK: - Pre-rendering

/// The atlas draws its cells one at a time into one context, and unit art is costly enough to
/// matter at startup. So the first unit cell drawn into a context renders all of them (but the
/// numerals) in parallel, and every cell then just copies its image. Batches are keyed by the
/// atlas context, so concurrent atlas builds never share one; each is gone once its last cell
/// is drawn.
private enum Prerendered {
    private static let batches = Mutex<[ObjectIdentifier: [UnitSprite: CGImage]]>([:])

    static func take(_ key: UnitSprite, for ctx: CGContext) -> CGImage? {
        let id = ObjectIdentifier(ctx)
        let found: CGImage?? = batches.withLock { batches in
            guard var batch = batches[id] else { return nil }
            let image = batch.removeValue(forKey: key)
            batches[id] = batch.isEmpty ? nil : batch
            return .some(image)
        }
        if let found { return found }
        var batch = renderAll()
        let image = batch.removeValue(forKey: key)
        if !batch.isEmpty { batches.withLock { $0[id] = batch } }
        return image
    }

    private static func renderAll() -> [UnitSprite: CGImage] {
        UnitSprite.prepareRecordings()
        let keys = UnitSprite.all.filter { if case .digit = $0 { false } else { true } }
        let images = Mutex<[UnitSprite: CGImage]>([:])
        DispatchQueue.concurrentPerform(iterations: keys.count) { i in
            let key = keys[i]
            guard let ctx = UnitSprite.bitmap(key.cellSize) else { return }
            key.paint(cell: CGRect(x: 0, y: 0, width: key.cellSize, height: key.cellSize), ctx: ctx)
            if let image = ctx.makeImage() { images.withLock { $0[key] = image } }
        }
        return images.withLock { $0 }
    }
}

extension UnitSprite {
    /// A transparent square sRGB bitmap, as the atlas uses.
    fileprivate static func bitmap(_ size: Int) -> CGContext? {
        CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Paints the data cell of the figure the steps record (`teamMask`, `escortedMask`,
    /// `standardField`): red is how much of each pixel is team paint (when `team`), green how
    /// near the painted silhouette it is, 1 - `rimField` / `rimRange` (so it fades to nothing
    /// far out), blue and alpha zero. Its outermost texels stay empty, so filtering at a
    /// neighbor's edge picks up nothing. The values are written into the context's memory as
    /// they are: compositing would drop color where alpha is zero.
    fileprivate static func paintData(_ steps: [Step], team: Bool, cell: CGRect, ctx: CGContext, high: [Step]? = nil) {
        let n = Int(cell.width.rounded())
        guard var pixels = dataPixels(steps, team: team, size: n) else { return }
        if let high, let more = dataPixels(high, team: team, size: n) {
            for i in 0..<(n * n) {
                pixels[4 * i + 2] = more[4 * i]
                pixels[4 * i + 3] = more[4 * i + 1]
            }
        }
        write(Data(pixels), rowBytes: n * 4, size: n, into: ctx, at: cell)
    }

    /// A data cell's pixels (red: team paint, green: nearness to the silhouette).
    private static func dataPixels(_ steps: [Step], team: Bool, size n: Int) -> [UInt8]? {
        guard let shape = bitmap(n) else { return nil }
        Canvas(ctx: shape, origin: .zero, size: CGFloat(n)).silhouette(steps)
        let field = rimField(alpha(of: shape, size: n), size: n)
        var teamCover = [UInt8](repeating: 0, count: n * n)
        if team, let mask = bitmap(n) {
            Canvas(ctx: mask, origin: .zero, size: CGFloat(n)).paint(steps, pass: .teamMask)
            teamCover = alpha(of: mask, size: n)
        }
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        let border = dataBorder
        for y in border..<(n - border) {
            for x in border..<(n - border) {
                let i = y * n + x
                pixels[4 * i] = teamCover[i]
                pixels[4 * i + 1] = UInt8((255 * max(1 - field[i] / rimRange, 0)).rounded())
            }
        }
        return pixels
    }

    /// Texels left empty around a data cell's edge.
    static let dataBorder = 4

    /// Copies a square cell's pixels (top row first) into a bitmap context's memory at `cell`
    /// (context coordinates, y up), bypassing compositing.
    private static func write(_ bytes: Data, rowBytes: Int, size n: Int, into ctx: CGContext, at cell: CGRect) {
        guard let data = ctx.data else { return }
        let x0 = Int(cell.minX.rounded()), top = ctx.height - Int(cell.maxY.rounded())
        guard x0 >= 0, top >= 0, x0 + n <= ctx.width, top + n <= ctx.height else { return }
        let target = data.assumingMemoryBound(to: UInt8.self)
        bytes.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            guard let from = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for row in 0..<n {
                (target + (top + row) * ctx.bytesPerRow + x0 * 4).update(from: from + row * rowBytes, count: n * 4)
            }
        }
    }

    /// The alpha channel of a square bitmap from `bitmap`, top row first.
    private static func alpha(of ctx: CGContext, size n: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: n * n)
        guard let data = ctx.data else { return out }
        let bytes = data.assumingMemoryBound(to: UInt8.self), row = ctx.bytesPerRow
        out.withUnsafeMutableBufferPointer { out in
            for y in 0..<n {
                for x in 0..<n { out[y * n + x] = bytes[y * row + x * 4 + 3] }
            }
        }
        return out
    }

    /// For each texel of an n x n coverage map (0...255, row-major), the distance in texels
    /// from its center out to the silhouette's edge, 0 inside (coverage of half or more). An
    /// exact Euclidean distance transform (Felzenszwalb and Huttenlocher: one pass down the
    /// columns, one along the rows) gives the distance to the nearest covered texel center;
    /// the edge lies about half a texel short of that, and partly covered texels on it say
    /// where.
    static func rimField(_ cover: [UInt8], size n: Int) -> [Float] {
        let far = 1e10
        var grid = cover.map { $0 >= 128 ? 0 : far }
        var f = [Double](repeating: 0, count: n), out = [Double](repeating: 0, count: n)
        var v = [Int](repeating: 0, count: n), z = [Double](repeating: 0, count: n + 1)
        grid.withUnsafeMutableBufferPointer { grid in
            f.withUnsafeMutableBufferPointer { f in
                out.withUnsafeMutableBufferPointer { out in
                    v.withUnsafeMutableBufferPointer { v in
                        z.withUnsafeMutableBufferPointer { z in
                            // One line of squared distances: out[q] = min over p of (q - p)^2 + f[p].
                            func line(start: Int, stride: Int) {
                                for q in 0..<n { f[q] = grid[start + q * stride] }
                                var k = 0
                                v[0] = 0
                                z[0] = -.infinity
                                z[1] = .infinity
                                func meet(_ q: Int, _ p: Int) -> Double {
                                    ((f[q] + Double(q * q)) - (f[p] + Double(p * p))) / Double(2 * (q - p))
                                }
                                for q in 1..<n {
                                    var s = meet(q, v[k])
                                    while s <= z[k] {
                                        k -= 1
                                        s = meet(q, v[k])
                                    }
                                    k += 1
                                    v[k] = q
                                    z[k] = s
                                    z[k + 1] = .infinity
                                }
                                k = 0
                                for q in 0..<n {
                                    while z[k + 1] < Double(q) { k += 1 }
                                    let d = Double(q - v[k])
                                    out[q] = d * d + f[v[k]]
                                }
                                for q in 0..<n { grid[start + q * stride] = out[q] }
                            }
                            for x in 0..<n { line(start: x, stride: n) }
                            for y in 0..<n { line(start: y * n, stride: 1) }
                        }
                    }
                }
            }
        }
        var field = [Float](repeating: 0, count: n * n)
        for i in 0..<(n * n) where cover[i] < 128 {
            let c = Float(cover[i]) / 255
            var d = Float(grid[i].squareRoot()) - 0.5
            if c > 0 { d = min(d, 0.5 - c) }
            field[i] = max(d, 0)
        }
        return field
    }
}

/// A body's recorded paint steps and the emblem spots it exports. Immutable, so cells can be
/// painted from it concurrently.
private final class RecordedFigure: @unchecked Sendable {
    let steps: [Step]
    let emblems: [SIMD4<Float>]
    /// What the steps paint (`UnitSprite.bounds`).
    let bounds: SIMD4<Float>

    init(steps: [Step], emblems: [SIMD4<Float>], size: CGFloat) {
        self.steps = steps
        self.emblems = emblems
        bounds = steps.bounds(size: size)
    }
}
