import SwiftUI

struct CanvasAreaView: View {
    @ObservedObject var state: DemoState
    // 长按删除检测（定时器方案：按下即计时，不依赖移动事件）
    @State private var pressAnchor: CGPoint?
    @State private var pressTask: Task<Void, Never>?
    @State private var longPressFired = false   // 本次触摸已弹出气泡（手指还按着，别把气泡关掉）
    // 画布平移：空白处拖动移动视图
    @State private var panLast: CGPoint?        // 平移中：上一采样点
    @State private var touchStart: CGPoint?     // 本次触摸起点（双击检测用）
    @State private var lastTapDate: Date?

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                draw(&ctx, size: size)
            }
            .overlay {
                deleteBubble
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { g in
                        // 触发气泡的那根手指还按着：忽略它的后续事件，保持气泡
                        if longPressFired { return }
                        // 气泡存在 + 新的一次触碰 → 关闭气泡
                        if state.pendingDelete != nil {
                            state.cancelDelete()
                            cancelPress()
                            return
                        }
                        // 未选中待放置零件：空白处拖动 = 平移画布；原地按住 = 长按检测
                        if state.selectedDefID == nil {
                            if let anchor = pressAnchor {
                                // 手指移动出容差 → 取消长按，转入平移
                                if hypot(g.location.x - anchor.x, g.location.y - anchor.y) > 18 {
                                    cancelPress()
                                    panLast = g.location
                                }
                            } else if let last = panLast {
                                // 平移中：跟随手指
                                state.panBy(dx: g.location.x - last.x, dy: g.location.y - last.y)
                                panLast = g.location
                            } else {
                                touchStart = g.location
                                beginPress(at: g.location)
                            }
                            return
                        }
                        guard let sel = state.selectedDefID else { return }
                        state.updateDragFromCanvas(defID: sel, point: g.location)
                    }
                    .onEnded { g in
                        // 原地快速双击空白处 → 画布回中
                        if let s = touchStart,
                           hypot(g.location.x - s.x, g.location.y - s.y) < 8 {
                            let now = Date()
                            if let last = lastTapDate, now.timeIntervalSince(last) < 0.35 {
                                state.resetPan()
                                lastTapDate = nil
                            } else {
                                lastTapDate = now
                            }
                        }
                        touchStart = nil
                        cancelPress()
                        panLast = nil
                        longPressFired = false
                        state.endDrag()
                    }
            )
            .onAppear {
                state.canvasSize = geo.size
                state.canvasFrame = geo.frame(in: .global)
            }
            .onChange(of: geo.size) { _, new in
                state.canvasSize = new
                state.canvasFrame = geo.frame(in: .global)
            }
        }
    }

    /// 按下瞬间启动 1 秒定时器；期间手指移动出容差则取消
    private func beginPress(at location: CGPoint) {
        pressAnchor = location
        pressTask?.cancel()
        pressTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let anchor = pressAnchor else { return }
            pressAnchor = nil
            longPressFired = true   // 气泡弹出后手指可能还按着，屏蔽同指后续事件
            state.requestDelete(at: anchor, canvasSize: state.canvasSize)
        }
    }

    private func cancelPress() {
        pressAnchor = nil
        pressTask?.cancel()
        pressTask = nil
    }

    /// 长按后出现的操作气泡
    @ViewBuilder
    private var deleteBubble: some View {
        if let pd = state.pendingDelete {
            let size = state.canvasSize
            let px = min(max(pd.screenPoint.x, 110), max(size.width - 110, 110))
            let py = min(max(pd.screenPoint.y - 60, 90), max(size.height - 90, 90))
            VStack(spacing: 12) {
                Text("「\(pd.name)」")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
                HStack(spacing: 10) {
                    if let flipLabel = pd.flipLabel {
                        Button {
                            state.flipPiece(pd.pieceID)
                        } label: {
                            Text(flipLabel)
                                .font(.system(size: 14, weight: .semibold))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.blue.opacity(0.85))
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        state.confirmDelete()
                    } label: {
                        Text("删除")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.red.opacity(0.85))
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14)
                .fill(Color(red: 0.16, green: 0.15, blue: 0.13))
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
            .position(x: px, y: py)
        }
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        drawGrid(&ctx, size: size)

        // 实物配色：浅桦木顶面 / 侧壁暗色 / 深凹槽 / 深棕线稿
        let wood = Color(red: 0.86, green: 0.70, blue: 0.44)
        let woodDark = Color(red: 0.32, green: 0.22, blue: 0.09)

        // 已放置的轨道：按真实比例的板身 + 凹槽（多层立体写实画法）
        // 高度低的先画、高的后画：交叉/穿桥时上层轨道遮住下层（与 3D 一致）
        let levelOf: (PlacedPiece) -> Double = { pc in
            let ids = state.assembly.def(pc.defID)?.ports.map { $0.id } ?? []
            let ls = ids.compactMap { state.assembly.worldPort(pc.id, $0)?.worldLevel }
            guard !ls.isEmpty else { return pc.baseLevel }
            return ls.reduce(0, +) / Double(ls.count)
        }
        let orderedPieces = state.assembly.pieces.enumerated().sorted { l, r in
            let a = levelOf(l.element), b = levelOf(r.element)
            return a == b ? l.offset < r.offset : a < b   // 同高保持摆放顺序（稳定）
        }
        for piece in orderedPieces.map({ $0.element }) {
            guard let def = state.assembly.def(piece.defID) else { continue }
            let segs = PieceGeometry.segments(def: def, pose: piece.pose, flipped: piece.flipped)
            drawTrackBody(&ctx, segs: segs, size: size,
                          bodyColor: wood,
                          grooveColor: woodDark,
                          drawGrooves: def.family != "buffer")
            // 爬坡轨：画坡度指示箭头（指向高端口）
            if def.family == "ramp" {
                drawSlopeArrows(&ctx, piece: piece, def: def, size: size, color: woodDark)
            }
        }

        // 连接接口示意：公头收窄颈部 + 突出圆头榫，压入母口端面缺口
        drawJointMarkers(&ctx, size: size, woodColor: wood, edgeColor: woodDark)

        // 拖拽时：兼容端口才显示蓝色吸附提示环（平时不画，端头形状已标明端口位置）
        if let d = state.drag {
            for fp in state.assembly.freePorts() where state.dragCompatible(defID: d.defID, with: fp) {
                let p = state.screenPoint(fp.pose.position, canvasSize: size)
                let r: CGFloat = 8
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                         with: .color(Color.blue.opacity(0.55)))
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r - 3, y: p.y - r - 3,
                                                  width: (r + 3) * 2, height: (r + 3) * 2)),
                           with: .color(Color.blue.opacity(0.5)), lineWidth: 1.5)
            }
        }

        // 拖拽幽灵件
        if let d = state.drag, let def = state.assembly.def(d.defID) {
            let snapPose: Pose?
            if let s = d.snap {
                snapPose = s.pose
            } else {
                snapPose = nil
            }
            let pose = snapPose ?? Pose(x: d.pointMM.x - d.centerOffset.x,
                                        y: d.pointMM.y - d.centerOffset.y, headingDegrees: 0)
            let segs = PieceGeometry.segments(def: def, pose: pose)
            let color = snapPose != nil ? Color.blue : Color.gray
            drawTrackBody(&ctx, segs: segs, size: size,
                          bodyColor: color.opacity(snapPose != nil ? 0.45 : 0.25),
                          grooveColor: color.opacity(snapPose != nil ? 0.9 : 0.5),
                          dashed: snapPose == nil,
                          drawGrooves: def.family != "buffer")
            // 爬坡轨幽灵件：坡向箭头——吸附采用翻面变体时坡向自动反向，拖动中即可确认
            if def.family == "ramp" {
                let flipped = d.snap?.rampFlipped ?? false
                let levelSum = def.ports.reduce(0.0) { $0 + $1.level }
                let eff = def.ports.map { (flipped ? levelSum - $0.level : $0.level, $0.position) }
                if let lo = eff.min(by: { $0.0 < $1.0 }),
                   let hi = eff.max(by: { $0.0 < $1.0 }),
                   hi.0 > lo.0 {
                    drawSlopeIndicator(&ctx, from: pose.apply(lo.1), to: pose.apply(hi.1),
                                       size: size, rise: Int((hi.0 - lo.0).rounded()),
                                       color: .white.opacity(0.95))
                }
            }
        }
    }

    /// 按实物外框绘制轨道实体：两侧平行直边 + 平直端面（非圆头描边）
    /// ① 外扩 2mm 暗色侧壁 → ② 浅木顶面实体 → ③ 有宽度的深凹槽 + 槽底暗缝
    private func drawTrackBody(_ ctx: inout GraphicsContext, segs: [Seg], size: CGSize,
                               bodyColor: Color,
                               grooveColor: Color,
                               dashed: Bool = false,
                               drawGrooves: Bool = true) {
        let toScreen: (Vec2) -> CGPoint = { state.screenPoint($0, canvasSize: size) }
        let halfW = DemoState.trackWidthMM / 2

        let side = PieceGeometry.solidPath(for: segs, halfWidthMM: halfW + 2, toScreen: toScreen)
        let top = PieceGeometry.solidPath(for: segs, halfWidthMM: halfW, toScreen: toScreen)

        if dashed {
            // 拖拽幽灵件：半透明实体 + 虚线轮廓
            ctx.fill(side, with: .color(bodyColor.opacity(0.5)))
            ctx.fill(top, with: .color(bodyColor))
            ctx.stroke(top, with: .color(grooveColor),
                       style: StrokeStyle(lineWidth: 1.5, dash: [10, 7]))
        } else {
            // ① 侧壁暗色 ② 顶面浅木
            ctx.fill(side, with: .color(Color(red: 0.58, green: 0.43, blue: 0.20)))
            ctx.fill(top, with: .color(bodyColor))
        }

        guard drawGrooves else { return }
        let grooves = PieceGeometry.offsetSegs(from: segs, offsetMM: DemoState.grooveOffsetMM)
        let gp = PieceGeometry.path(for: grooves, toScreen: toScreen)
        var gStyle = StrokeStyle(lineWidth: 5 * DemoState.scale, lineCap: .butt, lineJoin: .round)
        if dashed { gStyle.dash = [6, 5] }
        // ③ 凹槽：5mm 宽深棕槽，中央叠一道更暗的槽底缝
        ctx.stroke(gp, with: .color(grooveColor), style: gStyle)
        if !dashed {
            ctx.stroke(gp, with: .color(Color(red: 0.15, green: 0.10, blue: 0.04)),
                       style: StrokeStyle(lineWidth: 1.6, lineCap: .butt, lineJoin: .round))
        }
    }

    /// 实物端头：散开端口按极性画——公头端凸出圆点，母口端缺口
    /// 已连接处画一条横跨板宽的细接缝线，体现两段轨道拼接处
    private func drawJointMarkers(_ ctx: inout GraphicsContext, size: CGSize,
                                  woodColor: Color, edgeColor: Color) {
        let toScreen: (Vec2) -> CGPoint = { state.screenPoint($0, canvasSize: size) }

        // 已连接的接缝：细线横跨板宽
        for conn in state.assembly.connections {
            guard let wa = state.assembly.worldPort(conn.pieceA, conn.portA) else { continue }
            let joint = wa.pose.position
            let d = Vec2(x: cos(wa.pose.heading), y: sin(wa.pose.heading))
            let p = Vec2(x: -d.y, y: d.x)
            var seam = Path()
            seam.move(to: toScreen(Vec2(x: joint.x + p.x * 20, y: joint.y + p.y * 20)))
            seam.addLine(to: toScreen(Vec2(x: joint.x - p.x * 20, y: joint.y - p.y * 20)))
            ctx.stroke(seam, with: .color(edgeColor.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .butt))
        }

        for fp in state.assembly.freePorts() {
            PieceGeometry.drawJointEnd(&ctx,
                                       at: fp.pose.position,
                                       heading: fp.pose.heading,
                                       polarity: fp.port.polarity,
                                       mmToPt: DemoState.scale,
                                       wood: woodColor, edge: edgeColor,
                                       toScreen: toScreen)
        }
    }

    /// 爬坡轨坡度指示：单个箭头指向高端口（无锯齿）
    private func drawSlopeArrows(_ ctx: inout GraphicsContext, piece: PlacedPiece,
                                 def: PartDef, size: CGSize, color: Color) {
        // 高度走 worldPort（含反向后的高低互换），箭头始终指向世界高度更高的一端
        guard let wpa = state.assembly.worldPort(piece.id, "a"),
              let wpb = state.assembly.worldPort(piece.id, "b"),
              abs(wpb.worldLevel - wpa.worldLevel) > 0.5 else { return }
        let highIsA = wpa.worldLevel > wpb.worldLevel
        drawSlopeIndicator(&ctx, from: (highIsA ? wpb : wpa).pose.position,
                           to: (highIsA ? wpa : wpb).pose.position,
                           size: size,
                           rise: Int((wpb.worldLevel - wpa.worldLevel).magnitude.rounded()),
                           color: color)
    }

    /// 坡向箭头 + 高度差标注（从低端指向高端），已放置件与拖拽幽灵件共用
    private func drawSlopeIndicator(_ ctx: inout GraphicsContext, from lowMM: Vec2, to highMM: Vec2,
                                    size: CGSize, rise: Int, color: Color) {
        let d = highMM - lowMM
        let len = d.length
        guard len > 1e-6 else { return }
        let u = Vec2(x: d.x / len, y: d.y / len)        // 指向高端口
        let perp = Vec2(x: -u.y, y: u.x)
        let toScreen: (Vec2) -> CGPoint = { state.screenPoint($0, canvasSize: size) }

        // 中点一个箭头，指向高端口
        let base = Vec2(x: lowMM.x + d.x * 0.5, y: lowMM.y + d.y * 0.5)
        let tip = Vec2(x: base.x + u.x * 7, y: base.y + u.y * 7)
        var arrow = Path()
        arrow.move(to: toScreen(Vec2(x: tip.x - u.x * 10 + perp.x * 9, y: tip.y - u.y * 10 + perp.y * 9)))
        arrow.addLine(to: toScreen(tip))
        arrow.addLine(to: toScreen(Vec2(x: tip.x - u.x * 10 - perp.x * 9, y: tip.y - u.y * 10 - perp.y * 9)))
        ctx.stroke(arrow, with: .color(color),
                   style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

        // 高度差标注（如 ↑64），放在箭头旁，翻转/反向后自动跟随
        let labelPos = Vec2(x: base.x - perp.x * 16, y: base.y - perp.y * 16)
        ctx.draw(Text("↑\(rise)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.9)),
                 at: toScreen(labelPos))
    }

    private func drawGrid(_ ctx: inout GraphicsContext, size: CGSize) {
        var dots = Path()
        let step: CGFloat = 32
        // 网格跟随画布平移（取模平铺）
        let ox = (-CGFloat(state.panOffset.x) * DemoState.scale)
            .truncatingRemainder(dividingBy: step)
        let oy = (CGFloat(state.panOffset.y) * DemoState.scale)
            .truncatingRemainder(dividingBy: step)
        var x = (step / 2 + ox).truncatingRemainder(dividingBy: step)
        if x < 0 { x += step }
        while x < size.width {
            var y = (step / 2 + oy).truncatingRemainder(dividingBy: step)
            if y < 0 { y += step }
            while y < size.height {
                dots.addRect(CGRect(x: x, y: y, width: 1.3, height: 1.3))
                y += step
            }
            x += step
        }
        ctx.fill(dots, with: .color(.white.opacity(0.08)))
    }
}
