import SwiftUI
import UIKit

/// Demo 状态：装配体 + 拖拽吸附 + 撤销
final class DemoState: ObservableObject {
    static let scale: Double = 0.8            // mm → pt
    static let snapThresholdMM: Double = 90   // 吸附半径
    static let trackWidthMM: Double = 40      // 真实轨道板宽
    static let grooveOffsetMM: Double = 9.75  // 凹槽中心到板中心线的距离（轨距约19.5mm）
    static let liftOffset: CGFloat = 0       // 拖拽幽灵件相对指尖的抬升量（0 = 零件中心正贴指尖）

    let library: PartLibrary
    @Published private(set) var assembly: Assembly
    @Published private(set) var drag: DragState?
    @Published var canvasSize: CGSize = .zero
    @Published var selectedDefID: String?     // 托盘单击选中，等待画布放置
    @Published var pendingDelete: PendingDelete?  // 长按命中的待删除零件
    @Published var show3D = false                 // 3D 预览模式
    @Published var toast: String?                 // 轻提示（如"已保存到相册"）
    var canvasFrame: CGRect = .zero           // 画布在屏幕上的全局 frame

    /// 相册保存回调持有者（UIImageWriteToSavedPhotosAlbum 要求 NSObject 目标）
    private var photoSaver: PhotoSaver?

    struct PendingDelete {
        let pieceID: UUID
        let screenPoint: CGPoint
        let name: String
        let canFlip: Bool
        /// 翻转按钮文案：弯轨/道岔=「翻转」（镜像），爬坡轨=「调头」（高低端互换）
        let flipLabel: String?
    }

    private var history: [Assembly] = []

    struct DragState {
        let defID: String
        let pointMM: Vec2
        let snap: SnapCandidate?
        /// 零件包围盒中心相对原点的偏移——幽灵件以此偏移让「零件中心」跟手
        let centerOffset: Vec2
    }

    struct SnapCandidate {
        let parentPieceID: UUID
        let parentPortID: String
        let childPortID: String
        let pose: Pose
        let distance: Double
        /// 爬坡轨翻面变体（高低端互换、脚印不变）：正放接不上而翻面能接上时自动采用
        let rampFlipped: Bool
    }

    init() {
        let lib = (try? PartLibrary.load()) ?? PartLibrary(parts: [])
        self.library = lib
        var a = Assembly(library: lib)
        _ = a.place(defID: "STR_144", pose: Pose())
        self.assembly = a
    }

    // MARK: 坐标换算（自动居中 + 手动平移）

    /// 手动平移量（mm）；双击空白处回中
    @Published var panOffset: Vec2 = Vec2(x: 0, y: 0)
    /// 手动平移后冻结自动居中，避免画到边缘时视图中心被装配体包围盒拽回去
    private var frozenCenter: Vec2?

    private var autoCenter: Vec2 {
        if let b = assembly.portBounds() {
            return Vec2(x: (b.min.x + b.max.x) / 2, y: (b.min.y + b.max.y) / 2)
        }
        return Vec2(x: 72, y: 80)
    }

    var viewportCenter: Vec2 {
        if let f = frozenCenter { return f + panOffset }
        return autoCenter + panOffset
    }

    /// 画布平移：屏幕 pt 位移 → mm 位移（屏幕 y 向下、mm y 向上）
    func panBy(dx: CGFloat, dy: CGFloat) {
        if frozenCenter == nil { frozenCenter = autoCenter }
        panOffset = panOffset + Vec2(x: -Double(dx) / Self.scale, y: Double(dy) / Self.scale)
    }

    /// 冻结当前视口中心（翻转/删除等会改变包围盒的操作前调用，避免视图被自动居中拽动）
    func freezeViewport() {
        if frozenCenter == nil { frozenCenter = autoCenter }
    }

    /// 双击空白处：清除平移并恢复自动居中
    func resetPan() {
        panOffset = Vec2(x: 0, y: 0)
        frozenCenter = nil
    }

