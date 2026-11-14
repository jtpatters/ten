import GameCore
import MapRendering
import QuartzCore
import UIKit

/// The text over the map (M1 §15, §16): city banners and damage numbers, as Core Animation
/// layers in a view laid over the Metal map. `frameDidDraw()` runs in the renderer's `onFrame`
/// and pins every layer to the world for the frame just drawn; while anything shows, the
/// renderer presents with the Core Animation transaction (`presentsWithTransaction`), so the
/// layers and the map move as one.
///
/// Banners are drawn once per change (`BannerArt`) and only moved per frame. Overlaps resolve
/// by rank (`CityBannerModel.ranked`): the selected city, own cities, capitals, the largest;
/// a banner that would overlap one placed before it hides (foreign banners first, as M1 §16
/// asks), and it needs a little extra room to come back, so banners do not flicker at the
/// edge. At strategic zoom the banners are compact tags, and an overlapped one first tries one
/// tag height above, then below (keeping the place it has while that stays free). A banner that would reach under the top bar moves down to just below it while its
/// city shows below the bar (else it hides: it never shows in the gaps between the bar's
/// chips). A city's name always stays fully readable: only a banner's secondary rows (growth
/// and production) fade, while a unit figure next to the city stands under them, so the unit
/// shows through (not for the viewer's own units at rest, asleep or fortified); a damaged
/// city's HP bar never fades. A banner over a focus tile (`focusHexes`: the selected unit, a
/// previewed route or attack, the tile of an open card) collapses to its pill (the strategic
/// tag, with a damaged city's HP), leaving the unit and its route in sight. Taps on the name
/// row select the city; elsewhere on the banner, taps on a unit or a focus tile under it go to
/// the map. The view takes no touches: the map's tap handler asks `bannerCity(at:)` first.
@MainActor
final class MapOverlay: UIView {
    weak var renderer: MapRenderer?
    /// Builds the banners when they are stale (`invalidateBanners()`), so several state
    /// changes within a frame build them once.
    var bannerSource: (() -> [CityBannerModel])?
    /// VoiceOver activated a banner.
    var onActivateBanner: ((CityID) -> Void)?
    /// Reduce Motion: damage numbers fade in place.
    var reduceMotion = false
    /// Stretches damage numbers in time (debug slow motion, with the renderer's
    /// `animationSpeed`).
    var timeScale: Double = 1
    /// The height the top bar covers: banners reaching under it move down below it (or hide),
    /// so they never show in the gaps between its chips.
    var coveredTop: CGFloat = 0
    /// Tiles the player is working with (set by the session when the selection or a preview
    /// changes): taps on one under a banner (off its name row) go to the map.
    var focusHexes: [HexCoord] = []

    /// Banners shown in the last frame.
    private(set) var shownBanners = 0
    /// Time spent placing layers per frame (ms, smoothed): the developer readout.
    private(set) var layoutMilliseconds: Double = 0

    /// Marks pinned to tiles under the banners: own built quarters (a glyph each) and, while
    /// a quarter is placed, its legal sites' adjacency (M2 §18.2).
    struct QuarterMark: Equatable {
        var hex: HexCoord
        var symbol: String
        var pillaged: Bool
    }

    struct SiteLabel: Equatable {
        var hex: HexCoord
        var text: String
    }

    var quarterMarks: [QuarterMark] = [] {
        didSet { if quarterMarks != oldValue { rebuildMarks() } }
    }

    var siteLabels: [SiteLabel] = [] {
        didSet { if siteLabels != oldValue { rebuildMarks() } }
    }

    /// Raider camps the viewer remembers (M2 §11): a tent glyph on a crimson-rimmed disc.
    var campMarks: [HexCoord] = [] {
        didSet { if campMarks != oldValue { rebuildMarks() } }
    }

    /// The trade routes the viewer can see (M2 §13), as tile paths: faint dashed lines.
    var tradeRoutes: [[HexCoord]] = [] {
        didSet { if tradeRoutes.isEmpty { routeLayer.path = nil } }
    }

    private let routeLayer = CAShapeLayer()

