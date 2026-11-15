import SwiftUI
import SceneKit

/// 3D 预览：装配体按实物尺寸立体呈现。
/// 轨道用自定义扫掠网格（沿中心线的连续三角带）渲染——表面平滑无方块接缝；
/// 坡道为 smoothstep 弧面（两端水平、中间起拱，贴合实物拱形爬坡轨）；
/// 支撑为黄色桁架柱（对应官方渲染图的塑料增高架）。
/// 单指旋转 / 双指缩放平移，仅预览；编辑仍在 2D 画布进行。
struct Scene3DView: View {
    @ObservedObject var state: DemoState

    var body: some View {
        SceneView(
            scene: buildScene(),
            options: [.allowsCameraControl, .autoenablesDefaultLighting]
        )
        .ignoresSafeArea(edges: .bottom)
    }

    private func buildScene() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor(red: 0.07, green: 0.065, blue: 0.055, alpha: 1)

        // 相机
        let camera = SCNCamera()
        camera.zNear = 1
        camera.zFar = 8000
        let camNode = SCNNode()
        camNode.camera = camera
        camNode.position = SCNVector3(0, 500, 700)
        camNode.eulerAngles = SCNVector3(-0.6, 0, 0)
        scene.rootNode.addChildNode(camNode)

        // 灯光：环境 + 主光 + 补光，柔化明暗
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 450
        ambient.light?.color = UIColor(white: 0.94, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 550
        key.position = SCNVector3(300, 800, 400)
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.intensity = 220
        fill.position = SCNVector3(-400, 500, -350)
        scene.rootNode.addChildNode(fill)

        // 地板
        let floorMat = SCNMaterial()
        floorMat.diffuse.contents = UIColor(red: 0.16, green: 0.15, blue: 0.13, alpha: 1)
        let floorGeo = SCNBox(width: 3000, height: 2, length: 3000, chamferRadius: 0)
        floorGeo.materials = [floorMat]
        let floor = SCNNode(geometry: floorGeo)
        floor.position = SCNVector3(0, -1, 0)
        scene.rootNode.addChildNode(floor)

        // 装配体：每块零件渲染成连续扫掠网格；高度 = 基准高度（沿连接链级联）
        for pc in state.assembly.pieces {
            guard let def = state.assembly.def(pc.defID) else { continue }
            let segs = PieceGeometry.segments(def: def, pose: pc.pose, flipped: pc.flipped)

            let heightAt: (Vec2) -> Double
            if def.family == "ramp",
               let wpa = state.assembly.worldPort(pc.id, "a"),
               let wpb = state.assembly.worldPort(pc.id, "b"),
               abs(wpb.port.level - wpa.port.level) > 1e-6 {
                // 走 worldPort 统一位姿（含调头），坡向始终正确
                let wa = wpa.pose.position
                let wb = wpb.pose.position
                let dx = wb.x - wa.x, dy = wb.y - wa.y
                let len = max((dx * dx + dy * dy).squareRoot(), 1e-6)
                let ux = dx / len, uy = dy / len
                let la = wpa.worldLevel   // 世界高度
                let lb = wpb.worldLevel
                heightAt = { p in
                    let vx = p.x - wa.x, vy = p.y - wa.y
                    let t = max(0, min(1, (vx * ux + vy * uy) / len))
                    // smoothstep：两端导数为 0（水平），中间平滑起拱
                    let s = t * t * (3 - 2 * t)
                    return la + (lb - la) * s
                }

            } else {
                heightAt = { _ in pc.baseLevel }
            }
            scene.rootNode.addChildNode(
                sweptTrackNode(segs: segs, heightAt: heightAt, def: def))
        }

        // 桥墩：只在每条抬离地面的接缝正下方放一根（位置取连接点世界坐标）
        for conn in state.assembly.connections {
            guard let wa = state.assembly.worldPort(conn.pieceA, conn.portA) else { continue }
            let h = wa.worldLevel
            guard h > 10 else { continue }   // 地面接缝不需要桥墩
            let j = wa.pose.position
            scene.rootNode.addChildNode(pier(
                cx: j.x, cy: j.y, height: h, angleY: wa.pose.heading))
        }

        // 接缝效果：每条连接处放一块深色薄片（比板截面略大，形成可见的拼接缝）
        let seamMat = SCNMaterial()
        seamMat.diffuse.contents = UIColor(red: 0.30, green: 0.20, blue: 0.08, alpha: 1)
        for conn in state.assembly.connections {
            guard let wa = state.assembly.worldPort(conn.pieceA, conn.portA),
                  let wb = state.assembly.worldPort(conn.pieceB, conn.portB) else { continue }
            let j = wa.pose.position
            let hd = wa.pose.heading
            let ux = cos(hd), uy = sin(hd)
            let seamGeo = SCNBox(width: 1.6, height: 12.8, length: 41.6, chamferRadius: 0)
            seamGeo.materials = [seamMat]
            let seam = SCNNode(geometry: seamGeo)
            seam.position = SCNVector3(j.x, wa.worldLevel + 6, -j.y)
            // local x 对齐行进方向，length 41.6 沿横向跨过板宽
            seam.eulerAngles = SCNVector3(0, Float(atan2(uy, ux)), 0)
            scene.rootNode.addChildNode(seam)
        }
        return scene
    }

