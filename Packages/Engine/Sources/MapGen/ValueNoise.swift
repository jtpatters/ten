import Foundation

/// Seeded 2D value noise with fractal (fBm) octaves, optionally periodic in x so
/// cylindrical (east-west wrapping) maps have no seam.
///
/// Uses only +, *, floor, so results are bit-identical across Apple devices
/// (no libm transcendental functions whose implementations can vary by OS).
struct ValueNoise: Sendable {
    let seed: UInt64

    private func lattice(_ x: Int, _ y: Int) -> Double {
        var h = seed
        h ^= UInt64(bitPattern: Int64(x)) &* 0x9E37_79B9_7F4A_7C15
        h ^= UInt64(bitPattern: Int64(y)) &* 0xC2B2_AE3D_27D4_EB4F
        h = (h ^ (h >> 30)) &* 0xBF58_476D_1CE4_E5B9
        h = (h ^ (h >> 27)) &* 0x94D0_49BB_1331_11EB
        h ^= h >> 31
        return Double(h >> 11) * 0x1.0p-53
    }

    private static func smooth(_ t: Double) -> Double { t * t * (3 - 2 * t) }

    /// Single octave in [0, 1). `period` (if set) wraps lattice x coordinates.
    func sample(x: Double, y: Double, period: Int?) -> Double {
        let fx = floor(x), fy = floor(y)
        var x0 = Int(fx)
        let y0 = Int(fy)
        let tx = Self.smooth(x - fx), ty = Self.smooth(y - fy)
        var x1 = x0 + 1
        if let p = period {
            x0 = ((x0 % p) + p) % p
            x1 = ((x1 % p) + p) % p
        }
        let a = lattice(x0, y0), b = lattice(x1, y0)
        let c = lattice(x0, y0 + 1), d = lattice(x1, y0 + 1)
        let top = a + (b - a) * tx
        let bottom = c + (d - c) * tx
        return top + (bottom - top) * ty
    }

    /// Fractal noise in [0, 1). Base `period` doubles each octave, preserving wrap.
    func fbm(x: Double, y: Double, octaves: Int, period: Int?) -> Double {
        var total = 0.0, amplitude = 1.0, norm = 0.0, frequency = 1.0
        for octave in 0..<octaves {
            let p = period.map { $0 << octave }
            total += sample(x: x * frequency, y: y * frequency, period: p) * amplitude
            norm += amplitude
            amplitude *= 0.5
            frequency *= 2
        }
        return total / norm
    }
}
