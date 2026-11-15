import SwiftUI
import UIKit

// MARK: - 斜角俯瞰装配图纸导出

/// 把当前装配体渲染成「斜角俯视」图纸 PNG（白底、带尺寸标注与标题栏），
/// 通过系统分享面板保存/发送，供线下装配参考。
enum DrawingExporter {

    private static let wood = UIColor(red: 0.86, green: 0.70, blue: 0.44, alpha: 1)
    private static let woodSide = UIColor(red: 0.58, green: 0.43, blue: 0.20, alpha: 1)
    private static let edge = UIColor(red: 0.32, green: 0.22, blue: 0.09, alpha: 1)
    private static let ink = UIColor(red: 0.15, green: 0.13, blue: 0.10, alpha: 1)

    /// 中心线采样点：mm 坐标 + 世界高度 + 横向法向
    private typealias Sample = (p: Vec2, l: Double, n: Vec2)

    /// 单个零件的绘制数据
    private struct PieceData {
        let def: PartDef
        let segs: [[Sample]]
        let level: (Vec2) -> Double
        let depth: Double                     // x+y，画家算法排序
        let label: String
        let labelPos: Vec2
        let ends: [EndMark]                   // 空闲端口的接口标记（公头/母口）
    }

    /// 端口端面：公头圆榫 / 母口钥匙孔
    private struct EndMark {
        let pos: Vec2
        let t: Vec2          // 端面朝外方向（端口朝向，与 2D 画布一致）
        let n: Vec2          // 端面横向（板宽方向）
        let level: Double
        let male: Bool
        let connected: Bool  // 已连接：公头榫插入对方母口，本侧不再可见
    }

    /// 桥墩绘制数据：抬离地面的接缝正下方一根
    private struct PierData {
        let joint: Vec2
        let level: Double
        let n: Vec2          // 轨道横向法向
        let depth: Double
    }

