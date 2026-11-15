# TrackStudio 开发过程记录（交接文档）

> 本文档面向接手开发的后续开发者或 AI 助手，记录 v0.0.1 的实现要点、关键设计决策、踩坑与已知问题。配合 README.md 阅读。

## 1. 整体架构

两层结构，内核与 UI 严格分离：

- **TrackGeometry 内核包**（`Packages/TrackGeometry`）：纯 Swift，无 UI 依赖，可独立 `swift test`
  - `Pose.swift`：2D 刚体位姿（mm / 弧度），镜像与复合变换
  - `PartLibrary.swift`：零件定义（从 `parts_seed.json` 加载），端口（位置/朝向/极性/高度）
  - `Assembly.swift`：装配体核心——放置、吸附连接、高度级联、翻转、闭环检测
- **App 层**（`App/`）：SwiftUI + SceneKit
  - `DemoState`：ObservableObject 全局状态，持有 Assembly，实现拖拽吸附、撤销历史、翻转动作、toast
  - `CanvasAreaView`：2D 画布（SwiftUI Canvas 手绘），所有轨道造型都是矢量绘制，无位图
  - `Scene3DView`：3D 预览，**手写三角网格**（SCNGeometrySource data 方式），不是 SCNGeometry 原语拼装
  - `DrawingExporter`：UIGraphicsImageRenderer 出图纸

## 2. 核心模型与关键决策

### 2.1 端口位姿 + 高度级联
- 零件端口定义在零件局部坐标系：位置 (x,y)、朝向 heading（度，**指向件外**）、极性 M/F、相对高度 level
- `PlacedPiece` 有 `baseLevel`（基准高度）与 `flipped`（翻面状态）；端口世界高度 = baseLevel + port.level
- `attach()` 计算子件 baseLevel = 父端口世界高度 − 子端口 level → 爬上桥后所有后续轨道自动继承高度
- 地面约束：任何端口 baseLevel + minLevel ≥ −0.5mm，否则拒绝吸附（防钻地）

### 2.2 极性语义（以实物为准！）
- 普通直轨/弯轨/道岔：一公一母；道岔本体有三端（一公两母）
- **爬坡轨 ASC_N：低公高母**（低端公头插地面轨道母口、高端母口承接二层轨道公头）——曾两次改错（先标 F，后一度改双公），最终以用户实物照片确认。**教训：木轨极性不要凭社区数据推断，以实物为准**
- 真实尺寸：母口钥匙孔 Ø12.75 孔 + 7.25 宽滑槽，孔心距端面 12.10；公头 Ø12.25 球头 + 6.75 颈部，球心距端面 11.90（用户提供官方尺寸图）

### 2.3 翻转体系（四轮演进收敛）
- **弯轨/道岔**：`flip(id:)` 枢轴翻折——局部 y 镜像 M0，绕枢轴接口轴镜像 M1，刚体变换 Q = M1∘M0 作用到位姿。两镜像轴相交 → 绕交点旋转 2δ；平行 → 平移 2·qy。连接保持；位置/高度不吻合的连接自动断开
- **爬坡轨**：`flipRamp(id:def:)` 双面正反滚翻——绕已连接接口翻面后重配基准（两端 sum-level 互换），接口世界高度不变、连接保持；任一端口落地 < −0.5mm 拒绝。物理结论：接口端锚在地面（0mm）时坡向不可反（0↔64 桥接两朝向等价），只有高端母口接 64mm 桥面公口时才能上下互换
- App 层 `flipPiece` 会先 `freezeViewport()` 冻结视口中心——翻转改变包围盒，否则自动居中会拽动画布，视觉像"平移"

### 2.4 自动翻面吸附
- 拖拽时对每个兼容端口同时算正放/翻面两个变体（爬坡轨翻面 = 高低端互换、脚印不变）
- 正放违反地面约束而翻面可行 → 自动用翻面姿态；两者都可行时优先正放
- 幽灵件画坡向箭头（`drawSlopeIndicator`），命中翻面变体时箭头反向

