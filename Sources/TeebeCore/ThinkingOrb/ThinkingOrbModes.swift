// Ported from thinking-orbs 0.3.2 (https://libraries.dev/orbs), MIT License,
// Copyright (c) 2026 Jakub Antalik. See THIRD-PARTY-LICENSES.md.
//
// The `rubik` (solving) and `ring` (breathing) frame functions, line for line.

import Foundation

extension ThinkingOrbStyle {
    // MARK: rubik (solving)

    struct Move {
        let axis: Int
        let lo: Double
        let hi: Double
        let ang: Double
    }

    /// JS `makeMoves`: a fixed, hashed scramble of quarter turns on 4 slabs.
    static func makeMoves(_ count: Int) -> [Move] {
        (0..<count).map { i in
            let index = Double(i)
            let axis = min(2, Int((hashD(index, 2.3) * 3).rounded(.down)))
            let lo = -1 + 0.5 * min(3, (hashD(index, 5.9) * 4).rounded(.down))
            let dir: Double = hashD(index, 7.7) < 0.5 ? 1 : -1
            return Move(axis: axis, lo: lo, hi: lo + 0.5, ang: dir * .pi / 2)
        }
    }

    /// JS `solveCycle`: scramble move by move, unwind in reverse, then rest.
    static func solveCycle(_ time: Double, count: Int, slotDur: Double, rest: Double)
        -> (amount: [Double], active: Int) {
        let span = 2 * Double(count) * slotDur
        let tc = time.truncatingRemainder(dividingBy: span + rest)
        var amount = [Double](repeating: 0, count: count)
        var active = -1
        if tc < span {
            // Clamped: float rounding of tc / slotDur must not index past the cycle.
            let slot = min(2 * count - 1, Int((tc / slotDur).rounded(.down)))
            let p = (tc - Double(slot) * slotDur) / slotDur
            let cl = min(1, p / 0.7)
            let ep = 1 - pow(1 - cl, 3)
            if slot < count {
                for i in 0..<slot { amount[i] = 1 }
                amount[slot] = ep
                active = slot
            } else {
                let u = 2 * count - 1 - slot
                for i in 0..<u { amount[i] = 1 }
                amount[u] = 1 - ep
                active = u
            }
        }
        return (amount, active)
    }

    /// JS `applyMoves`: rotate a lattice point through every applied move.
    static func applyMoves(_ point: Vec3, _ moves: [Move],
                           amount: [Double], active: Int) -> (point: Vec3, inActive: Bool) {
        var x = point.x, y = point.y, z = point.z
        var inActive = false
        for (i, mv) in moves.enumerated() where amount[i] > 0 {
            let coord = mv.axis == 0 ? x : mv.axis == 1 ? y : z
            if coord < mv.lo || coord >= mv.hi { continue }
            if i == active { inActive = true }
            let a = mv.ang * amount[i]
            let ca = cos(a)
            let sa = sin(a)
            switch mv.axis {
            case 0:
                let y2 = y * ca - z * sa
                z = y * sa + z * ca
                y = y2
            case 1:
                let x2 = x * ca + z * sa
                z = -x * sa + z * ca
                x = x2
            default:
                let x2 = x * ca - y * sa
                y = x * sa + y * ca
                x = x2
            }
        }
        return (Vec3(x: x, y: y, z: z), inActive)
    }