    func screenPoint(_ p: Vec2, canvasSize size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + (p.x - viewportCenter.x) * Self.scale,
                y: size.height / 2 - (p.y - viewportCenter.y) * Self.scale)
    }

    private func toMM(_ point: CGPoint, canvasSize size: CGSize) -> Vec2 {
        Vec2(x: (Double(point.x) - Double(size.width) / 2) / Self.scale + viewportCenter.x,
             y: -(Double(point.y) - Double(size.height) / 2) / Self.scale + viewportCenter.y)
    }

    // MARK: 拖拽吸附

    /// 托盘拖拽入口：全局屏幕坐标 → 画布坐标（含指尖上方抬升）
    /// 手指在托盘区域内移动时不激活放置（留给滚动），进入画布才出现零件
    func updateDragGlobal(defID: String, globalPoint: CGPoint) {
        let canvasPoint = CGPoint(x: globalPoint.x - canvasFrame.origin.x,
                                  y: globalPoint.y - canvasFrame.origin.y - Self.liftOffset)
        let fingerInCanvas = canvasFrame.contains(
            CGPoint(x: globalPoint.x, y: globalPoint.y - Self.liftOffset))
        guard fingerInCanvas else {
            if drag != nil { drag = nil }   // 拖回托盘时撤销幽灵
            return
        }
        updateDrag(defID: defID, point: canvasPoint, canvasSize: canvasSize)
    }

    /// 托盘单击选中：之后在画布上任意位置拖动即可放置
    func selectForPlacement(_ defID: String) {
        selectedDefID = (selectedDefID == defID) ? nil : defID
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// 画布拖拽入口：画布本地坐标
    func updateDragFromCanvas(defID: String, point: CGPoint) {
        updateDrag(defID: defID, point: point, canvasSize: canvasSize)
    }

    func dragCompatible(defID: String, with port: WorldPort) -> Bool {
        guard let def = assembly.def(defID) else { return false }
        let minLevel = def.ports.map { $0.level }.min() ?? 0
        // 极性相对，且接上后零件不能低于地面
        return def.ports.contains { cp in
            cp.polarity != port.port.polarity
                && (port.worldLevel - cp.level) + minLevel >= -0.5
        }
    }

    func updateDrag(defID: String, point: CGPoint, canvasSize size: CGSize) {
        let mm = toMM(point, canvasSize: size)
        var snap: SnapCandidate?
        // 零件中心偏移：包围盒中心跟随手指（而不是零件原点）
        var centerOffset = Vec2(x: 0, y: 0)
        if let def = assembly.def(defID),
           let b = PieceGeometry.bounds(of: PieceGeometry.segments(def: def, pose: Pose(), flipped: false)) {
            centerOffset = Vec2(x: (b.min.x + b.max.x) / 2, y: (b.min.y + b.max.y) / 2)
        }
        if let def = assembly.def(defID) {
            // 幽灵件当前姿态（拖动时默认朝向 0，中心对准手指）
            let ghostPose = Pose(x: mm.x - centerOffset.x, y: mm.y - centerOffset.y, headingDegrees: 0)
            var best: SnapCandidate?
            let isRamp = def.family == "ramp"
            let levelSum = def.ports.reduce(0.0) { $0 + $1.level }
            for fp in assembly.freePorts() {
                for cp in def.ports where cp.polarity != fp.port.polarity {
                    // 候选变体：正放 +（爬坡轨独有的）翻面——高低端互换、脚印不变。
                    // 端口脚印位置与朝向翻面后不变，只有有效高度不同；
                    // 同一端口两个变体距离相同，先算正放、严格更近才替换 → 同距时优先正放
                    var variants = [(level: cp.level, flipped: false)]
                    if isRamp, cp.level != levelSum - cp.level {
                        variants.append((levelSum - cp.level, true))
                    }
                    for v in variants {
                        // 地面约束：任何端口翻后不得低于地面
                        let effLevels = def.ports.map { v.flipped ? levelSum - $0.level : $0.level }
                        let childBase = fp.worldLevel - v.level
                        guard childBase + (effLevels.min() ?? 0) >= -0.5 else { continue }
                        // 按「被拖零件端口 ↔ 目标端口」的实际距离判定，而不是手指距离——
                        // 长零件（道岔/长直轨）端口离手指远，视觉对上就该吸
                        let portWorld = ghostPose.apply(cp.position)
                        let d = (portWorld - fp.pose.position).length
                        let cand = SnapCandidate(parentPieceID: fp.pieceID, parentPortID: fp.port.id,
                                                 childPortID: cp.id, pose: Pose.attaching(childPort: cp, to: fp.pose),
                                                 distance: d, rampFlipped: v.flipped)
                        if let b = best {
                            if d < b.distance { best = cand }
                        } else {
                            best = cand
                        }
                    }
                }
            }
            if let b = best, b.distance <= Self.snapThresholdMM { snap = b }
        }
        drag = DragState(defID: defID, pointMM: mm, snap: snap, centerOffset: centerOffset)
    }

    func endDrag() {
        defer { drag = nil }
        guard let d = drag, let s = d.snap else { return }
        pushHistory()
        _ = assembly.attach(defID: d.defID, childPortID: s.childPortID,
                            toParent: s.parentPieceID, parentPortID: s.parentPortID,
                            childFlipped: s.rampFlipped)
        assembly.tryCloseLoop()
        selectedDefID = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    // MARK: 长按删除

    /// 点到线段的最短距离
    private func distPointToSeg(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
        let abx = b.x - a.x, aby = b.y - a.y
        let len2 = abx * abx + aby * aby
        if len2 < 1e-9 { return (p - a).length }
        let t = max(0, min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / len2))
        return (p - Vec2(x: a.x + t * abx, y: a.y + t * aby)).length
    }

    /// 命中检测：找出离触点最近（<35mm）的已放置零件
    func pieceHitTest(at point: CGPoint, canvasSize: CGSize) -> PlacedPiece? {
        let mm = toMM(point, canvasSize: canvasSize)
        var best: (piece: PlacedPiece, dist: Double)?
        for pc in assembly.pieces {
            guard let def = assembly.def(pc.defID) else { continue }
            let segs = PieceGeometry.segments(def: def, pose: pc.pose, flipped: pc.flipped)
            var minD = Double.infinity
            for seg in segs {
                let pts = PieceGeometry.points(of: seg)
                for i in 0..<(pts.count - 1) {
                    minD = min(minD, distPointToSeg(mm, pts[i], pts[i + 1]))
                }
            }
            if minD < 35, best == nil || minD < best!.dist { best = (pc, minD) }
        }
        return best?.piece
    }

    /// 长按命中 → 弹出删除气泡
    func requestDelete(at point: CGPoint, canvasSize: CGSize) {
        guard let pc = pieceHitTest(at: point, canvasSize: canvasSize),
              let def = assembly.def(pc.defID) else { return }
        // 翻转按钮：弯轨/道岔=「翻转」（绕接口镜像翻面）；
        // 爬坡轨按当前坡向显示动作效果（改为上行/改为下行/上下互换）
        let flipLabel: String?
        switch def.family {
        case "curve", "switch": flipLabel = "翻转"
        case "ramp": flipLabel = rampFlipLabel(pc.id)
        default: flipLabel = nil
        }
        pendingDelete = PendingDelete(pieceID: pc.id, screenPoint: point,
                                      name: def.name, canFlip: flipLabel != nil,
                                      flipLabel: flipLabel)
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }

    /// 爬坡轨翻转按钮文案：单端连接时算出翻后自由端高度，
    /// 升高 → 「改为上行」、降低 → 「改为下行」（若低于地面按钮按下后会给出解释）；
    /// 双端连接或自由放置 → 「上下互换」
    private func rampFlipLabel(_ id: UUID) -> String {
        guard let wa = assembly.worldPort(id, "a"),
              let wb = assembly.worldPort(id, "b") else { return "上下互换" }
        let freeKeys = Set(assembly.freePorts().map { "\($0.pieceID.uuidString)-\($0.port.id)" })
        let aFree = freeKeys.contains("\(wa.pieceID.uuidString)-a")
        let bFree = freeKeys.contains("\(wb.pieceID.uuidString)-b")
        guard aFree != bFree else { return "上下互换" }   // 双端都接 / 双端都空
        let (connLevel, connIsA) = aFree ? (wb.worldLevel, false) : (wa.worldLevel, true)
        let freeLevel = aFree ? wa.worldLevel : wb.worldLevel
        // 翻面绕连接端镜像：自由端新高度 = 2×连接端高度 − 自由端当前高度
        let newFreeLevel = 2 * connLevel - freeLevel
        return newFreeLevel > freeLevel ? "改为上行" : "改为下行"
    }

    /// 翻转零件：弯轨/道岔绕已连接接口镜像翻面（接口不脱开）、爬坡轨双面正反滚翻
    /// （上下坡互换，接口保持连接）。物理上不可行的翻转会被拒绝并提示。
    func flipPiece(_ id: UUID) {
        guard let pc = assembly.piece(id) else { return }
        freezeViewport()   // 翻转会改变包围盒，冻结中心避免画布被拽动、零件看似"平移"
        pushHistory()
        let hadConnection = assembly.isPieceConnected(id)
        guard assembly.flip(id) else {
            history.removeLast()   // 翻转被拒绝，撤销本次历史
            if assembly.def(pc.defID)?.family == "ramp" {
                showToast("连接端在地面上（0mm），反向会钻到地下——实物同样做不到：爬坡轨只有高端母口接在 64mm 桥面公口时才能上下互换")
            } else {
                showToast("翻面后会低于地面，物理上不可行——请先把这段轨道接到更高的接口上再翻")
            }
            pendingDelete = nil
            return
        }
        assembly.tryCloseLoop()
        if hadConnection {
            if assembly.isPieceConnected(id) {
                let isRamp = assembly.def(pc.defID)?.family == "ramp"
                showToast(isRamp ? "已翻面：上下坡互换，接口保持连接"
                                 : "已翻面，接口保持连接")
            } else {
                showToast("翻面后接口对不上，连接已断开——请拖拽零件重新吸附")
            }
        }
        pendingDelete = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func confirmDelete() {
        guard let pd = pendingDelete else { return }
        freezeViewport()   // 包围盒会变化，避免画布跳动
        pushHistory()
        assembly.removePiece(pd.pieceID)
        pendingDelete = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func cancelDelete() { pendingDelete = nil }

    // MARK: 动作

    /// 一键拼一个经典椭圆环：直轨 + 4 弯 + 直轨 + 4 弯
    func buildOval() {
        guard let start = assembly.freePorts().first(where: { $0.port.polarity == "M" }) else { return }
        pushHistory()
        if AutoBuilder.extendChain(assembly: &assembly, startPieceID: start.pieceID,
                                   startPortID: start.port.id, steps: AutoBuilder.ovalSteps()) {
            assembly.tryCloseLoop()
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func undo() {
        if let a = history.popLast() { assembly = a }
    }

    /// 导出斜角俯瞰装配图纸：直接保存到相册，轻提示结果
    func exportDrawing() {
        let img = DrawingExporter.renderImage(state: self)
        photoSaver = PhotoSaver { [weak self] message in
            self?.showToast(message)
        }
        UIImageWriteToSavedPhotosAlbum(img, photoSaver,
                                       #selector(PhotoSaver.image(_:didFinishSavingWithError:contextInfo:)),
                                       nil)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func showToast(_ message: String) {
        toast = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if toast == message { toast = nil }
        }
    }

    func reset() {
        pushHistory()
        var a = Assembly(library: library)
        _ = a.place(defID: "STR_144", pose: Pose())
        assembly = a
    }

    private func pushHistory() {
        history.append(assembly)
        if history.count > 50 { history.removeFirst() }
    }
}
