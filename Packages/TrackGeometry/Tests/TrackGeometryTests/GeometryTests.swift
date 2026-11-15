import XCTest
@testable import TrackGeometry

final class GeometryTests: XCTestCase {

    let library = try! PartLibrary.load()

    // MARK: 零件库

    func testLibraryLoads() {
        XCTAssertEqual(library.parts.count, 18, "种子库应有 18 个零件")
        XCTAssertNotNil(library.byId["CUR_E45"])
        XCTAssertNotNil(library.byId["SW_L"])
        // 爬坡轨实物极性：低公高母（低端公头插地面母口，高端母口承接二层公头）
        XCTAssertEqual(library.byId["ASC_N"]?.port("a")?.polarity, "M")
        XCTAssertEqual(library.byId["ASC_N"]?.port("b")?.polarity, "F")
        XCTAssertEqual(library.byId["STR_144"]?.length, 144)
    }

    // MARK: 端口位姿

    func testCurvePortPose() {
        let def = library.byId["CUR_E45"]!
        let b = def.port("b")!
        let world = Pose.compose(Pose(), Pose(x: b.x, y: b.y, headingRadians: b.headingRadians))
        XCTAssertEqual(world.x, 142.84, accuracy: 0.1)
        XCTAssertEqual(world.y, 59.16, accuracy: 0.1)
        XCTAssertEqual(world.heading * 180 / .pi, 45, accuracy: 0.1)
    }

    func testPoseInverseRoundTrip() {
        let p = Pose(x: 37, y: -12, headingDegrees: 63)
        let rt = Pose.compose(p, p.inverse)
        XCTAssertEqual(rt.x, 0, accuracy: 1e-9)
        XCTAssertEqual(rt.y, 0, accuracy: 1e-9)
        XCTAssertEqual(rt.heading, 0, accuracy: 1e-9)
    }

    // MARK: 翻面（双面轨道）

    func testFlipMirrorsFreePorts() {
        var a = Assembly(library: library)
        let c = a.place(defID: "CUR_E45", pose: Pose())!
        let bBefore = a.worldPort(c.id, "b")!
        XCTAssertEqual(bBefore.pose.y, 59.16, accuracy: 0.1)

        a.flip(c.id)
        let bAfter = a.worldPort(c.id, "b")!
        XCTAssertEqual(bAfter.pose.x, bBefore.pose.x, accuracy: 0.001, "翻面后 x 不变")
        XCTAssertEqual(bAfter.pose.y, -bBefore.pose.y, accuracy: 0.1, "翻面后 y 镜像")
        XCTAssertEqual(bAfter.port.polarity, bBefore.port.polarity, "极性不变")

        // freePorts 必须走统一镜像逻辑（回归：黄点不跟随翻面的 bug）
        let free = a.freePorts().filter { $0.pieceID == c.id && $0.port.id == "b" }
        XCTAssertEqual(free.first?.pose.y ?? 999, -bBefore.pose.y, accuracy: 0.1,
                       "freePorts 的位姿应与 worldPort 一致（翻面镜像）")
    }

    // MARK: 拼接

    func testAttachStraightToEnd() {
        var a = Assembly(library: library)
        let s1 = a.place(defID: "STR_144", pose: Pose())!
        let s2 = a.attach(defID: "STR_144", childPortID: "a", toParent: s1.id, parentPortID: "b")!
        XCTAssertEqual(s2.pose.x, 144, accuracy: 0.001)
        XCTAssertEqual(s2.pose.y, 0, accuracy: 0.001)
        let w = a.worldPort(s2.id, "b")!
        XCTAssertEqual(w.pose.x, 288, accuracy: 0.001)
        XCTAssertEqual(a.stats.connections, 1)
        XCTAssertEqual(a.stats.gaps, 2)
    }

    func testPolarityMismatchRejected() {
        var a = Assembly(library: library)
        let s1 = a.place(defID: "STR_144", pose: Pose())!
        // a 端对 a 端：两个母口，必须拒绝
        XCTAssertNil(a.attach(defID: "STR_108", childPortID: "a", toParent: s1.id, parentPortID: "a"))
    }

    // MARK: 闭环——椭圆环（核心验证用例）

    func testOvalCloses() {
        var a = Assembly(library: library)
        let s1 = a.place(defID: "STR_144", pose: Pose())!
        XCTAssertTrue(AutoBuilder.extendChain(assembly: &a,
                                              startPieceID: s1.id,
                                              startPortID: "b",
                                              steps: AutoBuilder.ovalSteps()),
                      "链式拼接 4 弯 + 1 直 + 4 弯应全部成功")
        XCTAssertEqual(a.freePorts().count, 2, "闭合前应恰好剩起点和终点两个空端口")
        XCTAssertTrue(a.tryCloseLoop(), "末端口应与 STR_144 的 a 端精确闭合")
        XCTAssertEqual(a.pieces.count, 10)
        XCTAssertEqual(a.stats.gaps, 0)
        XCTAssertEqual(a.stats.closedLoops, 1)
    }

    func testOvalClosurePrecision() {
        var a = Assembly(library: library)
        let s1 = a.place(defID: "STR_144", pose: Pose())!
        _ = AutoBuilder.extendChain(assembly: &a, startPieceID: s1.id,
                                    startPortID: "b", steps: AutoBuilder.ovalSteps())
        // 闭合前：唯一剩下的 M 端口（末弯轨 b）与起点 F 端口的距离
        let free = a.freePorts()
        XCTAssertEqual(free.count, 2)
        let start = free.first { $0.port.polarity == "F" }
        let end = free.first { $0.port.polarity == "M" }
        if let start = start, let end = end {
            let d = (start.pose.position - end.pose.position).length
            XCTAssertLessThan(d, 0.3, "8 弯 + 直轨椭圆的闭合误差应小于 0.3mm")
            XCTAssertTrue(start.pose.headingIsOpposite(to: end.pose), "两端朝向应相反才能对接")
        }
    }
}
