import MapRendering
import SwiftUI

@main
struct TenThousandYearsApp: App {
    init() {
        MapRenderer.prewarm() // shaders and sprite sheets, while the start screen is up
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// The start screen, or the game on screen; a busy veil while a world is made or a save opens.
struct RootView: View {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if let session = model.session {
                GameView(session: session, model: model)
                    .id(ObjectIdentifier(session))
                    .transition(.opacity)
            } else {
                StartView(model: model)
                    .transition(.opacity)
            }
            if let busy = model.busy {
                BusyVeil(text: busy)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.session.map(ObjectIdentifier.init))
        .animation(.easeInOut(duration: 0.2), value: model.busy)
        .task { await model.launchIfNeeded() }
        .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
        .alert(model.alert?.title ?? "", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
               presenting: model.alert) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
    }
}

/// A calm veil with a message, over whatever is underneath.
struct BusyVeil: View {
    var text: String

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.35)).ignoresSafeArea()
            HStack(spacing: HUD.Space.m) {
                ProgressView().tint(HUD.inkSoft)
                Text(text).font(HUD.title(.body))
            }
            .padding(.horizontal, HUD.Space.xl)
            .padding(.vertical, HUD.Space.l)
            .parchment(cornerRadius: HUD.Radius.large)
        }
        .accessibilityElement(children: .combine)
    }
}
