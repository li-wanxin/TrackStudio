# TrackStudio

iPad 木轨拼装 App —— 在 2D 画布上按实物尺寸拼搭木质火车轨道，实时预览 3D 效果，并导出可用于实际装配的图纸。

## 功能

### 2D 拼装画布
- **实物比例画法**：板宽 40mm、轨距 19.5mm、板厚 12mm，浅桦木配色 + 深色凹槽
- **钥匙孔榫卯接口**：公头 = 向外凸出的圆榫（Ø12.25 球头 + 6.75 颈部），母口 = 切穿顶面的钥匙孔（Ø12.75 孔 + 7.25 滑槽），与实物端头一致
- **吸附装配**：公母极性相对自动吸附，带真实装配容忍量（位置 10mm / 角度 6° / 高度差 6mm）
- **高度级联**：爬坡轨 / 桥面接上后，后续轨道自动继承接口高度，全链世界高度自洽
- **自动翻面适配**：拖动爬坡轨若正放会钻地而翻面能接上，自动以翻面姿态落位（坡向箭头拖动中可见）
- **穿桥遮挡**：交叉处按世界高度排序绘制，上层轨道自然遮住下层
- **画布平移**：空白处拖动平移、双击回中，画到边缘也能操作

### 3D 预览
- SceneKit 连续扫掠网格渲染（顶面/侧壁/底面/端帽），弧形坡面（smoothstep）
- 桥墩自动锚定接缝位置（单柱 20×48mm + 托板 26×52mm）

### 翻转体系
- 弯轨 / 道岔：绕已连接接口的**枢轴镜像翻折**，接口保持连接
- 爬坡轨：**双面正反滚翻** + 基准高度配平（低公高母 ⇄ 高公低母），物理上不可行的翻转（会钻地）被拒绝并解释原因
- 长按零件弹出操作气泡：删除 / 翻转（文案按零件类型动态显示）

### 导出装配图纸
- 斜角俯瞰投影图纸，直存系统相册
- 实物接口画法：公头凸榫带厚度层次、母口钥匙孔带孔底凹陷
- 桥墩（黄色立柱 + 托板）画在轨道下方
- 底部**零件清单**：每种模组统一实际比例缩略图 + 名称 ×数量

### 零件库（v0.0.1，9 种上托盘 / 共 18 种）
直轨 54/108/144/216mm、弯轨大/小（45°）、左右开道岔（互为镜像）、缓冲止挡、爬坡轨（升高 64mm，低公高母）

## 构建

```bash
# 内核单元测试
cd Packages/TrackGeometry && swift test --disable-sandbox

# iOS 构建（需 Xcode + Apple ID 签名）
xcodebuild -project TrackStudio.xcodeproj -scheme TrackStudio \
  -destination 'generic/platform=iOS' -configuration Debug build -allowProvisioningUpdates
```

- 要求 iPadOS 17.0+（iPad 专版）
- 免费开发者账号签名有效期 7 天，过期重装即可

## 项目结构

```
TrackStudio/
├── App/                        # SwiftUI 界面与状态
│   ├── TrackStudioApp.swift    # 入口
│   ├── DemoState.swift         # 全局状态：装配体/拖拽吸附/撤销/翻转/导出
│   ├── ContentView.swift       # 顶栏 + 托盘 + 画布容器
│   ├── CanvasAreaView.swift    # 2D 画布绘制与手势
│   ├── PieceGeometry.swift     # 零件几何采样/实心轮廓/端头绘制
│   ├── Scene3DView.swift       # 3D 预览（SceneKit 扫掠网格）
│   └── DrawingExporter.swift   # 装配图纸导出
├── Packages/TrackGeometry/     # 独立内核包（无 UI 依赖，纯 Swift）
│   ├── Sources/TrackGeometry/  # Pose / PartLibrary / Assembly
│   └── Tests/                  # 单元测试
├── Assets.xcassets/            # App 图标
└── Support/Info.plist
```

## 版本

- **v0.0.1**：首个可用版本——2D/3D 拼装、翻转体系、自动翻面吸附、装配图纸导出