    /// JS `frameRubik`.
    static func rubikFrame(size: Double, t: Double, options o: Options) -> [ThinkingOrbDot] {
        let cx = size / 2
        let cy = size / 2
        let radius = size / 2 * 0.82
        let pt = Projector(yaw: t * 0.55, tilt: 0.35 + 0.1 * sin(t * 0.9), cx: cx, cy: cy, scale: radius)
        let rs = radiusScale(size, o.rsPow)
        let moveCount = Int(o.moveCount)
        let moves = makeMoves(moveCount)
        let sc = solveCycle(t, count: moveCount, slotDur: 0.42, rest: 1.2)
        let latRings = Int(o.latRings)
        var dots: [ThinkingOrbDot] = []
        for li in 0...latRings {
            let lat = -Double.pi / 2 + Double(li) / Double(latRings) * .pi
            let cosLat = cos(lat)
            let sinLat = sin(lat)
            let lonCount = max(1, Int(jsRound(abs(cosLat) * o.lonDensity)))
            for lj in 0..<lonCount {
                let lon = Double(lj) / Double(lonCount) * 2 * .pi
                let moved = applyMoves(Vec3(x: cosLat * cos(lon), y: sinLat, z: cosLat * sin(lon)),
                                       moves, amount: sc.amount, active: sc.active)
                let inActive = moved.inActive
                let p = pt(moved.point.x, moved.point.y, moved.point.z)
                let depth = (p.z + 1) / 2
                dots.append(ThinkingOrbDot(
                    x: p.x, y: p.y, z: p.z,
                    radius: (o.rBase + o.rDepth * depth + (inActive ? o.rActive : 0)) * rs,
                    white: o.inkFar - o.inkSpan * depth - (inActive ? 0.14 : 0),
                    alpha: 1
                ))
            }
        }
        return finalize(dots, rMin: o.rMin)
    }

    // MARK: ring (breathing)

    /// JS `frameRibbon` with the `ring` profile: face-on, no ghost sphere
    /// (`ghostN` 0), the undulation moved onto the radius.
    static func ringFrame(size: Double, t: Double, options o: Options) -> [ThinkingOrbDot] {
        let cx = size / 2
        let cy = size / 2
        let radius = size / 2 * 0.78
        let spin = o.spin
        let camTilt = 0.3
        let pt = Projector(yaw: t * 0.1 * spin, tilt: camTilt, cx: cx, cy: cy, scale: 1)
        let rs = radiusScale(size, o.rsPow)
        let ya = t * 0.24 * spin
        let ta = o.faceOn ? -camTilt : 0.55 + 0.3 * sin(t * 0.18) * spin
        let ux = cos(ya), uy = 0.0, uz = sin(ya)
        let vx = -uz * sin(ta), vy = cos(ta), vz = ux * sin(ta)
        let nx = uy * vz - uz * vy
        let ny = uz * vx - ux * vz
        let nz = ux * vy - uy * vx
        let wobAmp = 0.23 * o.wobMul
        let baseR = o.faceOn ? radius / (1 + 0.85 * wobAmp) : radius
        let segs = Int(o.segs)
        let lanes = max(1, Int(jsRound(o.lanes * o.bandMul)))
        let mid = Double(lanes - 1) / 2
        var dots: [ThinkingOrbDot] = []
        for w in 0..<lanes {
            let lane = Double(w)
            let laneOff = (lane - mid) * 0.075
            let edge = abs(lane - mid) / max(1, mid)
            for k in 0..<segs {
                let a = Double(k) / Double(segs) * 2 * .pi
                let wob = (0.16 * sin(a * 3 - t * 1.7 + lane * 0.22) + 0.07 * sin(a * 5 + t * 1.1)) * o.wobMul
                let radial = o.faceOn ? 1 + wob : 1
                let off = o.faceOn ? laneOff : laneOff + wob
                let x = ux * cos(a) + vx * sin(a) + nx * off
                let y = uy * cos(a) + vy * sin(a) + ny * off
                let z = uz * cos(a) + vz * sin(a) + nz * off
                let l = (x * x + y * y + z * z).squareRoot()
                let rr = baseR * radial
                let p = pt(x / l * rr, y / l * rr, z / l * rr)
                let depth = (p.z / radius + 1) / 2
                dots.append(ThinkingOrbDot(
                    x: p.x, y: p.y, z: p.z,
                    radius: (o.rBase + o.rDepth * depth) * (1 - 0.25 * edge) * rs,
                    white: 0.52 - 0.44 * depth + 0.18 * edge,
                    alpha: 0.4 + 0.6 * depth
                ))
            }
        }
        return finalize(dots, rMin: o.rMin)
    }
}
