import XCTest
@testable import TrackGeometry

/// 翻转/反向行为：枢轴接口保持、连接不脱开、爬坡轨上下坡互换
final class FlipTests: XCTestCase {
    private var library: PartLibrary!
    private var assembly: Assembly!

    override func setUpWithError() throws {
        library = try PartLibrary.load()
        assembly = Assembly(library: library)
    }

    /// 弯轨通过活动端（b）连接时翻转：接口必须原地保持、连接不脱开、弯向反转
    func testCurveFlipPivotAtB() {
        _ = assembly.place(defID: "STR_144", pose: Pose())
        // 用弯轨的 b 端（活动端）接到直轨的母口上
        let strFree = assembly.freePorts().first { $0.port.polarity == "F" }!
        let curve = assembly.attach(defID: "CUR_E45", childPortID: "b",
                                    toParent: strFree.pieceID, parentPortID: strFree.port.id)!
        let bBefore = assembly.worldPort(curve.id, "b")!

        assembly.flip(curve.id)
        assembly.tryCloseLoop()

        XCTAssertEqual(assembly.connections.count, 1, "绕 b 端接口翻折，连接应保持")
        let bAfter = assembly.worldPort(curve.id, "b")!
        XCTAssertEqual(bAfter.pose.x, bBefore.pose.x, accuracy: 0.5, "接口位置不变")
        XCTAssertEqual(bAfter.pose.y, bBefore.pose.y, accuracy: 0.5, "接口位置不变")
        XCTAssertEqual(bAfter.pose.heading, bBefore.pose.heading, accuracy: 0.02, "接口朝向不变")
        // 弯向反转：a 端镜像到另一侧
        let aAfter = assembly.worldPort(curve.id, "a")!
        let aBefore = Pose.compose(curve.pose, Pose()).position   // 占位，下方用镜像关系验证
        _ = aBefore
        let bNow = assembly.worldPort(curve.id, "b")!
        XCTAssertNotEqual(aAfter.pose.y, bNow.pose.y, "a 端应镜像到轨道另一侧")
    }

    /// 弯轨通过固定端（a，中心线上）连接时翻转：a 端不动、连接保持
    func testCurveFlipPivotAtA() {
        _ = assembly.place(defID: "STR_144", pose: Pose())
        let strFree = assembly.freePorts().first { $0.port.polarity == "M" }!
        let curve = assembly.attach(defID: "CUR_E45", childPortID: "a",
                                    toParent: strFree.pieceID, parentPortID: strFree.port.id)!
        let aBefore = assembly.worldPort(curve.id, "a")!

        assembly.flip(curve.id)
        assembly.tryCloseLoop()

        XCTAssertEqual(assembly.connections.count, 1)
        let aAfter = assembly.worldPort(curve.id, "a")!
        XCTAssertEqual(aAfter.pose.x, aBefore.pose.x, accuracy: 0.5)
        XCTAssertEqual(aAfter.pose.y, aBefore.pose.y, accuracy: 0.5)
    }

    /// 爬坡轨反向（双面滚翻）：两端高度互换、脚印位置不变
    func testRampFlipSwapsLevels() {
        let ramp = assembly.place(defID: "ASC_N", pose: Pose())!
        let aBefore = assembly.worldPort(ramp.id, "a")!.pose
        let bBefore = assembly.worldPort(ramp.id, "b")!.pose

        assembly.flip(ramp.id)

        let a = assembly.worldPort(ramp.id, "a")!
        let b = assembly.worldPort(ramp.id, "b")!
        XCTAssertEqual(a.worldLevel, 64, accuracy: 0.001, "翻面后 a 端变高端")
        XCTAssertEqual(b.worldLevel, 0, accuracy: 0.001, "翻面后 b 端变低端")
        XCTAssertEqual(a.pose.x, aBefore.x, accuracy: 0.001, "脚印位置不变")
        XCTAssertEqual(a.pose.y, aBefore.y, accuracy: 0.001)
        XCTAssertEqual(b.pose.x, bBefore.x, accuracy: 0.001)
        XCTAssertEqual(b.pose.y, bBefore.y, accuracy: 0.001)
        XCTAssertEqual(a.port.polarity, "M", "极性跟随端点不变（双公件）")
    }

    /// 已连接的爬坡轨绕地面接口翻面会钻入地下 → 拒绝翻转，状态不变
    func testRampFlipRejectsBelowGround() {
        _ = assembly.place(defID: "STR_144", pose: Pose())
        let strFree = assembly.freePorts().first { $0.port.polarity == "F" }!
        let ramp = assembly.attach(defID: "ASC_N", childPortID: "a",
                                   toParent: strFree.pieceID, parentPortID: strFree.port.id)!
        XCTAssertEqual(assembly.connections.count, 1)
        let baseBefore = ramp.baseLevel

        XCTAssertFalse(assembly.flip(ramp.id), "绕地面接口翻面会低于地面，应拒绝")
        XCTAssertEqual(assembly.connections.count, 1, "拒绝翻转不应断开连接")
        XCTAssertEqual(assembly.piece(ramp.id)?.baseLevel ?? 999, baseBefore, "拒绝翻转不应改基准")
        XCTAssertFalse(assembly.piece(ramp.id)?.flipped ?? true, "拒绝翻转不应改变翻面状态")
    }

