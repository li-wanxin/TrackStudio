import SwiftUI
/// 把零件定义转成可绘制的线段（世界坐标，mm）
enum Seg {
    case line(Vec2, Vec2)
    case polyline([Vec2])
}

enum PieceGeometry {

    /// 采样弯轨弧线。left = 左转（+角度方向）
    static func arcPoints(pose: Pose, radius: Double, sweepDeg: Double, left: Bool) -> [Vec2] {
        var pts: [Vec2] = []
        let n = 20
        for i in 0...n {
            let t = Double(i) / Double(n) * sweepDeg * .pi / 180
            let dy = radius - radius * cos(t)
            let local = left ? Vec2(x: radius * sin(t), y: dy)
                             : Vec2(x: radius * sin(t), y: -dy)
            pts.append(pose.apply(local))
        }
        return pts
    }

    static func segments(def: PartDef, pose: Pose, flipped: Bool = false) -> [Seg] {
        let m = flipped ? -1.0 : 1.0   // 翻面：局部 y 镜像
        func pos(_ id: String) -> Vec2? {
            guard let pt = def.port(id) else { return nil }
            return Vec2(x: pt.x, y: pt.y * m)
        }
        switch def.family {
        case "straight", "bridge", "ramp":
            guard let a = pos("a"), let b = pos("b") else { return [] }
            return [.line(pose.apply(a), pose.apply(b))]

        case "curve":
            guard let bp = def.port("b"), let r = def.radius else { return [] }
            // 翻面后左右转互换
            let left = (bp.heading >= 0) != flipped
            return [.polyline(arcPoints(pose: pose, radius: r,
                                        sweepDeg: abs(bp.heading), left: left))]

        case "switch":
            guard let i = pos("in"), let s = pos("straight"),
                  let br = def.port("branch"), let r = def.branchRadius else { return [] }
            let left = (br.y >= 0) != flipped
            return [.line(pose.apply(i), pose.apply(s)),
                    .polyline(arcPoints(pose: pose, radius: r,
                                        sweepDeg: abs(br.heading), left: left))]

        case "cross":
            guard let w = pos("w"), let e = pos("e"),
                  let n = pos("n"), let s = pos("s") else { return [] }
            return [.line(pose.apply(w), pose.apply(e)),
                    .line(pose.apply(n), pose.apply(s))]

        case "buffer":
            guard let ap = def.port("a"), let len = def.length else { return [] }
            let start = pose.apply(pos("a") ?? Vec2(x: 0, y: 0))
            let ang = ap.headingRadians * m + .pi
            let dir = Vec2(x: cos(ang), y: sin(ang))
            let end = Vec2(x: start.x + dir.x * len, y: start.y + dir.y * len)
            let perp = Vec2(x: -dir.y, y: dir.x)
            return [.line(start, end),
                    .line(Vec2(x: end.x + perp.x * 14, y: end.y + perp.y * 14),
                          Vec2(x: end.x - perp.x * 14, y: end.y - perp.y * 14))]

        default:
            return []
        }
    }

    static func path(for segs: [Seg], toScreen: (Vec2) -> CGPoint) -> Path {
        var p = Path()
        for seg in segs {
            switch seg {
            case .line(let a, let b):
                p.move(to: toScreen(a))
                p.addLine(to: toScreen(b))
            case .polyline(let pts):
                guard let first = pts.first else { continue }
                p.move(to: toScreen(first))
                for pt in pts.dropFirst() { p.addLine(to: toScreen(pt)) }
            }
        }
        return p
    }

    static func points(of seg: Seg) -> [Vec2] {
        switch seg {
        case .line(let a, let b): return [a, b]
        case .polyline(let ps): return ps
        }
    }

    /// 把中心线段按法线方向向两侧偏移，用于绘制轨道两侧的凹槽线
    static func offsetSegs(from segs: [Seg], offsetMM: Double) -> [Seg] {
        var out: [Seg] = []
        for seg in segs {
            let pts = points(of: seg)
            guard pts.count >= 2 else { continue }
            for side in [-1.0, 1.0] {
                var off: [Vec2] = []
                for i in 0..<pts.count {
                    let prev = pts[max(i - 1, 0)]
                    let next = pts[min(i + 1, pts.count - 1)]
                    let dx = next.x - prev.x, dy = next.y - prev.y
                    let len = max((dx * dx + dy * dy).squareRoot(), 1e-9)
                    // 切向量 t=(dx,dy)/len，法线 n=(-ty, tx)
                    off.append(Vec2(x: pts[i].x - dy / len * offsetMM * side,
                                    y: pts[i].y + dx / len * offsetMM * side))
                }
                out.append(.polyline(off))
            }
        }
        return out
    }

