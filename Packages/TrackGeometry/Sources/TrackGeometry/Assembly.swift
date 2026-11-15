import Foundation

// MARK: - 装配容忍量

/// 真实木头轨道有弹性形变量，闭合环路时端点间允许的小误差。
/// 积累的装配误差（混合直轨/弯轨的环）在真实拼装中可以被木头"挤"进去，
/// 数字模型同样放宽，否则理论精确但实际拼得上的环会被判为无法闭合。
public enum AssemblyTolerance {
    /// 端点间距容忍（mm）
    public static let positionMM: Double = 10
    /// 端点朝向角度容忍（度）
    public static let angleDegrees: Double = 6
    /// 端口高度差容忍（mm）
    public static let heightMM: Double = 6
}

// MARK: - 已放置零件与装配体

public struct PlacedPiece: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let defID: String
    public var pose: Pose
    /// 双面轨道（如弯轨）是否翻面：翻面后左右转互换
    public var flipped: Bool
    /// 基准高度（mm）：沿连接链级联。端口世界高度 = baseLevel + port.level
    public var baseLevel: Double

    public init(defID: String, pose: Pose, flipped: Bool = false, baseLevel: Double = 0) {
        self.id = UUID()
        self.defID = defID
        self.pose = pose
        self.flipped = flipped
        self.baseLevel = baseLevel
    }
}

public struct Connection: Hashable, Sendable {
    public let pieceA: UUID
    public let portA: String
    public let pieceB: UUID
    public let portB: String

    public init(_ a: UUID, _ pa: String, _ b: UUID, _ pb: String) {
        let keyA = a.uuidString + pa
        let keyB = b.uuidString + pb
        if keyA < keyB {
            pieceA = a; portA = pa; pieceB = b; portB = pb
        } else {
            pieceA = b; portA = pb; pieceB = a; portB = pa
        }
    }
}

public struct WorldPort: Sendable {
    public let pieceID: UUID
    public let defID: String
    public let port: PortDef
    public let pose: Pose
    /// 端口世界高度（mm）= 零件基准高度 + 端口相对高度
    public let worldLevel: Double
}

// MARK: - 装配体

public struct Assembly: Sendable {
    public let library: PartLibrary
    public private(set) var pieces: [PlacedPiece] = []
    public private(set) var connections: Set<Connection> = []

    public init(library: PartLibrary) {
        self.library = library
    }

    public func def(_ id: String) -> PartDef? { library.byId[id] }
    public func piece(_ id: UUID) -> PlacedPiece? { pieces.first { $0.id == id } }

    // MARK: 放置与连接

    @discardableResult
    public mutating func place(defID: String, pose: Pose, flipped: Bool = false,
                               baseLevel: Double = 0) -> PlacedPiece? {
        guard library.byId[defID] != nil else { return nil }
        let piece = PlacedPiece(defID: defID, pose: pose, flipped: flipped, baseLevel: baseLevel)
        pieces.append(piece)
        return piece
    }

    public func worldPort(_ pieceID: UUID, _ portID: String) -> WorldPort? {
        guard let pc = piece(pieceID),
              let def = library.byId[pc.defID],
              let port = def.port(portID) else { return nil }
        // 翻面 = 局部 y 镜像：中心线上的端口位置不变，弯轨/道岔弯向互换
        let local = pc.flipped
            ? Pose(x: port.x, y: -port.y, headingRadians: -port.headingRadians)
            : Pose(x: port.x, y: port.y, headingRadians: port.headingRadians)
        let pose = Pose.compose(pc.pose, local)
        // 双面爬坡轨翻面（绕纵轴滚翻）：上下坡互换——两端高度互换，脚印位置与极性不变
        var level = pc.baseLevel + port.level
        if pc.flipped, def.family == "ramp" {
            let sum = def.ports.reduce(0.0) { $0 + $1.level }
            level = pc.baseLevel + (sum - port.level)
        }
        return WorldPort(pieceID: pieceID, defID: pc.defID, port: port, pose: pose,
                         worldLevel: level)
    }