    private let markLayer = CALayer()
    private var marks: [(layer: CALayer, hex: HexCoord)] = []
    private let bannerLayer = CALayer()
    private let floaterLayer = CALayer()
    private var slots: [CityID: Slot] = [:]
    /// Cities by rank, most important first.
    private var order: [CityID] = []
    /// The tiles near the cities with banners (within 2, the cities' own tiles left out),
    /// where a unit may stand under a banner.
    private var nearBanners: Set<HexCoord> = []
    private var bannersStale = true
    /// The banners shown in the last frame with the rectangles their art covers, by rank: the
    /// name row (`head`, always the city's), and off it `holes` that let taps through to the
    /// map (unit figures and focus tiles under the banner); `focused` ones lie over a focus
    /// tile, `pill` ones collapsed there to their pill; `faded` ones have their secondary rows
    /// faded over a unit figure.
    private var hits: [(city: CityID, rect: CGRect, head: CGRect, focused: Bool, pill: Bool, faded: Bool, holes: [CGRect])] = []
    private var floaters: [Floater] = []
    private var elements: [CityID: BannerElement] = [:]

    /// Points between a city's banner anchor and the bottom of its banner.
    static let bannerGap: CGFloat = 3
    /// Extra room a hidden banner needs before it shows again.
    static let hysteresis: CGFloat = 6
    /// Banner images drawn per frame when the content switches (zooming to strategic tokens).
    static let rendersPerFrame = 6
    static let maxFloaters = 12
    /// Where damage numbers start: about the top of a figure (as `onEventShown` reports).
    static let floaterLift: Float = 0.9
    /// The opacity of a banner's secondary rows over a unit next to its city (the name row
    /// never fades).
    nonisolated static let fadedOpacity: Float = 0.35
    /// Points between the top bar and a banner moved down below it.
    static let belowBar: CGFloat = 2

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        routeLayer.fillColor = nil
        routeLayer.strokeColor = HUD.UI.gilt.withAlphaComponent(0.55).cgColor
        routeLayer.lineWidth = 2
        routeLayer.lineDashPattern = [6, 4]
        routeLayer.lineCap = .round
        routeLayer.lineJoin = .round
        layer.addSublayer(routeLayer)
        layer.addSublayer(markLayer)
        layer.addSublayer(bannerLayer)
        layer.addSublayer(floaterLayer)
        accessibilityLabel = "City banners"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        markLayer.frame = bounds
        bannerLayer.frame = bounds
        floaterLayer.frame = bounds
        CATransaction.commit()
    }

    private var scale: CGFloat {
        let s = traitCollection.displayScale
        return s > 0 ? s : 3
    }

    // MARK: Banners

    /// The banners need rebuilding (state, selection or fog changed); done at the next frame.
    func invalidateBanners() {
        bannersStale = true
    }

    /// The city whose banner is at a view point (the top-most), with a 44 pt tall target: its
    /// name row always; off it, a tap on a unit or a focus tile under the banner goes through
    /// to the map.
    func bannerCity(at point: CGPoint) -> CityID? {
        for hit in hits where Self.touchRect(hit.rect).contains(point) {
            if hit.head.contains(point) { return hit.city }
            return hit.holes.contains(where: { $0.contains(point) }) ? nil : hit.city
        }
        return nil
    }

    /// The banners over focus tiles in the last frame (taps there go to the map): automation.
    var focusedBannerCities: [CityID] { hits.filter(\.focused).map(\.city) }

    /// The banners whose secondary rows were faded over a unit in the last frame: automation.
    var fadedBannerCities: [CityID] { hits.filter(\.faded).map(\.city) }

    /// The banners collapsed to their pill over a focus tile in the last frame: automation.
    var pillBannerCities: [CityID] { hits.filter(\.pill).map(\.city) }

    /// Where a city's banner shows (view points), if it shows.
    func bannerRect(of city: CityID) -> CGRect? {
        hits.first { $0.city == city }?.rect
    }

    /// The banners shown, by rank: automation and tests.
    var shownBannerCities: [CityID] { hits.map(\.city) }

    /// How far a shown banner was moved from its place to stay clear (strategic zoom): up is
    /// negative. Automation.
    func bannerShift(of city: CityID) -> CGFloat {
        hits.contains { $0.city == city } ? slots[city]?.shift ?? 0 : 0
    }

    static func touchRect(_ rect: CGRect) -> CGRect {
        let grow = max(0, (HUD.touch - rect.height) / 2)
        return rect.insetBy(dx: -4, dy: -grow)
    }

    private func setBanners(_ models: [CityBannerModel]) {
        var seen = Set<CityID>()
        for model in models {
            seen.insert(model.id)
            if let slot = slots[model.id] {
                if slot.model != model {
                    slot.model = model
                    slot.art.removeAll()
                }
            } else {
                let slot = Slot(model: model)
                slot.layer.contentsScale = scale
                slot.details.contentsScale = scale
                slot.layer.anchorPoint = .zero
                slot.layer.opacity = 0
                bannerLayer.addSublayer(slot.layer)
                slots[model.id] = slot
            }
        }
        for (id, slot) in slots where !seen.contains(id) {
            slot.layer.removeFromSuperlayer()
            slots[id] = nil
            elements[id] = nil
        }
        order = models.sorted(by: CityBannerModel.ranked).map(\.id)
        if let map = renderer?.state.map {
            let cities = Set(models.map(\.hex))
            nearBanners = Set(models.flatMap { map.coords(within: 2, of: $0.hex) }).subtracting(cities)
        } else {
            nearBanners = []
        }
    }

    /// Places everything for the frame the renderer just drew.
    func frameDidDraw() {
        guard let renderer else { return }
        let start = CACurrentMediaTime()
        if bannersStale, let source = bannerSource {
            bannersStale = false
            setBanners(source())
        }
        let strategic = renderer.showsStrategicTokens
        let screen = bounds.insetBy(dx: -24, dy: -24)
        let pixel = 1 / scale
        func snap(_ v: CGFloat) -> CGFloat { (v / pixel).rounded() * pixel }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeMarks(renderer, screen: screen, snap: snap)
        placeRoutes(renderer)
        var placed: [CGRect] = []
        var renders = 0
        let focus = focusRects(renderer)
        let figures = figureRects(renderer, strategic: strategic)
        hits.removeAll(keepingCapacity: true)
        for (rank, id) in order.enumerated() {
            guard let slot = slots[id] else { continue }
            guard var art = self.art(of: slot, strategic ? .strategic : .standard, renders: &renders) ?? slot.art.values.first,
                  let anchor = renderer.bannerAnchor(city: id.rawValue),
                  var (origin, content) = hang(art, at: anchor, city: slot.model.hex, renderer: renderer, screen: screen, snap: snap) else {
                slot.setVisible(false)
                continue
            }
            // Over a focus tile, the banner collapses to its pill.
            var pill = false
            if !strategic, focus.contains(where: { $0.intersects(content) }), let small = self.art(of: slot, .pill, renders: &renders),
               let hung = hang(small, at: anchor, city: slot.model.hex, renderer: renderer, screen: screen, snap: snap) {
                art = small
                (origin, content) = hung
                pill = true
            }
            guard let dy = Self.freePlace(for: content, slot: slot, strategic: strategic || pill, placed: placed,
                                          above: coveredTop + Self.belowBar) else {
                slot.setVisible(false)
                continue
            }
            slot.shift = dy
            origin.y += dy
            content = content.offsetBy(dx: 0, dy: dy)
            placed.append(content)
            if slot.shown !== art.image {
                slot.shown = art.image
                slot.layer.contents = art.image
                slot.layer.bounds = CGRect(origin: .zero, size: art.size)
                slot.details.contents = art.details
                slot.details.frame = CGRect(origin: .zero, size: art.size)
            }
            slot.layer.position = origin
            slot.layer.zPosition = CGFloat(order.count - rank)
            // Taps reach a little round a small banner (`touchRect`): so do its holes.
            let reach = Self.touchRect(content)
            let focused = focus.filter { $0.intersects(reach) }
            let units = figures.filter { $0.rect.intersects(reach) }
            let rows = art.detailsRect.offsetBy(dx: origin.x, dy: origin.y)
            // The viewer's own units at rest (asleep, fortified) leave the rows as they are.
            let faded = art.details != nil && units.contains { !$0.rests && $0.rect.intersects(rows) }
            slot.setVisible(true)
            slot.setDetailsFaded(faded)
            hits.append((id, content, art.head.offsetBy(dx: origin.x, dy: origin.y),
                         pill || focused.contains { $0.intersects(content) }, pill, faded, units.map(\.rect) + focused))
        }
        shownBanners = hits.count
        placeFloaters(renderer, snap: snap)
        CATransaction.commit()

        renderer.presentsWithTransaction = !hits.isEmpty || !floaters.isEmpty || !tradeRoutes.isEmpty
        layoutMilliseconds = layoutMilliseconds * 0.9 + (CACurrentMediaTime() - start) * 100
    }

    /// A banner's art in a style, drawn now unless this frame has drawn its share already (then
    /// nil, unless it was drawn before).
    private func art(of slot: Slot, _ style: BannerArt.Style, renders: inout Int) -> BannerArt.Rendered? {
        if slot.art[style] == nil, slot.art.isEmpty || renders < Self.rendersPerFrame {
            slot.art[style] = BannerArt.render(slot.model, style: style, scale: scale)
            renders += 1
        }
        return slot.art[style]
    }

    /// Where a banner's art hangs from its city's anchor this frame, as an origin and the
    /// rectangle its art covers: reaching under the top bar, it moves down to just below it
    /// while its city shows below the bar; nil when it then hides, or is off screen.
    private func hang(_ art: BannerArt.Rendered, at anchor: CGPoint, city hex: HexCoord, renderer: MapRenderer, screen: CGRect,
                      snap: (CGFloat) -> CGFloat) -> (origin: CGPoint, content: CGRect)? {
        var origin = CGPoint(x: snap(anchor.x - art.anchor.x), y: snap(anchor.y - Self.bannerGap - art.anchor.y))
        var content = art.content.offsetBy(dx: origin.x, dy: origin.y)
        if content.minY < coveredTop + Self.belowBar {
            guard let city = renderer.screenPoint(of: hex), city.y > coveredTop, screen.contains(city) else { return nil }
            let dy = snap(coveredTop + Self.belowBar - content.minY)
            origin.y += dy
            content = content.offsetBy(dx: 0, dy: dy)
        }
        return content.intersects(screen) ? (origin, content) : nil
    }

    /// Where a banner goes clear of those placed before it, as an offset from its place (nil:
    /// nowhere, it hides). Its place first (as shown, or with `hysteresis` to spare to come
    /// back); at strategic zoom then one tag height (and a gap) above, then below, never under
    /// the top bar (`above`), the offset it has kept while that stays free.
    private static func freePlace(for content: CGRect, slot: Slot, strategic: Bool, placed: [CGRect], above: CGFloat) -> CGFloat? {
        let step = content.height + strategicGap
        var tries: [(dy: CGFloat, margin: Bool)] = []
        if slot.visible, strategic, slot.shift != 0 {
            tries = [(0, true), (slot.shift, false)]
        } else {
            tries = [(0, !slot.visible)]
        }
        if strategic {
            for dy in [-step, step] where !tries.contains(where: { $0.dy == dy }) { tries.append((dy, true)) }
        }
        for (dy, margin) in tries {
            let rect = content.offsetBy(dx: 0, dy: dy)
            if dy != 0, rect.minY < above { continue }
            // A moved tag sits `strategicGap` from its own row, closer than `hysteresis`: up and
            // down, its margin is half that gap.
            let test = margin ? rect.insetBy(dx: -hysteresis, dy: dy == 0 ? -hysteresis : -strategicGap / 2) : rect
            if !placed.contains(where: { $0.intersects(test) }) { return dy }
        }
        return nil
    }

    /// Points between a strategic tag moved out of the way and the place it left.
    static let strategicGap: CGFloat = 2

    /// The focus tiles on screen: round each tile's centre, a box most of a tile wide that
    /// reaches up over the figures standing on it.
    private func focusRects(_ renderer: MapRenderer) -> [CGRect] {
        guard let first = focusHexes.first, let w = tileWidth(renderer, at: first) else { return [] }
        return renderer.screenPoints(of: focusHexes, lift: 0).compactMap { point in
            point.map { CGRect(x: $0.x - w * 0.35, y: $0.y - w * 0.75, width: w * 0.7, height: w * 0.95) }
        }
    }

    /// A tile's width on screen near `hex`, from a neighbour (west when east is off the map's
    /// edge).
    private func tileWidth(_ renderer: MapRenderer, at hex: HexCoord) -> CGFloat? {
        guard let a = renderer.screenPoint(of: hex),
              let b = renderer.screenPoint(of: hex.neighbor(.east)) ?? renderer.screenPoint(of: hex.neighbor(.west))
        else { return nil }
        return hypot(b.x - a.x, b.y - a.y)
    }

    /// The units drawn near cities with banners (the cities' own tiles left out: there the
    /// banner names the city), where they are drawn: a box round each figure, from its feet to
    /// the top of its standard (zoomed out, round its medallion), so a banner that only grazes
    /// the ring under a figure, or passes just over its standard, stays as it is. `rests`: one
    /// of the viewer's own units asleep or fortified, which fades nothing.
    private func figureRects(_ renderer: MapRenderer, strategic: Bool) -> [(rect: CGRect, rests: Bool)] {
        guard !nearBanners.isEmpty else { return [] }
        let viewer = renderer.viewer
        return renderer.state.units.compactMap { unit in
            guard nearBanners.contains(unit.position),
                  let p = renderer.screenPoint(ofUnit: unit.id), // nil: not drawn (out of sight)
                  let w = tileWidth(renderer, at: unit.position) else { return nil }
            let rect = strategic ? CGRect(x: p.x - w * 0.3, y: p.y - w * 0.3, width: w * 0.6, height: w * 0.6)
                : CGRect(x: p.x - w * 0.25, y: p.y - w * 0.62, width: w * 0.5, height: w * 0.62)
            let rests = unit.owner == viewer && [.sleeping, .fortifying, .fortified].contains(unit.activity)
            return (rect, rests)
        }
    }

    /// One city's banner: its model, its art (standard and strategic, drawn when needed), and
    /// its layers: the banner, and over it its secondary rows, which fade on their own.
    private final class Slot {
        var model: CityBannerModel
        let layer = CALayer()
        let details = CALayer()
        var art: [BannerArt.Style: BannerArt.Rendered] = [:]
        /// The image the layer shows.
        var shown: CGImage?
        /// How far the banner was moved up (−) or down from its place to stay clear (strategic
        /// zoom; 0 otherwise).
        var shift: CGFloat = 0
        private(set) var visible = false
        private var opacity: Float = 0
        private var detailsOpacity: Float = 1

        init(model: CityBannerModel) {
            self.model = model
            layer.addSublayer(details)
        }

        /// Fades the banner in or out (0.18 s), from wherever a running fade has it.
        func setVisible(_ show: Bool) {
            visible = show
            let target: Float = show ? 1 : 0
            guard target != opacity else { return }
            opacity = target
            Self.fade(layer, to: target)
        }

        /// Fades the secondary rows to `fadedOpacity` or back.
        func setDetailsFaded(_ faded: Bool) {
            let target: Float = faded ? MapOverlay.fadedOpacity : 1
            guard target != detailsOpacity else { return }
            detailsOpacity = target
            Self.fade(details, to: target)
        }

        private static func fade(_ layer: CALayer, to target: Float) {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
            fade.toValue = target
            fade.duration = 0.18
            layer.opacity = target
            layer.add(fade, forKey: "fade")
        }
    }

    // MARK: Damage numbers

    private struct Floater {
        let layer: CALayer
        let hex: HexCoord
        /// From the hex's point to where the number started.
        let offset: CGPoint
        let ends: CFTimeInterval
    }

    /// A damage number rising from a view point over `hex` (it stays pinned to the hex as the
    /// map moves). `own`: the viewer's unit or city was hurt (a crimson number).
    func showDamage(_ amount: Int, own: Bool, killed: Bool, at point: CGPoint, hex: HexCoord, delay: CFTimeInterval = 0) {
        guard amount > 0, bounds.insetBy(dx: -20, dy: -20).contains(point),
              let art = DamageArt.image("−\(amount)", fill: own ? .own : .other, big: killed, scale: scale) else { return }
        float(art, at: point, hex: hex, delay: delay, duration: Self.floaterDuration)
    }

    /// A tribal village's gift to the viewer floating up from its tile, as damage numbers do,
    /// in the good tone and a little longer: "+50 Gold", "+20 Science", "+1 Builder" (M1 §7.7).
    func showGift(_ gift: TribalVillageGift, at point: CGPoint, hex: HexCoord) {
        guard bounds.insetBy(dx: -20, dy: -20).contains(point),
              let art = DamageArt.image(TribalVillageText.label(gift), fill: .gift, big: false, scale: scale) else { return }
        float(art, at: point, hex: hex, delay: 0, duration: Self.giftDuration)
    }

    /// Floats `art` up from a view point over `hex` and fades it (with Reduce Motion it only
    /// fades, in place), pinned to the hex as the map moves.
    private func float(_ art: DamageArt.Rendered, at point: CGPoint, hex: HexCoord, delay: CFTimeInterval,
                       duration floatDuration: CFTimeInterval) {
        guard let renderer else { return }
        let base = renderer.screenPoint(of: hex, lift: Self.floaterLift) ?? point
        let now = CACurrentMediaTime()
        // Numbers on one tile in quick succession stack upward.
        let crowd = floaters.filter { $0.hex == hex && $0.ends - now > (Self.floaterDuration - 0.5) * timeScale }.count
        let offset = CGPoint(x: point.x - base.x, y: point.y - base.y - 10 - CGFloat(crowd) * 20)
        if floaters.count >= Self.maxFloaters {
            floaters.removeFirst().layer.removeFromSuperlayer()
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let layer = CALayer()
        layer.contents = art.image
        layer.contentsScale = scale
        layer.bounds = CGRect(origin: .zero, size: art.size)
        layer.position = CGPoint(x: base.x + offset.x, y: base.y + offset.y)
        layer.opacity = 0
        floaterLayer.addSublayer(layer)
        let begin = layer.convertTime(now, from: nil) + delay * timeScale
        let duration = (reduceMotion ? max(1.5, floatDuration) : floatDuration) * timeScale
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = reduceMotion ? [0, 0.1, 0.75, 1] : [0, 0.07, 0.68, 1]
        var animations: [CAAnimation] = [fade]
        if !reduceMotion {
            func t(_ y: CGFloat, _ s: CGFloat) -> NSValue {
                NSValue(caTransform3D: CATransform3DScale(CATransform3DMakeTranslation(0, y, 0), s, s, 1))
            }
            let rise = CAKeyframeAnimation(keyPath: "transform")
            rise.values = [t(8, 0.55), t(-3, 1.16), t(-7, 1), t(-Self.floaterRise, 1)]
            rise.keyTimes = [0, 0.1, 0.2, 1]
            rise.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut),
                                    CAMediaTimingFunction(name: .easeOut)]
            animations.append(rise)
        }
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = duration
        group.beginTime = begin
        group.fillMode = .both
        group.isRemovedOnCompletion = false
        layer.add(group, forKey: "float")
        CATransaction.commit()
        floaters.append(Floater(layer: layer, hex: hex, offset: offset, ends: now + delay * timeScale + duration))
    }

    static let floaterDuration: CFTimeInterval = 1.3
    /// A gift's label stays a little longer than a damage number: it has words to read.
    static let giftDuration: CFTimeInterval = 2.2
    /// How far a damage number rises (points).
    static let floaterRise: CGFloat = 36

    private func placeFloaters(_ renderer: MapRenderer, snap: (CGFloat) -> CGFloat) {
        guard !floaters.isEmpty else { return }
        let now = CACurrentMediaTime()
        floaters.removeAll { floater in
            guard now < floater.ends else {
                floater.layer.removeFromSuperlayer()
                return true
            }
            if let p = renderer.screenPoint(of: floater.hex, lift: Self.floaterLift) {
                floater.layer.position = CGPoint(x: snap(p.x + floater.offset.x), y: snap(p.y + floater.offset.y))
            }
            return false
        }
    }

    /// Drops every damage number (the game is closing, or a big jump).
    func clearFloaters() {
        for floater in floaters { floater.layer.removeFromSuperlayer() }
        floaters.removeAll()
    }

    // MARK: Quarter marks

    private func rebuildMarks() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for mark in marks { mark.layer.removeFromSuperlayer() }
        marks.removeAll()
        let labelled = Set(siteLabels.map(\.hex))
        var arts: [(DamageArt.Rendered, HexCoord)] = quarterMarks.filter { !labelled.contains($0.hex) }.compactMap { mark in
            QuarterMarkArt.image(mark.symbol, pillaged: mark.pillaged, scale: scale).map { ($0, mark.hex) }
        }
        arts += campMarks.filter { !labelled.contains($0) }.compactMap { hex in
            QuarterMarkArt.image("tent.2.fill", pillaged: true, scale: scale).map { ($0, hex) }
        }
        arts += siteLabels.compactMap { label in DamageArt.image(label.text, fill: .gift, big: false, scale: scale).map { ($0, label.hex) } }
        for (art, hex) in arts {
            let layer = CALayer()
            layer.contents = art.image
            layer.contentsScale = scale
            layer.bounds = CGRect(origin: .zero, size: art.size)
            layer.isHidden = true
            markLayer.addSublayer(layer)
            marks.append((layer, hex))
        }
        CATransaction.commit()
    }

    /// The route lines for this frame: each path through its tiles' screen points, broken where
    /// a tile is off the view or the map wraps between two steps.
    private func placeRoutes(_ renderer: MapRenderer) {
        guard !tradeRoutes.isEmpty else { return }
        let path = CGMutablePath(), jump = max(bounds.width, bounds.height) / 3
        for route in tradeRoutes {
            var last: CGPoint?
            for point in renderer.screenPoints(of: route, lift: 0) {
                guard let p = point else {
                    last = nil
                    continue
                }
                if let l = last, hypot(p.x - l.x, p.y - l.y) < jump { path.addLine(to: p) } else { path.move(to: p) }
                last = p
            }
        }
        routeLayer.path = path
    }

    private func placeMarks(_ renderer: MapRenderer, screen: CGRect, snap: (CGFloat) -> CGFloat) {
        guard !marks.isEmpty else { return }
        let points = renderer.screenPoints(of: marks.map(\.hex), lift: 0)
        for (mark, point) in zip(marks, points) {
            guard let p = point, screen.contains(p) else {
                mark.layer.isHidden = true
                continue
            }
            mark.layer.isHidden = false
            mark.layer.position = CGPoint(x: snap(p.x), y: snap(p.y))
        }
    }

    // MARK: Accessibility

    /// VoiceOver reads the banners shown, top-most first, and activating one selects its city.
    override var accessibilityElements: [Any]? {
        get {
            hits.compactMap { hit -> BannerElement? in
                guard let model = slots[hit.city]?.model else { return nil }
                let element = elements[hit.city] ?? BannerElement(accessibilityContainer: self)
                element.city = hit.city
                element.overlay = self
                element.accessibilityLabel = model.accessibilityLabel
                element.accessibilityTraits = .button
                element.accessibilityFrameInContainerSpace = Self.touchRect(hit.rect)
                elements[hit.city] = element
                return element
            }
        }
        set {}
    }

    private final class BannerElement: UIAccessibilityElement {
        var city = CityID(0)
        weak var overlay: MapOverlay?

        override func accessibilityActivate() -> Bool {
            overlay?.onActivateBanner?(city)
            return true
        }
    }
}

