# GlamAR 产品路线图与技术方案

## 当前状态（MVP）

| 模块 | 状态 |
|------|------|
| 前置相机实时预览 | ✅ 完成 |
| MediaPipe 468 点人脸追踪 | ✅ 完成 |
| 口红 AR 叠加 + 色板 UI | ✅ 完成 |
| EMA 关键点平滑 | ✅ 完成 |

---

## 1.0 — AR 全妆系统

### 产品目标

提供海量妆容库，用户可一键试妆，也可自由调节每一处妆容细节，实现「所见即所得」的 AR 镜体验。

### 功能清单

#### 妆容库

- 海量预设妆容（目标 100+ 套），每套妆容包含完整的多部位配置
- 妆容分类体系：
  - 风格：日常通勤 / 约会妆 / 晚宴妆 / 职场妆
  - 流派：韩系 / 欧美 / 日系 / 国风
  - 场景：夏日 / 冬季 / 节日限定
- 支持收藏、历史记录、热门排行

#### AR 美妆部位

| 部位 | 可调参数 |
|------|----------|
| 口红 | 颜色、不透明度、妆效（哑光/水润/珠光） |
| 腮红 | 颜色、位置偏移、晕染范围、不透明度 |
| 眼影 | 多色分区、渐变方向、不透明度 |
| 眉毛 | 颜色、粗细、形状（平眉/拱形/挑眉） |
| 眼线 | 颜色、粗细、延伸长度（内眼线/猫眼） |
| 睫毛 | 浓密度、弯曲度、加长效果 |
| 粉底 | 色号、覆盖度（遮瑕效果） |
| 高光 | 位置、亮度、范围 |
| 修容 | 颜色、位置、强度 |

#### 细节调节面板

- 每个部位独立可调，拖拽滑块实时预览
- 支持对比（Before / After 50/50 分割线）
- 一键重置当前部位
- 全局透明度总控

### 技术方案

#### 渲染引擎

基于 `CustomPainter` + `Canvas` 的分层渲染架构：

```
相机帧（底层）
  └── 粉底层（BlendMode.multiply，全脸 mask）
      └── 腮红层（高斯模糊边缘，椭圆 mask）
          └── 眼影层（三角形/多边形分区 mask）
              └── 眉毛层（贝塞尔曲线描边）
                  └── 眼线层（路径描边）
                      └── 口红层（当前已实现）
                          └── 高光层（BlendMode.screen）
```

每层独立 `RepaintBoundary`，只有参数变化时才触发重绘。

#### 嘴唇部位关键点索引（MediaPipe Face Mesh）

| 部位 | 关键点索引范围 |
|------|--------------|
| 外嘴唇 | 61, 185, 40, 39, 37, 0, 267, 269, 270, 409, 291, 375, 321, 405, 314, 17, 84, 181, 91, 146 |
| 内嘴唇 | 78, 191, 80, 81, 82, 13, 312, 311, 310, 415, 308, 324, 318, 402, 317, 14, 87, 178, 88, 95 |
| 左眉 | 46, 53, 52, 65, 55, 70, 63, 105, 66, 107 |
| 右眉 | 276, 283, 282, 295, 285, 300, 293, 334, 296, 336 |
| 左眼 | 33, 7, 163, 144, 145, 153, 154, 155, 133, 173, 157, 158, 159, 160, 161, 246 |
| 右眼 | 362, 382, 381, 380, 374, 373, 390, 249, 263, 466, 388, 387, 386, 385, 384, 398 |
| 左腮红区 | 117, 118, 119, 120, 121, 128, 126 |
| 右腮红区 | 346, 347, 348, 349, 350, 357, 355 |

#### 妆容数据结构

```dart
class MakeupLook {
  final String id;
  final String name;
  final String category;
  final String style;
  final LipConfig lip;
  final BlushConfig blush;
  final EyeshadowConfig eyeshadow;
  final BrowConfig brow;
  final EyelinerConfig eyeliner;
  final FoundationConfig foundation;
  final HighlightConfig highlight;
}

class LipConfig {
  final Color color;
  final double opacity;       // 0.0 ~ 1.0
  final LipFinish finish;     // matte / glossy / shimmer
}
```

#### 妆容库存储方案

- **本地**：内置 20 套精选妆容，打包进 `assets/looks/`，JSON 格式
- **远端**：Firebase Firestore + Storage，支持动态下发、运营更新
- 图片资源（妆容缩略图）使用 CDN，Flutter 端 `cached_network_image` 缓存

#### 新增依赖

```yaml
dependencies:
  flutter_colorpicker: ^1.1.0    # 颜色选择器
  cached_network_image: ^3.4.0   # 妆容缩略图缓存
  cloud_firestore: ^5.x.x        # 妆容库（可选，远端方案）
  firebase_storage: ^12.x.x      # 资源存储（可选）
  go_router: ^14.x.x             # 路由管理
  riverpod: ^2.x.x               # 状态管理
```

#### 架构扩展