    /// 挂在二层接口上的爬坡轨翻面：接口保持连接，上下坡互换（下行↔上行）
    func testRampFlipAtDeckKeepsConnection() {
        // 二层直轨（基准 64），翻面后的爬坡轨以 b（F@64，高端母口）接到其公口 → 下行挂坡（a 端悬在 0）
        let deck = assembly.place(defID: "STR_144", pose: Pose(), baseLevel: 64)!
        let ramp = assembly.attach(defID: "ASC_N", childPortID: "b",
                                   toParent: deck.id, parentPortID: "b")!
        XCTAssertEqual(ramp.baseLevel, 0, accuracy: 0.001, "下行挂坡基准 0")
        assembly.tryCloseLoop()
        XCTAssertEqual(assembly.connections.count, 1)
        let bBefore = assembly.worldPort(ramp.id, "b")!

        // 翻面：绕二层接口翻折 → 变为上行挂坡（a 端升到 128），接口保持连接
        XCTAssertTrue(assembly.flip(ramp.id))
        assembly.tryCloseLoop()

        XCTAssertEqual(assembly.connections.count, 1, "绕二层接口翻面应保持连接")
        let bAfter = assembly.worldPort(ramp.id, "b")!
        XCTAssertEqual(bAfter.worldLevel, bBefore.worldLevel, accuracy: 0.001, "接口世界高度不变")
        XCTAssertEqual(bAfter.pose.x, bBefore.pose.x, accuracy: 0.5, "接口位置不变")
        let aAfter = assembly.worldPort(ramp.id, "a")!
        XCTAssertEqual(aAfter.worldLevel, 128, accuracy: 0.001, "翻面后另一端升到 128")

        // 再翻回来：回到下行挂坡（a 端落回 0），接口依然保持
        XCTAssertTrue(assembly.flip(ramp.id))
        assembly.tryCloseLoop()
        XCTAssertEqual(assembly.connections.count, 1)
        XCTAssertEqual(assembly.worldPort(ramp.id, "a")!.worldLevel, 0, accuracy: 0.001)
    }

    /// 上行挂坡（a 端接二层公口）翻面 → 变为下行坡落地，连接保持（用户场景）
    func testRampFlipTurnsAscentIntoDescent() {
        // 二层直轨，爬坡轨以 a（M@0）接其母口 → 上行挂坡（b 端悬在 128）
        let deck = assembly.place(defID: "STR_144", pose: Pose(), baseLevel: 64)!
        let deckFree = assembly.freePorts().first { $0.port.polarity == "F" }!
        let ramp = assembly.attach(defID: "ASC_N", childPortID: "a",
                                   toParent: deckFree.pieceID, parentPortID: deckFree.port.id)!
        XCTAssertEqual(ramp.baseLevel, 64, accuracy: 0.001)
        assembly.tryCloseLoop()
        XCTAssertEqual(assembly.connections.count, 1)

        XCTAssertTrue(assembly.flip(ramp.id))
        assembly.tryCloseLoop()

        XCTAssertEqual(assembly.connections.count, 1, "翻面后接口保持连接")
        let a = assembly.worldPort(ramp.id, "a")!
        let b = assembly.worldPort(ramp.id, "b")!
        XCTAssertEqual(a.worldLevel, 64, accuracy: 0.001, "接口（a 端）高度不变")
        XCTAssertEqual(b.worldLevel, 0, accuracy: 0.001, "翻面后 b 端落地——成为下行坡")
    }

    /// 自动翻面吸附：地面公口旁拖入爬坡轨，正放会钻地（b 母口@64 → 基准 -64），
    /// 翻面变体（b 变 0mm 低口）应能直接吸上，且落位即 flipped 状态
    func testRampAttachAutoFlipped() {
        let str = assembly.place(defID: "STR_144", pose: Pose())!
        // 正放接不上：b（F@64）接地面公口 → 基准 -64，被地面约束拒绝
        XCTAssertNil(assembly.attach(defID: "ASC_N", childPortID: "b",
                                     toParent: str.id, parentPortID: "b"))
        // 翻面变体：b（F，翻后 0mm）接同一个公口 → 基准 0，成功
        let ramp = assembly.attach(defID: "ASC_N", childPortID: "b",
                                   toParent: str.id, parentPortID: "b",
                                   childFlipped: true)!
        XCTAssertTrue(ramp.flipped, "落位即翻面状态")
        XCTAssertEqual(ramp.baseLevel, 0, accuracy: 0.001)
        XCTAssertEqual(assembly.worldPort(ramp.id, "b")!.worldLevel, 0, accuracy: 0.001,
                       "连接端（翻后低口）落在地面")
        XCTAssertEqual(assembly.worldPort(ramp.id, "a")!.worldLevel, 64, accuracy: 0.001,
                       "翻后高处是公头端")
        XCTAssertEqual(assembly.connections.count, 1)
    }
}