    static func renderImage(state: DemoState) -> UIImage {
        let W: CGFloat = 2000, H: CGFloat = 1560

        // 1. 收集零件数据（中心线采样 + 高度场）
        var connectedPorts = Set<String>()
        for c in state.assembly.connections {
            connectedPorts.insert("\(c.pieceA)-\(c.portA)")
            connectedPorts.insert("\(c.pieceB)-\(c.portB)")
        }
        var pieces: [PieceData] = []
        for pc in state.assembly.pieces {
            guard let def = state.assembly.def(pc.defID) else { continue }
            let segs = PieceGeometry.segments(def: def, pose: pc.pose, flipped: pc.flipped)

            var level: (Vec2) -> Double
            if def.family == "ramp",
               let wpa = state.assembly.worldPort(pc.id, "a"),
               let wpb = state.assembly.worldPort(pc.id, "b") {
                let wa = wpa.pose.position, wb = wpb.pose.position
                let d = wb - wa
                let len2 = d.x * d.x + d.y * d.y
                let la = wpa.worldLevel, lb = wpb.worldLevel
                level = { p in
                    guard len2 > 1e-9 else { return la }
                    var t = ((p.x - wa.x) * d.x + (p.y - wa.y) * d.y) / len2
                    t = max(0, min(1, t))
                    let s = t * t * (3 - 2 * t)   // smoothstep，与 3D 弧面一致
                    return la + (lb - la) * s
                }
            } else {
                let l = pc.baseLevel + (def.ports.map { $0.level }.max() ?? 0)
                level = { _ in l }
            }

            let sampled = segs.map { seg -> [Sample] in
                let pts = resample(PieceGeometry.points(of: seg), step: 8)
                return pts.enumerated().map { i, p in
                    let a = pts[max(i - 1, 0)], b = pts[min(i + 1, pts.count - 1)]
                    let d = b - a
                    let len = max(d.length, 1e-9)
                    return Sample(p: p, l: level(p), n: Vec2(x: -d.y / len, y: d.x / len))
                }
            }
            guard let b = PieceGeometry.bounds(of: segs) else { continue }
            let center = Vec2(x: (b.min.x + b.max.x) / 2, y: (b.min.y + b.max.y) / 2)

            // 端口端面标记：每个接头只呈现一个钥匙孔（母口侧），公头圆榫连接后
            // 插入对方母口内不再可见；未连接的公头端画出向外凸出的圆榫
            let ends = def.ports.compactMap { pt -> EndMark? in
                guard let wp = state.assembly.worldPort(pc.id, pt.id) else { return nil }
                let hd = wp.pose.heading
                return EndMark(pos: wp.pose.position,
                               t: Vec2(x: cos(hd), y: sin(hd)),
                               n: Vec2(x: -sin(hd), y: cos(hd)),
                               level: wp.worldLevel, male: wp.port.polarity == "M",
                               connected: connectedPorts.contains("\(pc.id)-\(pt.id)"))
            }

            pieces.append(PieceData(def: def, segs: sampled, level: level,
                                    depth: center.x + center.y,
                                    label: labelText(def), labelPos: center,
                                    ends: ends))
        }
        pieces.sort { $0.depth < $1.depth }   // 远的先画

        // 桥墩：与 3D 视图一致，每条抬离地面的接缝正下方一根
        var piers: [PierData] = []
        for conn in state.assembly.connections {
            guard let wa = state.assembly.worldPort(conn.pieceA, conn.portA),
                  wa.worldLevel > 10 else { continue }
            let hd = wa.pose.heading
            let j = wa.pose.position
            piers.append(PierData(joint: j, level: wa.worldLevel,
                                  n: Vec2(x: -sin(hd), y: cos(hd)),
                                  depth: j.x + j.y))
        }

        // 2. 计算斜角投影（x-y 为横向、(x+y)/2 为纵深、高度向上）并求缩放
        let zkRatio: Double = 0.8
        var minX = Double.greatestFiniteMagnitude, maxX = -minX
        var minY = Double.greatestFiniteMagnitude, maxY = -minX
        for p in pieces {
            for seg in p.segs {
                for s in seg {
                    let gx = Double(s.p.x - s.p.y)
                    let gy = Double(s.p.x + s.p.y) * 0.5 - s.l * zkRatio
                    minX = min(minX, gx); maxX = max(maxX, gx)
                    minY = min(minY, gy); maxY = max(maxY, gy)
                }
            }
        }
        let topMargin: CGFloat = 130, bottomMargin: CGFloat = 240, sideMargin: CGFloat = 70
        let availW = W - sideMargin * 2, availH = H - topMargin - bottomMargin
        let spanX = max(maxX - minX, 1), spanY = max(maxY - minY, 1)
        var k = min(Double(availW) / spanX, Double(availH) / spanY)
        k = min(k, 2.4)   // 小装配不放大过度
        let zk = k * zkRatio
        let ox = Double(sideMargin) + (Double(availW) - spanX * k) / 2 - minX * k
        let oy = Double(topMargin) + (Double(availH) - spanY * k) / 2 - minY * k

        func pt(_ p: Vec2, _ l: Double) -> CGPoint {
            CGPoint(x: ox + Double(p.x - p.y) * k,
                    y: oy + Double(p.x + p.y) * k * 0.5 - l * zk)
        }

        // 3. 渲染
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: W, height: H))
        return renderer.image { rctx in
            UIColor.white.setFill()
            rctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

            // 零件与桥墩统一排序绘制：桥墩是垫在轨道下面的结构，全部先画，
            // 避免柱身/托板画到轨道顶上变成"方块补丁"
            for pier in piers { drawPier(pier, pt: pt) }
            for p in pieces {
                drawPiece(p, pt: pt, k: k, zk: zk)
            }

            // 已连接接缝：横跨板宽的细缝线（真实拼接位置）
            for conn in state.assembly.connections {
                guard let wa = state.assembly.worldPort(conn.pieceA, conn.portA) else { continue }
                let hd = wa.pose.heading
                let n = Vec2(x: -sin(hd), y: cos(hd))
                let j = wa.pose.position
                let seam = UIBezierPath()
                seam.move(to: pt(j + n * 20, wa.worldLevel))
                seam.addLine(to: pt(j - n * 20, wa.worldLevel))
                edge.withAlphaComponent(0.55).setStroke()
                seam.lineWidth = 1.5
                seam.stroke()
            }

            // 标题栏
            let title = "木轨装配图纸 · 斜角俯视" as NSString
            title.draw(at: CGPoint(x: sideMargin, y: 34), withAttributes: [
                .font: UIFont.systemFont(ofSize: 36, weight: .bold),
                .foregroundColor: ink
            ])
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm"
            let s = state.assembly.stats
            let subtitle = "\(df.string(from: Date()))  ·  零件 \(s.pieces) · 连接 \(s.connections) · 缺口 \(s.gaps) · 闭环 \(s.closedLoops)" as NSString
            subtitle.draw(at: CGPoint(x: sideMargin, y: 84), withAttributes: [
                .font: UIFont.systemFont(ofSize: 20, weight: .medium),
                .foregroundColor: UIColor(red: 0.35, green: 0.32, blue: 0.28, alpha: 1)
            ])
            // 零件清单：每种模组顶部视图缩略图 + 名称 ×数量
            drawPartsList(rctx, state: state, W: W, H: H, sideMargin: sideMargin)

            // 底部说明
            let footer = "单位：毫米  ·  板宽 40  ·  轨距 19.5  ·  层高 64（桥面）  ·  圆榫=公头端  钥匙孔=母口端（Ø12.75 孔 + 7.25 滑槽）" as NSString
            footer.draw(at: CGPoint(x: sideMargin, y: H - 40), withAttributes: [
                .font: UIFont.systemFont(ofSize: 17, weight: .regular),
                .foregroundColor: UIColor(red: 0.45, green: 0.42, blue: 0.38, alpha: 1)
            ])
        }
    }

    // MARK: 零件清单带

    /// 图纸底部：按托盘顺序列出用到的每种模组——顶部视图缩略图 + 名称 ×数量
    private static func drawPartsList(_ rctx: UIGraphicsImageRendererContext,
                                      state: DemoState, W: CGFloat, H: CGFloat,
                                      sideMargin: CGFloat) {
        var counts: [String: Int] = [:]
        for pc in state.assembly.pieces { counts[pc.defID, default: 0] += 1 }
        guard !counts.isEmpty else { return }

        let listTop = H - 210
        // 标题 + 分隔线
        "零件清单".draw(at: CGPoint(x: sideMargin, y: listTop - 40), withAttributes: [
            .font: UIFont.systemFont(ofSize: 24, weight: .semibold),
            .foregroundColor: ink
        ])
        UIColor(white: 0.82, alpha: 1).setFill()
        rctx.fill(CGRect(x: sideMargin, y: listTop - 6, width: W - sideMargin * 2, height: 1.5))

        // 按托盘顺序排列，未入托盘的型号排后面
        let order = ["STR_54", "STR_108", "STR_144", "STR_216",
                     "CUR_E45", "CUR_E1_45", "SW_L", "BUFFER", "ASC_N"]
        let ids = order.filter { counts[$0] != nil }
            + counts.keys.filter { !order.contains($0) }.sorted()

        let boxW: CGFloat = 104, boxH: CGFloat = 60, pitch: CGFloat = 188
        // 全局统一比例：按最大的零件求缩放（实物相对比例，不各自放大）
        var maxW = 1.0, maxH = 1.0
        for id in ids {
            guard let def = state.assembly.def(id),
                  let bb = PieceGeometry.bounds(of: PieceGeometry.segments(def: def, pose: Pose(), flipped: false)) else { continue }
            maxW = max(maxW, bb.max.x - bb.min.x)
            maxH = max(maxH, bb.max.y - bb.min.y)
        }
        let commonScale = min(Double(boxW) / maxW, Double(boxH) / maxH) * 0.9
        var x = sideMargin
        for id in ids {
            guard let def = state.assembly.def(id), let count = counts[id] else { continue }
            drawThumbnail(rctx, def: def,
                          box: CGRect(x: x, y: listTop + 8, width: boxW, height: boxH),
                          scale: commonScale)
            let text = "\(def.name) ×\(count)" as NSString
            text.draw(at: CGPoint(x: x, y: listTop + 8 + boxH + 8), withAttributes: [
                .font: UIFont.systemFont(ofSize: 17, weight: .medium),
                .foregroundColor: ink
            ])
            x += pitch
            if x + pitch > W - sideMargin { break }   // 单行放不下就截止（当前型号库一行足够）
        }
    }

    /// 单个模组的顶部视图缩略图（与 2D 画布同款画法：侧壁 + 顶面 + 描边）。
    /// scale 为全局统一比例（实物相对大小，小弯轨不再被单独放大）
    private static func drawThumbnail(_ rctx: UIGraphicsImageRendererContext,
                                      def: PartDef, box: CGRect, scale: Double) {
        let segs = PieceGeometry.segments(def: def, pose: Pose(), flipped: false)
        guard let bb = PieceGeometry.bounds(of: segs) else { return }
        let s = scale
        let cx = Double(box.midX), cy = Double(box.midY)
        let offX = cx - (bb.min.x + (bb.max.x - bb.min.x) / 2) * s
        let offY = cy - (bb.min.y + (bb.max.y - bb.min.y) / 2) * s
        let toScreen: (Vec2) -> CGPoint = { CGPoint(x: $0.x * s + offX, y: $0.y * s + offY) }

        let side = UIBezierPath(cgPath: PieceGeometry.solidPath(for: segs, halfWidthMM: 22,
                                                                toScreen: toScreen).cgPath)
        let top = UIBezierPath(cgPath: PieceGeometry.solidPath(for: segs, halfWidthMM: 20,
                                                               toScreen: toScreen).cgPath)
        woodSide.setFill()
        side.fill()
        wood.setFill()
        top.fill()
        edge.setStroke()
        top.lineWidth = 1.5
        top.stroke()

        // 接口端头：公头凸榫 / 母口钥匙孔（与主图同款，俯视平面投影）
        let pt2D: (Vec2, Double) -> CGPoint = { p, _ in toScreen(p) }
        for port in def.ports {
            let hd = port.headingRadians
            let t = Vec2(x: cos(hd), y: sin(hd))
            let m = EndMark(pos: port.position,
                            t: t,
                            n: Vec2(x: -t.y, y: t.x),
                            level: 0,
                            male: port.polarity == "M",
                            connected: false)
            drawJointEnd(m, pt: pt2D, k: s, zk: 0)
        }
    }

    // MARK: 辅助

    /// 桥墩：黄色立柱（横向 20mm，与 3D 一致）从地面到轨道底面 + 顶部托板（52 顺轨 × 26 横轨）
    private static func drawPier(_ pier: PierData, pt: (Vec2, Double) -> CGPoint) {
        let pierYellow = UIColor(red: 0.82, green: 0.62, blue: 0.16, alpha: 1)
        let pierPath = UIBezierPath()
        pierPath.move(to: pt(pier.joint + pier.n * 10, pier.level - 12))
        pierPath.addLine(to: pt(pier.joint - pier.n * 10, pier.level - 12))
        pierPath.addLine(to: pt(pier.joint - pier.n * 10, 0))
        pierPath.addLine(to: pt(pier.joint + pier.n * 10, 0))
        pierPath.close()
        pierYellow.setFill()
        pierPath.fill()
        edge.setStroke()
        pierPath.lineWidth = 1.5
        pierPath.stroke()
        // 柱身明暗分割（伪立体）
        let shade = UIBezierPath()
        shade.move(to: pt(pier.joint, pier.level - 12))
        shade.addLine(to: pt(pier.joint - pier.n * 10, pier.level - 12))
        shade.addLine(to: pt(pier.joint - pier.n * 10, 0))
        shade.addLine(to: pt(pier.joint, 0))
        shade.close()
        UIColor(red: 0.70, green: 0.51, blue: 0.12, alpha: 1).setFill()
        shade.fill()
        // 顶部托板（贴在轨道底面 level-12，藏在板下只露边缘）
        let tDir = Vec2(x: pier.n.y, y: -pier.n.x)   // 顺轨方向
        let cap = UIBezierPath()
        cap.move(to: pt(pier.joint + tDir * 26 + pier.n * 13, pier.level - 12))
        cap.addLine(to: pt(pier.joint - tDir * 26 + pier.n * 13, pier.level - 12))
        cap.addLine(to: pt(pier.joint - tDir * 26 - pier.n * 13, pier.level - 12))
        cap.addLine(to: pt(pier.joint + tDir * 26 - pier.n * 13, pier.level - 12))
        cap.close()
        UIColor(red: 0.90, green: 0.70, blue: 0.24, alpha: 1).setFill()
        cap.fill()
        edge.setStroke()
        cap.lineWidth = 1.5
        cap.stroke()
    }

    /// 单个零件：侧壁 + 端面盖 + 顶面 + 描边 + 凹槽 + 接口端头 + 标注
    private static func drawPiece(_ p: PieceData, pt: @escaping (Vec2, Double) -> CGPoint,
                                  k: Double, zk: Double) {
        let thickness = 12.0   // 板厚 mm
        // 侧壁：逐段判断朝向观察者的一侧（投影中外向法线 x+y>0 为正面）
        for seg in p.segs { drawSideWalls(seg, pt: pt, thickness: thickness) }
        // 端面盖：朝向观察者的零件端头竖直面
        for seg in p.segs { drawEndCaps(seg, pt: pt, thickness: thickness) }
        // 顶面
        for seg in p.segs { drawRibbon(seg, pt: pt, offsetMM: 0, color: wood) }
        // 描边
        edge.setStroke()
        for seg in p.segs {
            let outline = UIBezierPath()
            let left = seg.map { pt($0.p + $0.n * 20, $0.l) }
            let right = seg.map { pt($0.p - $0.n * 20, $0.l) }
            outline.move(to: left[0])
            left.dropFirst().forEach { outline.addLine(to: $0) }
            right.reversed().forEach { outline.addLine(to: $0) }
            outline.close()
            outline.lineWidth = 2
            outline.stroke()
        }
        // 凹槽：中心线两侧 ±9.75mm
        for seg in p.segs {
            for side in [-9.75, 9.75] {
                let gpath = UIBezierPath()
                var first = true
                for s in seg {
                    let q = pt(s.p + s.n * side, s.l)
                    if first { gpath.move(to: q); first = false }
                    else { gpath.addLine(to: q) }
                }
                gpath.lineWidth = max(3, 4.5 * CGFloat(k))
                gpath.lineCapStyle = .round
                gpath.stroke()
            }
        }
        // 端口接口：公头圆榫 / 母口钥匙孔（按实物标准尺寸）
        for m in p.ends { drawJointEnd(m, pt: pt, k: k, zk: zk) }
        // 标注：名称 + 主要尺寸（顶面上方）
        let c = pt(p.labelPos, p.level(p.labelPos))
        let text = p.label as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: max(15, 17 * CGFloat(k) / 1.2), weight: .semibold),
            .foregroundColor: ink
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: c.x - size.width / 2,
                              y: c.y - size.height - 10), withAttributes: attrs)
    }

    /// 侧壁：逐段画朝向观察者一侧的竖直面（外向法线 x+y>0 为正面）
    private static func drawSideWalls(_ seg: [Sample], pt: (Vec2, Double) -> CGPoint,
                                      thickness: Double) {
        guard seg.count >= 2 else { return }
        woodSide.setFill()
        for i in 0..<(seg.count - 1) {
            let s0 = seg[i], s1 = seg[i + 1]
            let n = Vec2(x: (s0.n.x + s1.n.x) / 2, y: (s0.n.y + s1.n.y) / 2)
            let u = (n.x + n.y) > 0 ? n : Vec2(x: -n.x, y: -n.y)
            let path = UIBezierPath()
            path.move(to: pt(s0.p + u * 20, s0.l))
            path.addLine(to: pt(s1.p + u * 20, s1.l))
            path.addLine(to: pt(s1.p + u * 20, s1.l - thickness))
            path.addLine(to: pt(s0.p + u * 20, s0.l - thickness))
            path.close()
            path.fill()
        }
    }

    /// 端面盖：零件端头朝向观察者的竖直面（切向 x+y>0 才可见，背面的被本体遮挡）
    private static func drawEndCaps(_ seg: [Sample], pt: (Vec2, Double) -> CGPoint,
                                    thickness: Double) {
        guard seg.count >= 2, let s0 = seg.first, let s1 = seg.last else { return }
        let capColor = UIColor(red: 0.50, green: 0.37, blue: 0.17, alpha: 1)
        let ends = [(s0, (seg[1].p - seg[0].p)), (s1, (seg[seg.count - 1].p - seg[seg.count - 2].p))]
        capColor.setFill()
        for (s, d) in ends {
            let len = max(d.length, 1e-9)
            let t = Vec2(x: d.x / len, y: d.y / len)
            guard (t.x + t.y) > 0 else { continue }
            let path = UIBezierPath()
            path.move(to: pt(s.p + s.n * 20, s.l))
            path.addLine(to: pt(s.p - s.n * 20, s.l))
            path.addLine(to: pt(s.p - s.n * 20, s.l - thickness))
            path.addLine(to: pt(s.p + s.n * 20, s.l - thickness))
            path.close()
            path.fill()
        }
    }

    /// 端口端头（顶视图，按实物标准尺寸图纸绘制）：
    /// 母口 SLOT = Ø12.75 圆孔 + 宽 7.25 滑槽（孔心距端面 12.10），切穿顶面 → 深色钥匙孔；
    /// 已连接时孔内画出坐入的公头球头（Ø12.25，浅色，孔缘留深色一圈）
    /// 公头 LUG = Ø12.25 球头 + 宽 6.75 颈部，球心距端面 11.90 **朝外凸出**；
    /// 已连接的公头端不画（榫已插入对方母口，被板体遮挡）
    private static func drawJointEnd(_ m: EndMark, pt: @escaping (Vec2, Double) -> CGPoint,
                                     k: Double, zk: Double) {
        // 顶面平面上的点：(u 沿板宽方向 n，d 自端面沿 -t 向件体内伸入，d<0 为朝外)
        let q = { (u: Double, d: Double) in pt(m.pos + m.n * u - m.t * d, m.level) }
        // 顶面圆的投影椭圆基（n、t 两方向）
        func circlePath(centerU: Double, centerD: Double, r: Double) -> UIBezierPath {
            let c = q(centerU, centerD)
            let ex = (m.n.x - m.n.y) * r * k
            let ey = (m.n.x + m.n.y) * 0.5 * r * k
            let fx = (m.t.x - m.t.y) * r * k
            let fy = (m.t.x + m.t.y) * 0.5 * r * k
            let path = UIBezierPath()
            for i in 0..<24 {
                let a = Double(i) / 24 * 2 * Double.pi
                let p = CGPoint(x: c.x + ex * cos(a) + fx * sin(a),
                                y: c.y + ey * cos(a) + fy * sin(a))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.close()
            return path
        }
        // 滑槽矩形（从端面伸到深度 d，d<0 为朝外凸出）
        func slotPath(width: Double, depth: Double) -> UIBezierPath {
            let path = UIBezierPath()
            path.move(to: q(-width / 2, 0))
            path.addLine(to: q(width / 2, 0))
            path.addLine(to: q(width / 2, depth))
            path.addLine(to: q(-width / 2, depth))
            path.close()
            return path
        }
        // 已连接的公头端：圆榫插在对方母口里，本侧顶面就是普通板端
        if m.male && m.connected { return }
        if m.male {
            // 未连接公头：向外凸出的圆榫——位于板厚中层（顶面下 6mm），
            // 下层再画一层同形深色（板底面高度），呈现立体厚度而不是贴在顶面的一层
            let peg = UIColor(red: 0.90, green: 0.74, blue: 0.47, alpha: 1)
            let pegEdge = UIColor(red: 0.62, green: 0.46, blue: 0.19, alpha: 1)
            let qm = { (u: Double, d: Double) in pt(m.pos + m.n * u - m.t * d, m.level - 6) }
            let qb = { (u: Double, d: Double) in pt(m.pos + m.n * u - m.t * d, m.level - 12) }
            // 圆的投影椭圆基（n、t 方向，高度由 q 决定）
            func ellipse(at c: CGPoint, r: Double) -> UIBezierPath {
                let ex = (m.n.x - m.n.y) * r * k
                let ey = (m.n.x + m.n.y) * 0.5 * r * k
                let fx = (m.t.x - m.t.y) * r * k
                let fy = (m.t.x + m.t.y) * 0.5 * r * k
                let path = UIBezierPath()
                for i in 0..<24 {
                    let a = Double(i) / 24 * 2 * Double.pi
                    let p = CGPoint(x: c.x + ex * cos(a) + fx * sin(a),
                                    y: c.y + ey * cos(a) + fy * sin(a))
                    if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                path.close()
                return path
            }
            func rect(_ q: (Double, Double) -> CGPoint, width: Double, depth: Double) -> UIBezierPath {
                let path = UIBezierPath()
                path.move(to: q(-width / 2, 0))
                path.addLine(to: q(width / 2, 0))
                path.addLine(to: q(width / 2, depth))
                path.addLine(to: q(-width / 2, depth))
                path.close()
                return path
            }
            // 底层（板底高度，深色）→ 中层（板厚中间，浅木色）
            for (qq, color) in [(qb, pegEdge), (qm, peg)] {
                let neck = rect(qq, width: 6.75, depth: -11.90)
                color.setFill()
                neck.fill()
                pegEdge.setStroke()
                neck.lineWidth = 1.2
                neck.stroke()
                let ball = ellipse(at: qq(0, -11.90), r: 6.125)
                color.setFill()
                ball.fill()
                pegEdge.setStroke()
                ball.lineWidth = 1.2
                ball.stroke()
            }
        } else {
            // 母口：切穿顶面的钥匙孔开口（圆孔 + 滑槽）——孔壁深色，
            // 再把孔底（下沉 8mm 的投影偏移）裁剪进开口，形成立体凹陷感
            let wall = UIColor(red: 0.30, green: 0.22, blue: 0.10, alpha: 1)
            let floor = UIColor(red: 0.40, green: 0.30, blue: 0.14, alpha: 1)
            let slot = slotPath(width: 7.25, depth: 12.10)
            let hole = circlePath(centerU: 0, centerD: 12.10, r: 6.375)
            wall.setFill()
            slot.fill()
            hole.fill()
            if let cg = UIGraphicsGetCurrentContext() {
                let dz = CGFloat(8.0 * zk)
                for p in [slot, hole] {
                    cg.saveGState()
                    p.addClip()
                    cg.translateBy(x: 0, y: dz)
                    floor.setFill()
                    p.fill()
                    cg.restoreGState()
                }
            }
        }
    }

    /// 采样点折线 → 色带多边形（offsetMM=0 为顶面；-12 为底部厚度层）
    private static func drawRibbon(_ seg: [Sample], pt: (Vec2, Double) -> CGPoint,
                                   offsetMM: Double, color: UIColor) {
        guard seg.count >= 2 else { return }
        let left = seg.map { pt($0.p + $0.n * 20, $0.l + offsetMM) }
        let right = seg.map { pt($0.p - $0.n * 20, $0.l + offsetMM) }
        let path = UIBezierPath()
        path.move(to: left[0])
        left.dropFirst().forEach { path.addLine(to: $0) }
        right.reversed().forEach { path.addLine(to: $0) }
        path.close()
        color.setFill()
        path.fill()
    }

    private static func resample(_ pts: [Vec2], step: Double) -> [Vec2] {
        guard pts.count >= 2 else { return pts }
        var out: [Vec2] = []
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let d = b - a
            let len = d.length
            guard len > 1e-9 else { continue }
            let n = max(1, Int(len / step))
            for k in 0..<n { out.append(a + d * (Double(k) / Double(n))) }
        }
        out.append(pts.last!)
        return out
    }

    private static func labelText(_ def: PartDef) -> String {
        var dim = ""
        if let l = def.length {
            dim = "\(Int(l))mm"
        } else if let r = def.radius, let a = def.geometry["angle"] {
            dim = "R\(Int(r)) · \(Int(a))°"
        } else if let bs = def.geometry["base_straight"] {
            dim = "直段\(Int(bs))mm"
        }
        return dim.isEmpty ? def.name : "\(def.name) \(dim)"
    }
}

// MARK: - 相册保存回调（UIImageWriteToSavedPhotosAlbum 要求 NSObject 目标）

final class PhotoSaver: NSObject {
    private let onDone: (String) -> Void

    init(onDone: @escaping (String) -> Void) {
        self.onDone = onDone
    }

    @objc func image(_ image: UIImage,
                     didFinishSavingWithError error: Error?,
                     contextInfo: UnsafeRawPointer) {
        onDone(error == nil ? "图纸已保存到相册" : "保存失败：\(error?.localizedDescription ?? "未知错误")")
    }
}
