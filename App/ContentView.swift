import SwiftUI

struct ContentView: View {
    @StateObject private var state = DemoState()

    var body: some View {
        VStack(spacing: 0) {
            TopBarView(state: state)
            HStack(spacing: 0) {
                TrayView(state: state)
                if state.show3D {
                    Scene3DView(state: state)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    CanvasAreaView(state: state)
                        .coordinateSpace(name: "canvas")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color(red: 0.09, green: 0.085, blue: 0.073).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .overlay(alignment: .top) {
            if let t = state.toast {
                Text(t)
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color(red: 0.16, green: 0.15, blue: 0.13))
                        .shadow(color: .black.opacity(0.4), radius: 10, y: 4))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
                    .foregroundColor(.primary)
                    .padding(.top, 64)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: state.toast)
    }
}

// MARK: - 顶栏

struct TopBarView: View {
    @ObservedObject var state: DemoState

    var body: some View {
        let s = state.assembly.stats
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("TrackStudio")
                    .font(.system(size: 16, weight: .semibold))
                Text("几何内核 Demo · iPad")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer().frame(width: 12)
            StatChip(label: "零件", value: s.pieces)
            StatChip(label: "连接", value: s.connections)
            StatChip(label: "缺口", value: s.gaps, danger: s.gaps > 0)
            StatChip(label: "闭环", value: s.closedLoops, good: s.closedLoops > 0)
            Spacer()
            actionButton("3D", filled: state.show3D) { state.show3D.toggle() }
            actionButton("拼椭圆", filled: !state.show3D) { state.buildOval() }
            actionButton("导出图纸", filled: !state.show3D) { state.exportDrawing() }
            actionButton("撤销") { state.undo() }
            actionButton("清空") { state.reset() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(red: 0.13, green: 0.122, blue: 0.105))
    }

    private func actionButton(_ title: String, filled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(filled ? AnyShapeStyle(Color.blue.opacity(0.85)) : AnyShapeStyle(Color.white.opacity(0.08)))
                .foregroundColor(filled ? .white : .primary)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

struct StatChip: View {
    let label: String
    let value: Int
    var danger = false
    var good = false

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(danger ? .red : (good ? .green : .primary))
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.06))
        .cornerRadius(8)
    }
}

// MARK: - 底部零件托盘

struct TrayView: View {
    @ObservedObject var state: DemoState

    // SW_M（右开道岔）由 SW_L 长按「翻转」镜像得到；BRIDGE_DECK 与 STR_144 几何一致，
    // 不单独占格（实物清单统计时按用途折算）
    let trayIDs = ["STR_54", "STR_108", "STR_144", "STR_216",
                   "CUR_E45", "CUR_E1_45", "SW_L", "BUFFER", "ASC_N"]

    // 固定布局参数，用于自定义滚动与起始零件定位
    private let chipHeight: CGFloat = 104
    private let chipPitch: CGFloat = 118          // 104 + 14 间距
    private let contentTop: CGFloat = 14
    private let hintHeight: CGFloat = 30          // 提示文字 + 间距

    @State private var scrollOffset: CGFloat = 0
    @State private var scrollAnchor: CGFloat?
    @State private var placementDefID: String?
    @State private var placementActive = false

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            let viewHeight = geo.size.height
            let contentHeight = contentTop + hintHeight
                + CGFloat(trayIDs.count) * chipHeight
                + CGFloat(trayIDs.count - 1) * 14 + 14
            let minOffset = min(0, viewHeight - contentHeight)

            VStack(spacing: 14) {
                Text("拖入画布 / 点选")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(height: 16)
                ForEach(trayIDs, id: \.self) { id in
                    if let def = state.assembly.def(id) {
                        TrayChip(state: state, def: def)
                            .frame(height: chipHeight)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, contentTop)
            .padding(.bottom, 14)
            .frame(width: geo.size.width, alignment: .top)
            .offset(y: scrollOffset)
            .frame(width: geo.size.width, height: viewHeight, alignment: .top)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .global)
                    .onChanged { g in
                        if !placementActive {
                            // 手指越过托盘右边界 → 进入放置模式
                            if g.location.x > frame.maxX - 2 {
                                let startY = g.startLocation.y - frame.minY - scrollOffset
                                let idx = Int((startY - contentTop - hintHeight) / chipPitch)
                                placementDefID = trayIDs[max(0, min(trayIDs.count - 1, idx))]
                                placementActive = true
                                scrollAnchor = nil
                            } else if scrollAnchor == nil {
                                scrollAnchor = scrollOffset - g.translation.height
                            }
                        }
                        if placementActive, let defID = placementDefID {
                            state.updateDragGlobal(defID: defID, globalPoint: g.location)
                        } else if let anchor = scrollAnchor {
                            scrollOffset = min(max(anchor + g.translation.height, minOffset), 0)
                        }
                    }
                    .onEnded { _ in
                        if placementActive { state.endDrag() }
                        placementActive = false
                        placementDefID = nil
                        scrollAnchor = nil
                    }
            )
        }
        .frame(width: 150)
        .background(Color(red: 0.13, green: 0.122, blue: 0.105))
    }
}

struct TrayChip: View {
    @ObservedObject var state: DemoState
    let def: PartDef
    @State private var showInfo = false

    private var isSelected: Bool { state.selectedDefID == def.id }