// MARK: - Damage number art

/// Damage numbers: serif numerals with an ink outline and a soft shadow, cream for others'
/// losses and crimson for the viewer's own; a little larger for a killing blow.
@MainActor
enum DamageArt {
    struct Rendered {
        var image: CGImage
        var size: CGSize
    }

    /// The fill of the text: a hurt own unit or city (crimson), anyone else (cream), or a
    /// gift to the viewer (green).
    enum Fill: Hashable {
        case own, other, gift
    }

    private struct Key: Hashable {
        var text: String
        var fill: Fill
        var big: Bool
    }

    private static var cache: [Key: Rendered] = [:]

    static func image(_ text: String, fill: Fill, big: Bool, scale: CGFloat) -> Rendered? {
        let key = Key(text: text, fill: fill, big: big)
        if let cached = cache[key] { return cached }
        let font = HUD.UI.numeric(big ? 23 : 19, weight: .heavy)
        let string = text as NSString
        let textSize = string.size(withAttributes: [.font: font])
        let pad: CGFloat = 5
        let size = CGSize(width: ceil(textSize.width + pad * 2), height: ceil(textSize.height + pad * 2))
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let origin = CGPoint(x: pad, y: pad)
            // The outline: the text in ink, stamped around a small circle, with the sun shadow.
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 1, height: 1.5), blur: 2.5, color: UIColor.black.withAlphaComponent(0.45).cgColor)
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            let outline: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: HUD.UI.ink]
            let r: CGFloat = 1.7
            for i in 0..<12 {
                let a = CGFloat(i) * .pi / 6
                string.draw(at: CGPoint(x: origin.x + cos(a) * r, y: origin.y + sin(a) * r), withAttributes: outline)
            }
            cg.endTransparencyLayer()
            cg.restoreGState()
            let color = switch fill {
            case .own: HUD.UI.wound
            case .other: HUD.UI.cream
            case .gift: HUD.UI.healthy
            }
            string.draw(at: origin, withAttributes: [.font: font, .foregroundColor: color])
        }
        guard let cgImage = image.cgImage else { return nil }
        let rendered = Rendered(image: cgImage, size: size)
        if cache.count > 400 { cache.removeAll() }
        cache[key] = rendered
        return rendered
    }
}

