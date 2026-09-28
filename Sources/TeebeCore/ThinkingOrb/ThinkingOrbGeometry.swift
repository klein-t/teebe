// Ported from thinking-orbs 0.3.2 (https://libraries.dev/orbs), MIT License,
// Copyright (c) 2026 Jakub Antalik. See THIRD-PARTY-LICENSES.md.
//
// Only the geometry the app draws is ported: the `solving` (rubik) and
// `breathing` (ring) states at the 20 px preset, with the `dotSize` multiplier
// and the tint's depth-shading ramp. Numbers follow the JS engine exactly; the
// golden tests in ThinkingOrbTests compare against its real output.

import Foundation

/// The two orb animations the app uses.
public enum ThinkingOrbState: Sendable, CaseIterable {
    /// Bands scramble in quarter turns, then click back solved (JS mode `rubik`).
    case solving
    /// A face-on ring slowly morphing (JS mode `ring`).
    case breathing
}

/// One dot of a finished frame, in the orb's own points (0...size).
public struct ThinkingOrbDot: Equatable, Sendable {
    public var x: Double
    public var y: Double
    /// Depth; frames are already sorted far to near.
    public var z: Double
    public var radius: Double
    /// Ink value, 0 = full tint. Painters clamp it to 0...1.
    public var white: Double
    public var alpha: Double
}

/// An 8-bit sRGB colour, used for the tint and its shaded ramp.
public struct ThinkingOrbRGB: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// The JS painter's `inkColor` with a tint: fade toward black on dark
    /// substrates and toward white on light ones, rounded to whole channels.
    public func shaded(white: Double, dark: Bool) -> ThinkingOrbRGB {
        let w = min(1, max(0, white))
        func ramp(_ c: Double) -> Double {
            jsRound(dark ? c * (1 - w) : c + (255 - c) * w)
        }
        return ThinkingOrbRGB(red: ramp(red), green: ramp(green), blue: ramp(blue))
    }
}

/// A resolved orb: the preset's speed and draw options for one state at the
/// app's size, ready to produce frames.
public struct ThinkingOrbStyle: Sendable {
    /// The tuned inline-text preset (20 CSS px in the package).
    public static let size: Double = 20
    /// The app draws slightly bolder dots than the stock preset.
    public static let appDotSize: Double = 1.2
    /// Geometry time of the package's reduced-motion frame.
    public static let staticTime: Double = 0.6

    public let state: ThinkingOrbState
    /// Geometry seconds per wall-clock second.
    public let speed: Double
    let options: Options

    public init(state: ThinkingOrbState, dotSize: Double = ThinkingOrbStyle.appDotSize) {
        self.state = state
        let preset = Self.preset(for: state)
        speed = preset.speed
        options = preset.options.scalingRadii(max(0.1, dotSize))
    }

    /// The frame at geometry time `t` (wall-clock seconds times `speed`).
    public func frame(at t: Double) -> [ThinkingOrbDot] {
        switch state {
        case .solving: return Self.rubikFrame(size: Self.size, t: t, options: options)
        case .breathing: return Self.ringFrame(size: Self.size, t: t, options: options)
        }
    }
}

// MARK: - Presets

extension ThinkingOrbStyle {
    /// The draw options the two ported modes read.
    struct Options: Sendable {
        var latRings: Double = 0
        var lonDensity: Double = 0
        var lanes: Double = 0
        var segs: Double = 0
        var moveCount: Double = 14
        var rBase: Double
        var rDepth: Double
        var rActive: Double = 0
        var inkFar: Double = 0
        var inkSpan: Double = 0
        var rsPow: Double = 0.6
        var rMin: Double = 0.3
        var faceOn = false
        var spin: Double = 1
        var bandMul: Double = 1
        var wobMul: Double = 1