    static func bounds(of segs: [Seg]) -> (min: Vec2, max: Vec2)? {
        var pts: [Vec2] = []
        for seg in segs {
            switch seg {
            case .line(let a, let b): pts.append(contentsOf: [a, b])
            case .polyline(let ps): pts.append(contentsOf: ps)
            }
        }
        guard let f = pts.first else { return nil }
        var lo = f, hi = f
        for p in pts {
            lo = Vec2(x: min(lo.x, p.x), y: min(lo.y, p.y))
            hi = Vec2(x: max(hi.x, p.x), y: max(hi.y, p.y))
        }
        return (lo, hi)
    }

    // MARK: - 实物端头（画布与托盘图标共用）
    // 和实物一样：公头端 = 凸出的圆点，母口端 = 带深度的缺口（U 形轮廓）

    /// 轨道实体外框（平端面，非圆头）：中心线两侧各偏移 halfWidthMM，端部直线封闭。
    /// 弯轨沿内外弧偏移，道岔每条股道单独成块。
    static func solidPath(for segs: [Seg], halfWidthMM: Double, toScreen: (Vec2) -> CGPoint) -> Path {
        var p = Path()
        for seg in segs {
            let off = offsetSegs(from: [seg], offsetMM: halfWidthMM)
            guard off.count >= 2,
                  case .polyline(let a) = off[0],
                  case .polyline(let b) = off[1] else { continue }
            p.move(to: toScreen(a[0]))
            for pt in a.dropFirst() { p.addLine(to: toScreen(pt)) }
            for pt in b.reversed() { p.addLine(to: toScreen(pt)) }
            p.closeSubpath()
        }
        return p
    }


    /// 在指定端口位姿处绘制实物端头（顶视图，标准钥匙孔榫卯尺寸）
    /// - polarity "M"：向外凸出的圆榫（颈部宽 6.75 + 球头 Ø12.25，球心距端面 11.90）
    /// - polarity "F"：切穿顶面的钥匙孔（圆孔 Ø12.75 孔心距端面 12.10 + 滑槽宽 7.25）
    static func drawJointEnd(_ ctx: inout GraphicsContext,
                             at joint: Vec2, heading: Double, polarity: String,
                             mmToPt: Double,
                             wood: Color, edge: Color,
                             toScreen: (Vec2) -> CGPoint) {
        let d = Vec2(x: cos(heading), y: sin(heading))    // 端面朝外
        let p = Vec2(x: -d.y, y: d.x)                     // 板宽方向

        if polarity == "M" {
            // 公头：向外凸出的圆榫，颈部与球头同色
            let peg = Color(red: 0.90, green: 0.74, blue: 0.47)
            let pegEdge = Color(red: 0.62, green: 0.46, blue: 0.19)
            let n1 = joint + d * 11.90                    // 球心
            var neck = Path()
            neck.move(to: toScreen(joint + p * 3.375))
            neck.addLine(to: toScreen(n1 + p * 3.375))
            neck.addLine(to: toScreen(n1 - p * 3.375))
            neck.addLine(to: toScreen(joint - p * 3.375))
            neck.closeSubpath()
            ctx.fill(neck, with: .color(peg))
            ctx.stroke(neck, with: .color(pegEdge), lineWidth: 1.2)
            let sc = toScreen(n1)
            let r = CGFloat(6.125 * mmToPt)
            let ball = Path(ellipseIn: CGRect(x: sc.x - r, y: sc.y - r,
                                              width: r * 2, height: r * 2))
            ctx.fill(ball, with: .color(peg))
            ctx.stroke(ball, with: .color(pegEdge), lineWidth: 1.2)
        } else {
            // 母口：深色钥匙孔开口（滑槽 + 圆孔，分开填充避免绕向相消）
            let dark = Color(red: 0.30, green: 0.22, blue: 0.10)
            let cIn = joint - d * 12.10                   // 孔心（向件体内）
            var slot = Path()
            slot.move(to: toScreen(joint + p * 3.625))
            slot.addLine(to: toScreen(cIn + p * 3.625))
            slot.addLine(to: toScreen(cIn - p * 3.625))
            slot.addLine(to: toScreen(joint - p * 3.625))
            slot.closeSubpath()
            ctx.fill(slot, with: .color(dark))
            let sc = toScreen(cIn)
            let r = CGFloat(6.375 * mmToPt)
            let hole = Path(ellipseIn: CGRect(x: sc.x - r, y: sc.y - r,
                                              width: r * 2, height: r * 2))
            ctx.fill(hole, with: .color(dark))
        }
    }

    /// 画出一个零件定义的所有端口端头（用于托盘缩略图，无翻转）
    static func drawAllJointEnds(_ ctx: inout GraphicsContext, def: PartDef,
                                 mmToPt: Double, wood: Color, edge: Color,
                                 toScreen: (Vec2) -> CGPoint) {
        for port in def.ports {
            drawJointEnd(&ctx, at: Vec2(x: port.x, y: port.y),
                         heading: port.headingRadians, polarity: port.polarity,
                         mmToPt: mmToPt, wood: wood, edge: edge, toScreen: toScreen)
        }
    }
}
