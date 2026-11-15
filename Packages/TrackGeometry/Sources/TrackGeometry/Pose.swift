import Foundation

// MARK: - 基础几何

public struct Vec2: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double = 0, y: Double = 0) {
        self.x = x
        self.y = y
    }

    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x - b.x, y: a.y - b.y) }
    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x + b.x, y: a.y + b.y) }
    public static func * (v: Vec2, s: Double) -> Vec2 { Vec2(x: v.x * s, y: v.y * s) }
    public var length: Double { (x * x + y * y).squareRoot() }
}

/// 位姿：位置 + 朝向。所有轨道拼装都通过刚体变换完成，误差不累积。
/// 单位：mm / 弧度。heading 逆时针为正，0 = +x 方向。
public struct Pose: Equatable, Sendable {
    public var x: Double
    public var y: Double
    /// 弧度
    public var heading: Double

    public init(x: Double = 0, y: Double = 0, headingDegrees: Double = 0) {
        self.x = x
        self.y = y
        self.heading = headingDegrees * .pi / 180
    }

    public init(x: Double, y: Double, headingRadians: Double) {
        self.x = x
        self.y = y
        self.heading = headingRadians
    }

    public var position: Vec2 { Vec2(x: x, y: y) }

    /// 刚体变换复合：先应用 b，再应用 a
    public static func compose(_ a: Pose, _ b: Pose) -> Pose {
        let c = cos(a.heading), s = sin(a.heading)
        return Pose(x: a.x + c * b.x - s * b.y,
                    y: a.y + s * b.x + c * b.y,
                    headingRadians: a.heading + b.heading)
    }

    public var inverse: Pose {
        let c = cos(heading), s = sin(heading)
        return Pose(x: -(x * c + y * s),
                    y: x * s - y * c,
                    headingRadians: -heading)
    }

    public func apply(_ p: Vec2) -> Vec2 {
        let c = cos(heading), s = sin(heading)
        return Vec2(x: x + c * p.x - s * p.y,
                    y: y + s * p.x + c * p.y)
    }

    /// 两个位姿是否在容差内一致（用于闭环判定）
    public func isClose(to other: Pose, tolMM: Double = 0.5, tolDegrees: Double = 1.0) -> Bool {
        let d = (position - other.position).length
        var dh = abs(heading - other.heading).truncatingRemainder(dividingBy: 2 * .pi)
        if dh > .pi { dh = 2 * .pi - dh }
        return d <= tolMM && dh <= tolDegrees * .pi / 180
    }

    /// 两个朝向是否相反（用于公母对接判定）
    public func headingIsOpposite(to other: Pose, tolDegrees: Double = 1.0) -> Bool {
        var dh = abs(heading - other.heading).truncatingRemainder(dividingBy: 2 * .pi)
        if dh > .pi { dh = 2 * .pi - dh }
        return abs(dh - .pi) <= tolDegrees * .pi / 180
    }
}

// MARK: - 拼接公式
// 新件位姿 = 父件端口位姿 ⊕ 反向的子件局部端口位姿

public extension Pose {
    /// 把子件的某个端口对接到父件端口上，返回子件位姿
    static func attaching(childPort: PortDef, to parentPort: Pose) -> Pose {
        let target = Pose(x: parentPort.x, y: parentPort.y,
                          headingRadians: parentPort.heading + .pi)
        let local = Pose(x: childPort.x, y: childPort.y,
                         headingRadians: childPort.headingRadians)
        return Pose.compose(target, local.inverse)
    }
}