    /// 该零件是否有任何已占用的端口（已连接的零件不能单独调头/翻面，否则端口与邻居错位）
    public func isPieceConnected(_ pieceID: UUID) -> Bool {
        connections.contains { $0.pieceA == pieceID || $0.pieceB == pieceID }
    }

    public func isConnected(_ pieceID: UUID, _ portID: String) -> Bool {
        connections.contains {
            ($0.pieceA == pieceID && $0.portA == portID) || ($0.pieceB == pieceID && $0.portB == portID)
        }
    }

    /// 所有尚未连接的端口（走 worldPort 统一镜像逻辑，翻面件端口同步移动）
    public func freePorts() -> [WorldPort] {
        var result: [WorldPort] = []
        for pc in pieces {
            guard let def = library.byId[pc.defID] else { continue }
            for port in def.ports where !isConnected(pc.id, port.id) {
                if let wp = worldPort(pc.id, port.id) {
                    result.append(wp)
                }
            }
        }
        return result
    }

    /// 把一个新零件吸附到父件空闲端口上。公母必须相对、层高必须一致。
    /// - Parameter childFlipped: 双面爬坡轨以翻面姿态吸附（高低端互换，脚印位置不变）——
    ///   拖拽时若正放接不上（会钻到地下）而翻面能接上，App 会自动用翻面变体。
    @discardableResult
    public mutating func attach(defID: String, childPortID: String,
                                toParent parentPieceID: UUID, parentPortID: String,
                                childFlipped: Bool = false) -> PlacedPiece? {
        guard let childDef = library.byId[defID],
              let childPort = childDef.port(childPortID),
              let parentWorld = worldPort(parentPieceID, parentPortID),
              !isConnected(parentPieceID, parentPortID),
              childPort.polarity != parentWorld.port.polarity else { return nil }
        let isRamp = childDef.family == "ramp"
        let sum = childDef.ports.reduce(0.0) { $0 + $1.level }
        let entryLevel = childFlipped && isRamp ? sum - childPort.level : childPort.level
        let pose = Pose.attaching(childPort: childPort, to: parentWorld.pose)
        // 高度级联：孩子基准 = 父端口世界高度 − 孩子入口端口的相对高度
        // 这样爬上桥后，普通轨道接到桥面会自动继承桥面高度
        let childBase = parentWorld.worldLevel - entryLevel
        // 地面约束：零件任何端口都不能低于地面（0mm）——
        // 例如拿爬坡轨高端口（64mm 空中）去接地面端口会算出 -64mm，物理上不可能，拒绝吸附
        let minLevel = childDef.ports.map {
            childFlipped && isRamp ? sum - $0.level : $0.level
        }.min() ?? 0
        guard childBase + minLevel >= -0.5 else { return nil }
        guard let piece = place(defID: defID, pose: pose, flipped: childFlipped,
                                baseLevel: childBase) else { return nil }
        connections.insert(Connection(parentPieceID, parentPortID, piece.id, childPortID))
        return piece
    }

    /// 移除一块零件及其所有连接
    public mutating func removePiece(_ id: UUID) {
        pieces.removeAll { $0.id == id }
        connections = connections.filter { $0.pieceA != id && $0.pieceB != id }
    }

