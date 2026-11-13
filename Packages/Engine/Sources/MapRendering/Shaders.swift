import Dispatch
import Metal
import Synchronization

/// Metal shader source, compiled at runtime (`makeLibrary(source:)`) so the package builds
/// identically with Xcode and `swift build`, and `swift test` catches shader errors.
///
/// The source is assembled from one file per area so each can be worked on independently:
/// - `ShaderCommon.swift`: frozen contract (uniforms, instance layouts, noise, tile fetch).
/// - `ShaderLighting.swift`: sun, explored-fog look and atmosphere shared by every pass.
/// - `ShaderMarks.swift`: player colours and ring patterns, and what the renderer inputs paint
///   on the ground (territory tint, farm fields, pasture fences, movement range, site scores).
/// - `ShaderGround.swift`: terrain, water, rivers, fog of war (one full-screen-ish quad).
/// - `ShaderDecor.swift`: trees, hills, mountains (static sprite instances).
/// - `ShaderUnits.swift`: unit tokens, shadows, path markers (per-frame sprite instances).
/// - `ShaderOverlay.swift`: selection ring and path geometry on the ground.
enum Shaders {
    static var source: String {
        [common, lighting, marksSource, groundSource, decorSource, unitSource, overlaySource].joined(separator: "\n")
    }
}

/// The compiled shaders, once per process and device. `MapRenderer.prewarm()` starts the
/// compile in the background while the start screen is up; a renderer created before it
/// finishes waits for it instead of compiling again, and later renderers (and the ground
/// bake) reuse the library.
final class ShaderLibrary: Sendable {
    static let shared = ShaderLibrary()

    private struct State {
        var device: UInt64?
        var library: MTLLibrary?
        var error: String?
    }
    private let group = DispatchGroup()
    private let state = Mutex(State())

    /// Starts compiling for `device`, unless a compile for it has started already.
    func start(device: MTLDevice) {
        let id = device.registryID
        let fresh = state.withLock { s -> Bool in
            guard s.device != id else { return false }
            s = State(device: id)
            return true
        }
        guard fresh else { return }
        group.enter()
        device.makeLibrary(source: Shaders.source, options: nil) { library, error in
            self.state.withLock { s in
                guard s.device == id else { return }
                s.library = library
                s.error = error.map { "\($0)" }
            }
            self.group.leave()
        }
    }

    /// The library for `device`, waiting for the compile if it is still running.
    func library(device: MTLDevice) throws -> MTLLibrary {
        start(device: device)
        group.wait()
        let result = state.withLock { s in (s.device == device.registryID ? s.library : nil, s.error) }
        if let library = result.0 { return library }
        if let error = result.1 { throw CompileError(message: error) }
        return try device.makeLibrary(source: Shaders.source, options: nil)
    }

    struct CompileError: Error, CustomStringConvertible {
        var message: String
        var description: String { message }
    }
}