        /// JS `scaleCounts`: paired lattice counts scale by sqrt so the pair's
        /// product tracks the density multiplier.
        func scalingCounts(_ scale: Double) -> Options {
            var out = self
            let rt = scale.squareRoot()
            if latRings > 0 {
                out.latRings = max(2, jsRound(latRings * rt))
                out.lonDensity = max(2, jsRound(lonDensity * rt))
            }
            if lanes > 0 {
                out.lanes = max(2, jsRound(lanes * rt))
                out.segs = max(2, jsRound(segs * rt))
            }
            return out
        }

        /// JS `scaleRadii`.
        func scalingRadii(_ scale: Double) -> Options {
            var out = self
            out.rBase *= scale
            out.rDepth *= scale
            out.rActive *= scale
            return out
        }
    }

    /// JS `resolvePreset(state, 20)`: base profile, then the 20 px preset's
    /// count and radius scaling, then its extra options.
    static func preset(for state: ThinkingOrbState) -> (speed: Double, options: Options) {
        switch state {
        case .solving:
            let base = Options(latRings: 15, lonDensity: 40, moveCount: 14, rBase: 0.6, rDepth: 1.7,
                               rActive: 0.3, inkFar: 0.62, inkSpan: 0.54)
            return (1.95, base.scalingCounts(0.088).scalingRadii(1.9))
        case .breathing:
            let base = Options(lanes: 5, segs: 88, rBase: 1.1, rDepth: 1.7, faceOn: true)
            var options = base.scalingCounts(0.028).scalingRadii(1.622)
            options.spin = 0
            options.bandMul = 3.968
            options.wobMul = 0.565
            return (3.78, options)
        }
    }
}

// MARK: - Shared engine helpers

/// JS `Math.round`: halves round up.
func jsRound(_ x: Double) -> Double { (x + 0.5).rounded(.down) }

extension ThinkingOrbStyle {
    /// JS `hashD`: deterministic hash in [0, 1).
    static func hashD(_ a: Double, _ b: Double) -> Double {
        let h = sin(a * 12.9898 + b * 78.233) * 43758.5453
        return h - h.rounded(.down)
    }

    /// JS `radiusScale`: radii were tuned for a 300 pt frame.
    static func radiusScale(_ size: Double, _ pow: Double) -> Double {
        Foundation.pow(size / 300, pow)
    }

    /// A point in the orb's 3-D model space, or a projected point (x, y in
    /// points, z as depth).
    struct Vec3 {
        var x: Double
        var y: Double
        var z: Double
    }

    /// JS `makeProj`: spin, tilt and orthographic projection.
    struct Projector {
        let st: Double, ct: Double, sy: Double, cyw: Double
        let cx: Double, cy: Double, scale: Double

        init(yaw: Double, tilt: Double, cx: Double, cy: Double, scale: Double) {
            st = sin(tilt)
            ct = cos(tilt)
            sy = sin(yaw)
            cyw = cos(yaw)
            self.cx = cx
            self.cy = cy
            self.scale = scale
        }

        func callAsFunction(_ x: Double, _ y: Double, _ z: Double) -> Vec3 {
            let x1 = x * cyw + z * sy
            let z1 = -x * sy + z * cyw
            let y1 = y * ct - z1 * st
            let z2 = y * st + z1 * ct
            return Vec3(x: cx + x1 * scale, y: cy - y1 * scale, z: z2)
        }
    }

    /// JS `finalizeFrame`: drop invisible dots, clamp radii, sort far to near.
    /// JS sort is stable, so ties keep their generation order.
    static func finalize(_ dots: [ThinkingOrbDot], rMin: Double) -> [ThinkingOrbDot] {
        dots.enumerated()
            .filter { $0.element.alpha >= 0.02 }
            .map { item -> (Int, ThinkingOrbDot) in
                var dot = item.element
                dot.radius = max(rMin, dot.radius)
                return (item.offset, dot)
            }
            .sorted { $0.1.z != $1.1.z ? $0.1.z < $1.1.z : $0.0 < $1.0 }
            .map(\.1)
    }
}