### 2.5 装配容忍量
- `AssemblyTolerance`：位置 10mm / 角度 6° / 高度差 6mm，用于 `connect` 与 `tryCloseLoop`——模拟真实木头积木弹性形变，否则混合直轨弯轨的环闭不上

### 2.6 拖拽跟手
- `DragState.centerOffset` = 包围盒中心偏移，幽灵件与未吸附落点都以**零件中心**对准手指（曾保留 70pt 指尖抬升导致"不跟手"观感，v0.0.1 已置 0）

## 3. 绘制体系（都是手绘矢量，改样式找这些函数）

| 场景 | 文件 | 关键函数 |
|---|---|---|
| 2D 板身（侧壁+顶面+凹槽） | CanvasAreaView | `drawTrackBody` |
| 2D 端头（钥匙孔榫卯） | PieceGeometry | `drawJointEnd` / `drawAllJointEnds`（画布与托盘共用） |
| 2D 遮挡排序 | CanvasAreaView | `draw` 内按平均世界高度升序 |
| 3D 扫掠网格 | Scene3DView | 沿中心线 6mm 重采样生成顶点+法线 |
| 3D 桥墩 | Scene3DView | `pier()`，按 worldLevel>10 的连接点锚定 |
| 图纸投影 | DrawingExporter | gx = x−y, gy = (x+y)/2 − z·0.8 |
| 图纸接口 | DrawingExporter | `drawJointEnd`（EndMark；**注意所有端口都画**，已连接公头端跳过） |
| 图纸零件清单 | DrawingExporter | `drawPartsList` / `drawThumbnail`（全局统一比例） |

**图纸绘制踩坑**：圆+槽合并成一条 UIBezierPath 用非零环绕规则填充会因绕向相消挖出环形空洞——必须分开 fill。

## 4. 构建 / 测试 / 部署

```bash
# 内核测试（14+ 用例，含 FlipTests）
cd Packages/TrackGeometry && swift test --disable-sandbox

# 构建（注意：本机环境执行 xcodebuild 需禁用沙箱）
rm -rf ~/Library/Developer/Xcode/DerivedData/TrackStudio-*
xcodebuild -project TrackStudio.xcodeproj -scheme TrackStudio \
  -destination 'generic/platform=iOS' -configuration Debug build -allowProvisioningUpdates

# 装机（开发者自己的 iPad）
APP=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 5 -name "TrackStudio.app" -path "*iphoneos*" | head -1)
xcrun devicectl device install app --device <UDID> "$APP"
xcrun devicectl device process launch --device <UDID> com.workbuddy.trackstudio
```

- 新增 Swift 文件需在 `project.pbxproj` 登记 4 处（fileRef / buildFile / group / sources）
- 新增资源登记 3 处（fileRef / group / Resources build phase）

## 5. 已知问题与注意事项

1. **免费 Apple ID 签名**：描述文件 7 天过期；Xcode 账号会话经常掉，GUI 显示已登录但 `xcodebuild` CLI 报 `No Accounts`——GUI 里移除账号重新添加，或直接在 Xcode 里 Cmd+R
2. **添加新设备**：需目标 iPad 开启开发者模式（设置→隐私与安全性），首次连接会经历 "Preparing device"
3. **parts_seed.json 是唯一零件数据源**，改端口/极性后跑内核测试（`testLibraryLoads` 断言零件数量）
4. 零件库当前 18 种，托盘只放 9 种（SW_M 由 SW_L 翻转镜像得到，BRIDGE_DECK 与 STR_144 同几何）
5. 图纸导出尺寸 H=1560，零件清单单行排布，型号再多需换行逻辑
6. `DemoState.scale = 0.8`（mm→pt），改缩放会影响吸附半径等常量的视觉一致性

## 6. 版本历史

- **v0.0.1**（2026-11-15）：首个可用版本。2D 实物画法 + 吸附装配 + 高度级联 + 翻转体系（枢轴翻折/爬坡轨滚翻/自动翻面吸附）+ 3D 扫掠渲染 + 桥墩 + 画布平移 + 长按信息卡 + 装配图纸导出（含零件清单与实物接口画法）+ App 图标