    var body: some View {
        VStack(spacing: 6) {
            MiniTrack(def: def)
            Text(def.name)
                .font(.system(size: 13))
                .foregroundColor(isSelected ? .blue : .secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(isSelected ? Color.blue.opacity(0.18) : Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(isSelected ? Color.blue : Color.white.opacity(0.12),
                          lineWidth: isSelected ? 2 : 1))
        .contentShape(Rectangle())
        // 轻点选中；拖动由 TrayView 容器统一按轨迹分流（滚动 / 放置）
        .onTapGesture { state.selectForPlacement(def.id) }
        // 长按查看具体型号与尺寸（系统自动选择弹出方向，避免贴边截断）
        .onLongPressGesture(minimumDuration: 0.5) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showInfo = true
        }
        .popover(isPresented: $showInfo) {
            PartInfoCard(def: def)
                .padding(14)
                .frame(width: 272, alignment: .leading)
        }
    }
}

// MARK: - 零件型号尺寸信息卡（托盘长按弹出）

struct PartInfoCard: View {
    let def: PartDef

    private let familyNames = ["straight": "直轨", "curve": "弯轨", "switch": "道岔",
                               "buffer": "止冲轨", "ramp": "爬坡轨", "bridge": "桥面",
                               "cross": "交叉轨"]
    /// 尺寸字段的展示顺序与中文标签（angle 类单位是度，其余毫米）
    private static let geoOrder = ["length", "radius", "angle", "rise",
                                   "horizontal_projection", "base_straight",
                                   "branch_radius", "branch_angle", "branch_offset"]
    private static let geoLabels: [String: String] = [
        "length": "长度", "radius": "转弯半径", "angle": "弯角",
        "rise": "提升高度", "horizontal_projection": "水平投影",
        "base_straight": "直道段长", "branch_radius": "岔道半径",
        "branch_angle": "岔道角度", "branch_offset": "岔道偏移"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(def.name)
                    .font(.system(size: 19, weight: .semibold))
                Spacer()
                Text(familyNames[def.family] ?? def.family)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.blue.opacity(0.15))
                    .foregroundColor(.blue)
                    .cornerRadius(6)
            }
            if let alias = def.alias, !alias.isEmpty {
                Text("对应型号：\(alias)")
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Self.geoOrder, id: \.self) { key in
                    if let v = def.geometry[key] {
                        let unit = (key == "angle" || key == "branch_angle") ? "°" : " mm"
                        Text("\(Self.geoLabels[key] ?? key)：\(format(v))\(unit)")
                            .font(.system(size: 14))
                            .foregroundColor(.primary)
                    }
                }
                Text("板宽 40 mm · 凹槽距中心线 ±9.75 mm（轨距 19.5 mm）")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                if def.family == "ramp" {
                    Text("拱形坡面：两端水平、中间起拱（smoothstep）")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("端口")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                ForEach(def.ports, id: \.id) { p in
                    Text("· \(p.id)：\(p.polarity == "M" ? "公头（凸圆榫）" : "母口（插孔）")"
                         + (p.level > 0.5 ? " · 端口高度 \(Int(p.level)) mm" : ""))
                        .font(.system(size: 13))
                        .foregroundColor(.primary)
                }
            }

            if let notes = def.notes, !notes.isEmpty {
                Text(notes)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func format(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v)
    }
}

struct MiniTrack: View {
    let def: PartDef

    var body: some View {
        Canvas { ctx, size in
            let segs = PieceGeometry.segments(def: def, pose: Pose())
            guard let bounds = PieceGeometry.bounds(of: segs) else { return }
            // 外扩 20mm，让板宽（40mm）完整落进可视区域
            let cx = (bounds.min.x + bounds.max.x) / 2
            let cy = (bounds.min.y + bounds.max.y) / 2
            let spanX = max(bounds.max.x - bounds.min.x + DemoState.trackWidthMM, 1)
            let spanY = max(bounds.max.y - bounds.min.y + DemoState.trackWidthMM, 1)
            let s = min(Double(size.width) / spanX, Double(size.height) / spanY) * 0.92
            let toScreen: (Vec2) -> CGPoint = { p in
                CGPoint(x: size.width / 2 + (p.x - cx) * s,
                        y: size.height / 2 - (p.y - cy) * s)
            }
            // 与画布一致：浅桦木顶面 + 深棕线稿
            let wood = Color(red: 0.86, green: 0.70, blue: 0.44)
            let woodDark = Color(red: 0.32, green: 0.22, blue: 0.09)

            // 实体外框：两侧平行直边 + 平直端面（与画布同款画法）
            let side = PieceGeometry.solidPath(for: segs, halfWidthMM: DemoState.trackWidthMM / 2 + 2, toScreen: toScreen)
            let top = PieceGeometry.solidPath(for: segs, halfWidthMM: DemoState.trackWidthMM / 2, toScreen: toScreen)
            ctx.fill(side, with: .color(Color(red: 0.58, green: 0.43, blue: 0.20)))
            ctx.fill(top, with: .color(wood))

            if def.family != "buffer" {
                let grooves = PieceGeometry.offsetSegs(from: segs, offsetMM: DemoState.grooveOffsetMM)
                let gp = PieceGeometry.path(for: grooves, toScreen: toScreen)
                ctx.stroke(gp, with: .color(woodDark),
                           style: StrokeStyle(lineWidth: max(1.2, 4.5 * s), lineCap: .butt, lineJoin: .round))
            }

            // 实物端头：公头端凸出圆点 / 母口端缺口（与画布一致）
            PieceGeometry.drawAllJointEnds(&ctx, def: def,
                                           mmToPt: s, wood: wood, edge: woodDark,
                                           toScreen: toScreen)
        }
        .frame(width: 110, height: 56)
    }
}
