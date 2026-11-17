# 光影评分（GuangYing）· iOS 自用版

一个只做一件事的相机：**实时评估构图，打分并给改进提示**。

去掉了账号、社区、积分、消息、推送、分享——自用不需要这些。

---

## 核心思路

不用任何第三方模型，**全部基于 iOS 自带的 Vision 框架**：

| 维度 | 权重 | 实现 |
|---|---|---|
| 主体位置 | 36% | 注意力显著性检测 + 人脸检测，取最大主体的中心点，算到最近三分点的距离 |
| 水平 | 20% | `VNDetectHorizonRequest` 检测地平线倾角 |
| 曝光 | 26% | 直接读 Y 平面算均值与高光/阴影溢出比例 |
| 主体占比 | 18% | 主体边界框面积占比，理想区间 12%–45% |

好处：**零模型文件、零授权风险、离线、启动快、不占体积**。总包体不到 2 MB。

评分做指数移动平均（0.72 / 0.28），避免数字跳变。没有检测到主体时总分封顶 62，防止空画面拿高分。

---

## 目录结构

```
guangying-ios/
├── project.yml                        # XcodeGen 工程定义（不手写 pbxproj）
├── GuangYing/
│   ├── GuangYingApp.swift             # 入口
│   ├── ContentView.swift              # 界面：分数环、维度条、提示、快门
│   ├── CameraPreview.swift            # AVCaptureVideoPreviewLayer 桥接
│   ├── CameraController.swift         # 采集 / 节流 / 拍照 / 存相册
│   └── CompositionScorer.swift        # 评分核心 ← 想调效果改这里
└── .github/workflows/
    ├── build-unsigned-ipa.yml         # 出未签名 IPA（默认，无需任何密钥）
    └── build-signed-ipa.yml           # 用你的证书云端签名（可选）
```

---

## 怎么装到 iPhone 上

你没有 Mac，所以走云端构建。两条路，推荐第一条。

### 路线 A：未签名 IPA + Sideloadly（最简单）

1. 在 GitHub 新建一个仓库，把 **`guangying-ios` 目录里的内容**作为仓库根目录推上去（`project.yml` 要在最外层）。
2. 推上去后 Actions 会自动跑 `Build unsigned IPA`。也可以在 Actions 页面手动 `Run workflow`。
3. 跑完在 Artifacts 里下载 `GuangYing-unsigned-ipa`，解压得到 `GuangYing-unsigned.ipa`。
4. Windows 上装 [Sideloadly](https://sideloadly.io/)，手机连电脑：
   - 把 ipa 拖进 Sideloadly
   - Apple ID 填你的开发者账号
   - 点 Start，输入密码
5. 装好后手机上要去 **设置 › 通用 › VPN与设备管理** 里信任你的开发者证书。

> 用免费 Apple ID 签的话，**7 天过期**，到期重新走一次第 4 步。用付费开发者账号签是 1 年。

### 路线 B：云端直接签好

如果你想让 CI 直接产出签好名的 IPA（可自签分发，不用每次重签）：

1. 在仓库 Settings → Secrets 里配置 `BUILD_CERTIFICATE_BASE64`、`P12_PASSWORD`、`PROVISIONING_PROFILE_BASE64`、`TEAM_ID`、`BUNDLE_ID`（说明见该 workflow 文件顶部注释）。
2. 手动触发 `Build signed IPA`。
3. 下载 artifact 里的 ipa。

注意：`provisioningProfiles` 里写的是 profile 名称 `GuangYing Distribution`，你要把它改成**你自己 profile 的真实名称**。

---

## 想改效果，改哪里

全部集中在 `CompositionScorer.swift`：

| 想调整 | 位置 |
|---|---|
| 各维度权重 | `evaluate()` 里的 `weighted` 那几行（0.36 / 0.20 / 0.26 / 0.18） |
| 主体位置容忍度 | `placementScore()` 的 `/ 0.32`，越小越严格 |
| 主体占比理想区间 | `sizeScore()` 的 `0.12...0.45` |
| 曝光目标亮度 | `exposureScore()` 的 `0.45` |
| 平滑强度 | `smoothedTotal` 的 `0.72 / 0.28`，前者越大越稳但越迟钝 |
| 自动快门阈值 | `CameraController.autoCaptureThreshold`，默认 85 |
| 分析频率 | `analysisInterval`，默认 0.22 秒 |

改完重新推代码，Actions 会重新出包。

---

## 已知限制（用之前先知道）

1. **这份代码没有在本机编译过。** 我没有 macOS 环境，Windows 上无法编译 iOS 工程。语法与 API 我都按 iOS 16+ 保守写法处理了，但首次 CI 构建仍可能报编译错误——把 Actions 日志发我，我直接改。
2. **只支持竖屏**，且只适配 iPhone（`TARGETED_DEVICE_FAMILY = 1`）。
3. **没有美颜**。要磨皮/妆效得自己加 Metal 着色器，那是另一个量级的工作。
4. **地平线检测对纯人像不可靠**，代码里已做降权处理（人脸占主导时给 0.6 保底）。
5. **评分是启发式的**，不是学习出来的美学判断。它擅长发现"主体偏了、地平线歪了、曝过了"这类结构问题，不擅长判断"这张照片有没有味道"。
6. 相册写入用 `.addOnly` 权限，只加不改，不会碰你已有的照片。

---

## 想更进一步

按性价比排序：

1. **先用手上这个版本拍一周**，看提示是否真的帮到你。不准的地方就是该调的参数。
2. 加**九宫格辅助线**（`GridOverlay`），比数字分数更直观。
3. 接一个真正的美学模型：把开源的 `improved-aesthetic-predictor`（CLIP ViT-L/14 线性头，MIT 许可）转成 Core ML，替换 `CompositionScorer` 里的启发式总分。转换用 `coremltools`，在 macOS 上做。
4. 加**连拍取最优**：按住快门连拍 5 张，自动留下分数最高的那张。