    /// 翻转零件。
    /// - 弯轨/道岔：绕"已连接端口"的轨道轴镜像翻面（接口保持原位、连接不脱开）；
    ///   未连接时绕自身中心线镜像。
    /// - 爬坡轨（双面）：正反滚翻——上下坡互换、脚印位置不变。绕已连接接口翻折
    ///   并重新配平基准高度，使接口世界高度不变、连接可自动恢复；
    ///   若翻后任何端口低于地面（物理上不可能）则拒绝翻转并返回 false。
    /// - 返回 false 表示翻转被拒绝，零件状态未变。
    @discardableResult
    public mutating func flip(_ id: UUID) -> Bool {
        guard let idx = pieces.firstIndex(where: { $0.id == id }),
              let def = library.byId[pieces[idx].defID] else { return false }

        if def.family == "ramp" {
            return flipRamp(id: id, def: def)
        }

        // 弯轨/道岔：绕枢轴接口轴的平面镜像（高度不变，必可行）
        // 额外作用在零件位姿上的刚体变换 Q：翻面 = 局部 y 镜像 M0，
        // 绕枢轴轴镜像 M1 = Q ∘ M0 → Q = M1 ∘ M0（两镜像轴相交→绕交点旋转 2δ，平行→平移）
        let pc = pieces[idx]
        var q = Pose()
        let connectedPorts = def.ports.filter { isConnected(id, $0.id) }
        if connectedPorts.count == 1,
           let wp = worldPort(id, connectedPorts[0].id) {
            let ql = pc.pose.inverse.apply(wp.pose.position)
            let delta = wp.pose.heading - pc.pose.heading
            if abs(sin(delta)) < 1e-9 {
                q = Pose(x: 0, y: 2 * ql.y, headingRadians: 0)
            } else {
                let k = Vec2(x: ql.x - ql.y / tan(delta), y: 0)
                let c2 = cos(2 * delta), s2 = sin(2 * delta)
                q = Pose(x: k.x - (c2 * k.x - s2 * k.y),
                         y: k.y - (s2 * k.x + c2 * k.y),
                         headingRadians: 2 * delta)
            }
        }
        pieces[idx].flipped.toggle()
        pieces[idx].pose = Pose.compose(pc.pose, q)
        connections = connections.filter { $0.pieceA != id && $0.pieceB != id }
        return true
    }

    /// 双面爬坡轨的正反滚翻：两端高度互换、脚印位置与极性不变。
    /// 有连接接口时，以该接口为枢轴重新配平基准高度（接口世界高度保持），
    /// 翻转后 tryCloseLoop 可自动恢复连接；翻后低于地面则拒绝。
    private mutating func flipRamp(id: UUID, def: PartDef) -> Bool {
        guard let idx = pieces.firstIndex(where: { $0.id == id }) else { return false }
        let sum = def.ports.reduce(0.0) { $0 + $1.level }
        let willFlip = !pieces[idx].flipped
        // 候选枢轴：已连接端口（按世界高度从高到低，高接口翻折更容易合法）
        let connected = def.ports
            .filter { isConnected(id, $0.id) }
            .compactMap { worldPort(id, $0.id) }
            .sorted { $0.worldLevel > $1.worldLevel }
        // 新基准：使枢轴端口在翻后的世界里高度保持不变；无连接时基准不动
        var newBase = pieces[idx].baseLevel
        if let pivot = connected.first {
            let pivotRelAfter = willFlip ? (sum - pivot.port.level) : pivot.port.level
            newBase = pivot.worldLevel - pivotRelAfter
        }
        // 地面约束：翻后任何端口不能低于地面
        let minEffective = def.ports.map {
            newBase + (willFlip ? (sum - $0.level) : $0.level)
        }.min() ?? newBase
        guard minEffective >= -0.5 else { return false }
        pieces[idx].flipped.toggle()
        pieces[idx].baseLevel = newBase
        connections = connections.filter { $0.pieceA != id && $0.pieceB != id }
        return true
    }

    /// 手动连接两个已放置零件的空闲端口（如闭合环路）。
    /// 装配容忍量：真实木头轨道有少量弹性形变，接口高度差在几毫米内可以强行拼上，
    /// 因此闭合时放宽高度检查（闭合后以两端各自的位姿记录连接，视觉上允许微小错位）。
    @discardableResult
    public mutating func connect(pieceA: UUID, portA: String, pieceB: UUID, portB: String) -> Bool {
        guard let w1 = worldPort(pieceA, portA),
              let w2 = worldPort(pieceB, portB),
              w1.port.polarity != w2.port.polarity,
              !isConnected(pieceA, portA),
              !isConnected(pieceB, portB),
              abs(w1.worldLevel - w2.worldLevel) <= AssemblyTolerance.heightMM else { return false }
        connections.insert(Connection(pieceA, portA, pieceB, portB))
        return true
    }