    // MARK: - 轨道扫掠网格

    private struct Sample {
        let center: Vec2
        let height: Double
        let tangent: simd_float3   // 3D 行进方向（含坡度）
    }

    /// 沿中心线扫掠出轨道实体：顶面带 + 两侧壁 + 底面 + 端帽，再贴两条凹槽带
    private func sweptTrackNode(segs: [Seg], heightAt: (Vec2) -> Double, def: PartDef) -> SCNNode {
        let node = SCNNode()
        let woodMat = SCNMaterial()
        woodMat.diffuse.contents = UIColor(red: 0.86, green: 0.70, blue: 0.44, alpha: 1)
        woodMat.isDoubleSided = true
        let grooveMat = SCNMaterial()
        grooveMat.diffuse.contents = UIColor(red: 0.30, green: 0.20, blue: 0.08, alpha: 1)
        grooveMat.isDoubleSided = true

        for (si, seg) in segs.enumerated() {
            let pts = resampled(seg, step: 6)
            guard pts.count >= 2 else { continue }

            var samples: [Sample] = []
            for (i, p) in pts.enumerated() {
                let prev = pts[max(i - 1, 0)], next = pts[min(i + 1, pts.count - 1)]
                var t = simd_float3(Float(next.x - prev.x), 0, Float(-(next.y - prev.y)))
                if simd_length(t) < 1e-6 { t = simd_float3(1, 0, 0) }
                samples.append(Sample(center: p, height: heightAt(p), tangent: simd_normalize(t)))
            }

            // 止冲轨（buffer）：主体木杆 + 末端红色挡板（对应实物红色缓冲块）
            if def.family == "buffer" {
                if si == 0 {
                    node.addChildNode(makeSweep(samples, halfWidth: 20, topY: 12,
                                                thickness: 12, mat: woodMat))
                    // 红色挡板：立在轨道末端，横跨板宽
                    let end = pts.last!
                    let prev = pts[pts.count - 2]
                    let dx = end.x - prev.x, dy = end.y - prev.y
                    let len = max((dx * dx + dy * dy).squareRoot(), 1e-6)
                    let ux = dx / len, uy = dy / len
                    let h = heightAt(end)
                    let barGeo = SCNBox(width: 40, height: 26, length: 8, chamferRadius: 1)
                    let redMat = SCNMaterial()
                    redMat.diffuse.contents = UIColor(red: 0.75, green: 0.15, blue: 0.12, alpha: 1)
                    barGeo.materials = [redMat]
                    let bar = SCNNode(geometry: barGeo)
                    // 挡板沿横向放置：local x 对齐行进方向
                    bar.position = SCNVector3(end.x - ux * 6, h + 13, -(end.y - uy * 6))
                    bar.eulerAngles = SCNVector3(0, Float(atan2(uy, ux)), 0)
                    node.addChildNode(bar)
                }
                continue
            }

            // 板身：宽 40、厚 12
            node.addChildNode(makeSweep(samples, halfWidth: 20, topY: 12,
                                        thickness: 12, mat: woodMat))
            // 两条凹槽带：贴在顶面上方 0.4mm，宽 5mm
            for side in [-9.75, 9.75] {
                let gs = samples.map { s -> Sample in
                    let t2 = Vec2(x: Double(s.tangent.x), y: Double(-s.tangent.z))
                    let n2 = Vec2(x: -t2.y, y: t2.x)
                    return Sample(center: s.center + n2 * side,
                                  height: s.height, tangent: s.tangent)
                }
                node.addChildNode(makeSweep(gs, halfWidth: 2.5, topY: 12.4,
                                            thickness: 0, mat: grooveMat))
            }
        }
        return node
    }