/// A built quarter's mark on the map: its kind's symbol in ink on a cream disc with an ink
/// rim (crimson when pillaged).
@MainActor
enum QuarterMarkArt {
    private struct Key: Hashable {
        var symbol: String
        var pillaged: Bool
    }

    private static var cache: [Key: DamageArt.Rendered] = [:]

    static func image(_ symbol: String, pillaged: Bool, scale: CGFloat) -> DamageArt.Rendered? {
        let key = Key(symbol: symbol, pillaged: pillaged)
        if let cached = cache[key] { return cached }
        let side: CGFloat = 26
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let config = UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        let rim = pillaged ? HUD.UI.wound : HUD.UI.ink
        guard let glyph = UIImage(systemName: symbol, withConfiguration: config)?.withTintColor(rim, renderingMode: .alwaysOriginal) else {
            return nil
        }
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let disc = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
            cg.setShadow(offset: CGSize(width: 0.5, height: 1), blur: 1.5, color: UIColor.black.withAlphaComponent(0.4).cgColor)
            cg.setFillColor(HUD.UI.cream.withAlphaComponent(0.92).cgColor)
            cg.fillEllipse(in: disc)
            cg.setShadow(offset: .zero, blur: 0)
            cg.setStrokeColor(rim.cgColor)
            cg.setLineWidth(1.5)
            cg.strokeEllipse(in: disc)
            let g = glyph.size
            glyph.draw(in: CGRect(x: (side - g.width) / 2, y: (side - g.height) / 2, width: g.width, height: g.height))
        }
        guard let cgImage = image.cgImage else { return nil }
        let rendered = DamageArt.Rendered(image: cgImage, size: size)
        cache[key] = rendered
        return rendered
    }
}