    /// 扫描空闲端口，把位置接近、朝向相反的一对自动闭合（闭环）。
    /// 默认容差按真实木头积木的装配容忍量设定：端点间距 ~10mm、角度 ~6°、高度差 ~6mm
    /// 都能拼上（木头有弹性，实际拼装中积累的小误差可以吸收）。
    @discardableResult
    public mutating func tryCloseLoop(tolMM: Double = AssemblyTolerance.positionMM,
                                      tolDegrees: Double = AssemblyTolerance.angleDegrees) -> Bool {
        let free = freePorts()
        for i in 0..<free.count {
            for j in (i + 1)..<free.count {
                let p1 = free[i], p2 = free[j]
                if p1.port.polarity != p2.port.polarity,
                   abs(p1.worldLevel - p2.worldLevel) <= AssemblyTolerance.heightMM,
                   (p1.pose.position - p2.pose.position).length <= tolMM,
                   p1.pose.headingIsOpposite(to: p2.pose, tolDegrees: tolDegrees) {
                    return connect(pieceA: p1.pieceID, portA: p1.port.id,
                                   pieceB: p2.pieceID, portB: p2.port.id)
                }
            }
        }
        return false
    }

    // MARK: 统计

    public var stats: (pieces: Int, connections: Int, gaps: Int, closedLoops: Int) {
        let total = pieces.reduce(0) { $0 + (library.byId[$1.defID]?.ports.count ?? 0) }
        let gaps = freePorts().count
        let conns = (total - gaps) / 2
        return (pieces.count, conns, gaps, (gaps == 0 && !pieces.isEmpty) ? 1 : 0)
    }

    /// 所有端口位置的包围盒（用于画布自动居中）。
    /// 走 worldPort 统一镜像逻辑，保证与端口实际位姿一致（直线族调头是 x 互换而非 y 镜像）
    public func portBounds() -> (min: Vec2, max: Vec2)? {
        var pts: [Vec2] = []
        for pc in pieces {
            guard let def = library.byId[pc.defID] else { continue }
            for port in def.ports {
                if let wp = worldPort(pc.id, port.id) {
                    pts.append(wp.pose.position)
                }
            }
        }
        guard let first = pts.first else { return nil }
        var lo = first, hi = first
        for p in pts {
            lo = Vec2(x: min(lo.x, p.x), y: min(lo.y, p.y))
            hi = Vec2(x: max(hi.x, p.x), y: max(hi.y, p.y))
        }
        return (lo, hi)
    }
}

// MARK: - 自动搭建

public enum AutoBuilder {
    /// 从一个空闲端口出发，按顺序拼接一系列零件（每个零件用它的入口端口连接）。
    /// 链式生长：新零件的出口端口约定为 "b"。
    @discardableResult
    public static func extendChain(assembly: inout Assembly,
                                   startPieceID: UUID,
                                   startPortID: String,
                                   steps: [(defID: String, entryPortID: String)]) -> Bool {
        var currentPiece = startPieceID
        var currentPort = startPortID
        for step in steps {
            guard let placed = assembly.attach(defID: step.defID,
                                               childPortID: step.entryPortID,
                                               toParent: currentPiece,
                                               parentPortID: currentPort) else { return false }
            currentPiece = placed.id
            currentPort = "b"
        }
        return true
    }

    /// 经典椭圆环：2 × 中直轨 + 8 × 45°大弯轨
    /// 结构：直轨 → 4 弯（转 180°）→ 直轨 → 4 弯（转回 180°）→ 闭合到起点
    public static func ovalSteps() -> [(defID: String, entryPortID: String)] {
        var steps: [(defID: String, entryPortID: String)] = []
        for _ in 0..<4 {
            steps.append((defID: "CUR_E45", entryPortID: "a"))
        }
        steps.append((defID: "STR_144", entryPortID: "a"))
        for _ in 0..<4 {
            steps.append((defID: "CUR_E45", entryPortID: "a"))
        }
        return steps
    }
}