    /// 线段重采样（弯轨 polyline 直接加密）
    private func resampled(_ seg: Seg, step: Double) -> [Vec2] {
        let pts = PieceGeometry.points(of: seg)
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

    /// 由采样点生成扫掠网格：顶面条带（含法线随坡面倾斜），thickness>0 时带侧壁/底面/端帽
    private func makeSweep(_ samples: [Sample], halfWidth: Double,
                           topY: Double, thickness: Double, mat: SCNMaterial) -> SCNNode {
        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var indices: [Int32] = []
        let hasBottom = thickness > 0.01

        func addVert(_ x: Double, _ y: Double, _ z: Double, _ n: simd_float3) -> Int32 {
            positions.append(SCNVector3(x, y, z))
            normals.append(SCNVector3(n.x, n.y, n.z))
            return Int32(positions.count - 1)
        }

        var topL: [Int32] = [], topR: [Int32] = []
        var botL: [Int32] = [], botR: [Int32] = []

        for s in samples {
            let t = s.tangent
            let t2 = Vec2(x: Double(t.x), y: Double(-t.z))
            let n2 = Vec2(x: -t2.y, y: t2.x)                  // 2D 横向
            let side3 = simd_float3(Float(n2.x), 0, Float(-n2.y))
            let up = simd_normalize(simd_cross(t, side3))     // 坡面法线
            let h = s.height
            let lx = s.center.x + n2.x * halfWidth, ly = s.center.y + n2.y * halfWidth
            let rx = s.center.x - n2.x * halfWidth, ry = s.center.y - n2.y * halfWidth
            topL.append(addVert(lx, h + topY, -ly, up))
            topR.append(addVert(rx, h + topY, -ry, up))
            if hasBottom {
                let dn = simd_float3(0, -1, 0)
                botL.append(addVert(lx, h + topY - thickness, -ly, dn))
                botR.append(addVert(rx, h + topY - thickness, -ry, dn))
            }
        }

        let n = samples.count
        for i in 0..<(n - 1) {
            // 顶面
            indices += [topL[i], topR[i], topR[i + 1]]
            indices += [topL[i], topR[i + 1], topL[i + 1]]
            if hasBottom {
                // 左右壁
                indices += [topL[i], botL[i], botL[i + 1], topL[i], botL[i + 1], topL[i + 1]]
                indices += [topR[i], topR[i + 1], botR[i + 1], topR[i], botR[i + 1], botR[i]]
                // 底面
                indices += [botL[i], botR[i], botR[i + 1], botL[i], botR[i + 1], botL[i + 1]]
            }
        }
        if hasBottom {
            // 两端平端帽
            indices += [topL[0], topR[0], botR[0], topL[0], botR[0], botL[0]]
            let e = n - 1
            indices += [topL[e], botL[e], botR[e], topL[e], botR[e], topR[e]]
        }

        let vertexSource = SCNGeometrySource(vertices: positions)
        // 法线：手工构造 float3 数据源
        var floatNormals: [Float] = []
        for n in normals { floatNormals += [Float(n.x), Float(n.y), Float(n.z)] }
        let normalSource = SCNGeometrySource(
            data: Data(bytes: floatNormals, count: floatNormals.count * MemoryLayout<Float>.size),
            semantic: .normal,
            vectorCount: normals.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 3)
        let ele = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geo = SCNGeometry(sources: [vertexSource, normalSource], elements: [ele])
        geo.materials = [mat]
        return SCNNode(geometry: geo)
    }

    // MARK: - 桥墩（只在接缝处，单柱）

    /// 单柱桥墩：宽度略宽于轨道（40mm），顶部托板托住接缝处轨道底面
    private func pier(cx: Double, cy: Double, height: Double, angleY: Double) -> SCNNode {
        let node = SCNNode()
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor(red: 0.82, green: 0.62, blue: 0.16, alpha: 1)

        // 柱体：行进方向 20mm、横向 48mm（略宽于 40mm 轨道），顶到轨道底面
        let colGeo = SCNBox(width: 20, height: CGFloat(max(height, 2)), length: 48, chamferRadius: 1)
        colGeo.materials = [mat]
        let col = SCNNode(geometry: colGeo)
        col.position = SCNVector3(0, max(height, 2) / 2, 0)
        node.addChildNode(col)

        // 顶部托板：比柱体再宽一点，正对接缝
        let capGeo = SCNBox(width: 26, height: 4, length: 52, chamferRadius: 1)
        capGeo.materials = [mat]
        let cap = SCNNode(geometry: capGeo)
        cap.position = SCNVector3(0, max(height, 2) + 1, 0)
        node.addChildNode(cap)

        node.position = SCNVector3(cx, 0, -cy)
        node.eulerAngles = SCNVector3(0, Float(angleY), 0)
        return node
    }
}