```
lib/
├── app/
│   ├── theme/
│   └── router/                  # go_router 路由配置
├── features/
│   ├── face_mesh/               # 现有，保持不变
│   ├── makeup/
│   │   ├── models/              # MakeupLook, LipConfig 等数据模型
│   │   ├── painters/            # 各部位 CustomPainter
│   │   │   ├── lipstick_painter.dart   ✅ 已有
│   │   │   ├── blush_painter.dart
│   │   │   ├── eyeshadow_painter.dart
│   │   │   ├── brow_painter.dart
│   │   │   └── eyeliner_painter.dart
│   │   ├── providers/           # Riverpod providers
│   │   ├── ar_mirror_page.dart  # 主 AR 镜页面
│   │   └── detail_panel.dart    # 细节调节面板
│   └── catalog/
│       ├── look_catalog_page.dart  # 妆容库浏览页
│       └── look_card.dart
└── shared/
    └── services/
        └── looks_repository.dart  # 本地+远端妆容数据访问层
```

---

## 2.0 — 手把手教你化妆

### 产品目标

用户选择想学的妆容，App 实时通过摄像头分析用户当前化妆进度，分步骤给出语音+视觉引导，直到完成整套妆容。

### 功能清单

- **步骤拆解**：每套妆容拆分为 8~15 个有序步骤（打底 → 眉毛 → 眼影 → 眼线 → 腮红 → 口红 → 高光）
- **实时进度检测**：摄像头检测当前步骤是否完成，自动推进到下一步
- **语音播报**：TTS 朗读当前步骤要点
- **视觉引导叠加**：用半透明遮罩在脸上标注目标区域和方向箭头
- **对比参考图**：左侧显示目标妆容该步骤参考图
- **进度回退**：用户可手动切换到任意步骤
- **完成拍照**：完成后进入拍照/分享页，可叠加 AR 妆容保存

### 技术方案

#### 步骤检测方案

通过分析 Face Mesh 关键点颜色变化来判断化妆进度：

| 检测目标 | 技术手段 |
|----------|----------|
| 眉毛是否画了 | 分析眉毛区域关键点周围像素的深色覆盖率 |
| 口红是否涂了 | 分析嘴唇轮廓内像素的饱和度/色相是否偏红 |
| 眼影是否上了 | 分析眼睑区域像素与肤色基准的差异度 |
| 腮红是否打了 | 分析腮红区域像素的红色分量变化 |

具体实现：截取 Camera 帧中对应关键点围成的 ROI 区域，计算颜色特征值，与基准肤色比对得出「完成度评分」（0~1），超过阈值即认为该步骤完成。

#### 引导叠加渲染

```dart
class GuideOverlayPainter extends CustomPainter {
  // 当前步骤目标区域（关键点围成的多边形）
  // 绘制虚线描边 + 呼吸动画（AnimationController 控制透明度）
  // 方向箭头（Paint.drawArrow）
}
```

#### TTS 语音播报

```yaml
dependencies:
  flutter_tts: ^4.x.x   # 支持中文语音播报
```

#### 用户化妆动作识别（进阶）

如果要更精准地识别「刷腮红」「涂口红」等动作（手部轨迹），可引入：

- `google_mlkit_hand_pose` — Google ML Kit 手部关键点
- 根据手部与脸部关键点的相对位置和运动轨迹判断化妆动作类型

#### 步骤数据结构

```dart
class TutorialStep {
  final int order;
  final String title;           // '涂口红'
  final String instruction;     // '用唇刷从唇峰向外均匀涂抹...'
  final String audioText;       // TTS 播报文本
  final List<int> targetLandmarks;  // 本步骤高亮的关键点索引
  final StepDetector detector;  // 完成度检测逻辑
  final String referenceImageUrl;
}
```

#### 新增依赖

```yaml
dependencies:
  flutter_tts: ^4.x.x                        # TTS 语音
  google_mlkit_hand_pose: ^0.x.x             # 手部识别（可选）
  image: ^4.x.x                              # 像素分析
```

#### 架构扩展

```
lib/features/
└── tutorial/
    ├── models/
    │   ├── tutorial_step.dart
    │   └── step_detector.dart
    ├── painters/
    │   └── guide_overlay_painter.dart
    ├── providers/
    │   └── tutorial_provider.dart
    ├── tutorial_page.dart          # 教学主页面
    └── step_completion_analyzer.dart  # 像素分析 + 完成度判断
```

---

## 里程碑计划

| 阶段 | 目标 | 关键交付物 |
|------|------|-----------|
| MVP（当前）| 口红 AR + 色板 | `LipstickPainter`、色板 UI |
| 1.0-alpha | 全部位 AR 渲染 | 6 个部位 Painter、调节面板 |
| 1.0-beta | 妆容库 + 分类 | 20 套本地妆容、目录页 |
| 1.0 | 完整 AR 全妆体验 | 远端妆容库、拍照分享 |
| 2.0-alpha | 步骤引导原型 | 单妆容教学流程 |
| 2.0 | 手把手教化妆 | TTS + 进度检测 + 多妆容 |
