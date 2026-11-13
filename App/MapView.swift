import MapRendering
import MetalKit
import SwiftUI
import UIKit

/// Hosts the Metal map with the session's overlay (city banners, damage numbers) laid over it,
/// and turns touch and trackpad gestures into renderer calls (pan, pinch) and session input
/// (tap, long-press). A tap on a city banner selects the city before the map is asked what is
/// under the finger (M1 §16). Any gesture counts as touching the map, which keeps AI playback
/// from moving the camera for a while.
struct MapView: UIViewRepresentable {
    let session: GameSession

    func makeUIView(context: Context) -> MapContainer {
        let container = MapContainer(mapView: MTKView(frame: .zero, device: session.renderer.device))
        let view = container.mapView
        session.renderer.configure(view)
        view.isMultipleTouchEnabled = true
        container.attach(session.overlay)

        let c = context.coordinator
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 2
        pan.allowedScrollTypesMask = .all // trackpad two-finger scroll pans
        pan.delegate = c
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.handlePinch(_:)))
        pinch.delegate = c
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleTap(_:)))
        let longPress = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.45
        tap.require(toFail: longPress)
        for g in [pan, pinch, tap, longPress] as [UIGestureRecognizer] { view.addGestureRecognizer(g) }
        view.accessibilityLabel = "Map"
        return container
    }

    func updateUIView(_ container: MapContainer, context: Context) {
        context.coordinator.session = session
        if container.mapView.delegate !== session.renderer { session.renderer.configure(container.mapView) }
        if container.overlay !== session.overlay { container.attach(session.overlay) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    /// The map and, over it, the overlay (which takes no touches).
    final class MapContainer: UIView {
        let mapView: MTKView
        private(set) weak var overlay: MapOverlay?

        init(mapView: MTKView) {
            self.mapView = mapView
            super.init(frame: .zero)
            mapView.frame = bounds
            mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(mapView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        func attach(_ overlay: MapOverlay) {
            self.overlay?.removeFromSuperview()
            overlay.removeFromSuperview()
            overlay.frame = bounds
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(overlay)
            self.overlay = overlay
        }

        override var accessibilityElements: [Any]? {
            get { [mapView] + (overlay.map { [$0] } ?? []) }
            set {}
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var session: GameSession

        init(session: GameSession) {
            self.session = session
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            session.noteMapTouched()
            let location = g.location(in: g.view)
            let t = g.translation(in: g.view)
            session.renderer.pan(from: CGPoint(x: location.x - t.x, y: location.y - t.y), to: location)
            g.setTranslation(.zero, in: g.view)
        }

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            session.noteMapTouched()
            session.renderer.zoom(by: g.scale, aroundViewPoint: g.location(in: g.view))
            g.scale = 1
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            session.notices.acknowledge()
            session.tapMap(at: g.location(in: g.view))
        }

        @objc func handleLongPress(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began else { return }
            session.notices.acknowledge()
            let point = g.location(in: g.view)
            if let city = session.overlay.bannerCity(at: point), let hex = session.cityHex(city) {
                session.inspect(hex)
                return
            }
            guard let hex = session.renderer.hex(atViewPoint: point) else { return }
            session.inspect(hex)
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            (g is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
                || (g is UIPinchGestureRecognizer && other is UIPanGestureRecognizer)
        }
    }
}
