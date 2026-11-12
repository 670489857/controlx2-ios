# ControlX2 · iOS

Tandem t:slim X2 / Mobi 胰岛素泵的 iOS 客户端，协议层由 [pumpX2](https://github.com/jwoglom/pumpx2)（MIT）移植而来。

> ## 安全声明
> 本仓库是**实验性研究工具**，未经任何监管机构批准，与 Tandem、Dexcom 无任何关联。
> **当前版本只做配对与只读状态，不包含任何输注指令。** 任何治疗决定必须以泵屏幕为准。
> 读数可能滞后或错误；使用风险自负。

---

## 当前实现范围（v0.1）

| 能力 | 状态 | 说明 |
|---|---|---|
| BLE 扫描 / 连接 / 通知订阅 | ✅ 代码完成 | `Sources/PumpX2BLE/BLETransport.swift`，需真机验证 |
| 帧封包 / 分片 / 重组 / CRC16 | ✅ 已测试 | 与 pumpX2 抓包向量逐字节一致 |
| HMAC-SHA1 签名报文 | ✅ 已测试 | 含 `pumpTimeSinceReset` 参与签名 |
| EC-JPAKE 配对（P-256） | ✅ 已测试 | 客户端/服务端双端派生同一密钥 |
| 6 位配对码流程 | ✅ 代码完成 | 中央挑战 → 泵挑战 → JPAKE 1a/1b/2/3/4 |
| 血糖 + 趋势箭头 | ✅ 已实现 | `EGV(0x22/0x23)`，int16 mg/dL |
| 活性胰岛素 IOB | ✅ 已实现 | `ControlIQIOB(0x6C/0x6D)`，÷1000 U |
| 药筒余量 | ✅ 已实现 | `InsulinStatus(0x24/0x25)` |
| 电量 / 基础率 | ✅ 已实现 | `BatteryV1(0x34/0x35)`、`BasalStatus(0x28/0x29)` |
| 配对密钥持久化（免重复输入配对码） | ✅ 已实现 | Keychain 存 `derivedSecret` + `appInstanceId`，重连走 `0x26` 快速确认 |
| 历史日志 / 曲线 | ⛔ 未实现 | 需 `HistoryLog` 流式解析 |
| 大剂量 / 基础率 / 暂停 | ⛔ 未实现 | 见「为什么不开放给药」 |
| watchOS App / 复杂功能 | ⛔ 未实现 | 规划中 |

## 已验证的部分

在 Linux 上用 Swift 6.1 跑通 21 个单元测试（`swift test`）：

- SHA-256 / SHA-1 / HMAC-SHA1 / HMAC-SHA256：RFC 2202、RFC 4231、NIST 向量
- CRC16 与组包：与 pumpX2 `BTResponseParserTest` 的真实抓包十六进制逐字节一致
- 分片与重组往返、坏 CRC 拒绝、签名报文验签
- P-256：对 2G、3G、任意 128 位标量、n-1 的坐标与独立实现（Python 大整数）一致
- 蒙哥马利乘法 / 标量乘：200 组随机值对照「移位加法」慢速实现
- EC-JPAKE：客户端与服务端各自完成两轮 ZKP 后派生**相同**的 32 字节密钥；错误配对码则不同

未验证：任何真机 BLE 行为、泵的配对接受、字段语义。

## 现成产物

`ControlX2-unsigned.ipa`（260 KB，arm64，iOS 17+，构建号 `d25bd39`）由 GitHub Actions 的 macOS runner 编译产出：

```
SHA-256: f09417637192e687a0da0c5ed9e619e8113525ae15c4a7c92e70d00ea890ad7b
```

**未签名**，iOS 会拒绝直接安装，必须先用 Apple ID 重签（见下方「云端构建」）。签名后即可在真机运行，首次启动需连接泵并输入配对码。

## 已知限制（比功能缺失更重要）

1. **快速重连协议未在真机验证**。首次配对成功后，`derivedSecret`（32 字节）与 `appInstanceId` 存入 Keychain，之后连接跳过 JPAKE 前三轮，直接发 `0x26` 做第 3、4 步确认。这套流程依据 pumpX2 的 `CONFIRM_INITIAL` 分支实现，但「泵是否接受跳过前三轮」只能真机确认。若不接受，会自动删除凭据并退回输入配对码，不会卡死。
2. **息屏后连接会被系统挂起**。`bluetooth-central` 后台模式只能延长存活，无法像 Android 前台服务那样常驻。血糖不会持续刷新。
3. **字段语义未在真机核对**。血糖、IOB、基础率的字节偏移来自 pumpX2 的解析代码，量纲按 `÷1000` 换算，但「泵实际返回值是否与解析一致」只能在真机上看。
4. **16 位配对码里的字母不参与密钥**。pumpX2 的 `charCode` 把 `'0'–'9'` 映射为 ASCII，其余字符一律返回 `(byte)-1`（0xFF），本实现照此对齐。也就是说 16 位码中字母位置的信息被折叠成同一个字节。如果旧固件配对始终失败，这是第一个要怀疑的点 —— 需要真机抓包确认泵侧是否用了别的编码。

## 构建

### 方式一：云端构建（不需要 Mac）

推送到 `main` 或手动触发 `iOS` workflow，GitHub 会在 macOS runner 上编译，产出**未签名** `ControlX2-unsigned.ipa`：

```
仓库 → Actions → iOS → 最近一次运行 → Artifacts → ControlX2-unsigned-ipa
```

流水线做两件事：`ubuntu` 容器里跑 `swift test`（协议层，几秒），`macos-15` 上 `xcodegen` + `xcodebuild` 出包。编译失败时 `build-log` artifact 里有完整日志。

> 私有仓库的 macOS runner 按 **10 倍**分钟计费，一次构建约消耗 50–80 分钟额度。公开仓库免费。

拿到 IPA 后需要自签才能安装（未签名包 iOS 会直接拒绝）：

| 工具 | 平台 | 说明 |
|---|---|---|
| Sideloadly | Win/macOS | 拖入 IPA，填 Apple ID，7 天有效 |
| AltStore / SideStore | Win/macOS | 需常驻电脑或配对设备续签 |
| Xcode | macOS | `Devices and Simulators` 里拖入 IPA |

免费 Apple ID 签名有效期 7 天，到期需重签；付费开发者账号 1 年。

### 方式二：本地 Xcode

```bash
brew install xcodegen
xcodegen generate
open ControlX2.xcodeproj      # 选择 Team，真机运行
```

命令行跑协议层测试（不需要 Xcode，macOS 或 Linux 均可）：

```bash
swift test
swift test -c release        # 加密运算在 release 下快约 10 倍
```

## 架构

```
Sources/PumpX2Kit/           纯 Swift，无 Apple 私有依赖，可在 Linux 跑测试
├── Support/                 Hex、CRC16、字节工具
├── Crypto/                  SHA/HMAC/HKDF、U256+蒙哥马利、P-256、EC-JPAKE
├── Protocol/                Message/MessageMeta、注册表（自动生成）、组包、重组
├── Messages/                认证报文构造与解析
└── Session/
    ├── PumpSession          事务、请求响应配对、配对/恢复状态机、只读刷新
    └── Credentials          配对凭据结构与 Keychain / 内存存储

Sources/PumpX2BLE/           CoreBluetooth 传输（#if canImport(CoreBluetooth)）
App/                         SwiftUI 界面：免责声明 → 扫描 → 配对 → 状态

Tools/generate_registry.py   从 pumpX2 的 @MessageProps 生成 274 条协议元数据
Tools/message_catalog.json   上述元数据的中间产物
```

协议要点：

- 帧格式 `opCode | txId | len | cargo [| 4B timeSinceReset | 20B HMAC-SHA1] | CRC16`，按 18 字节（control 请求 40 字节）逆序切片
- 配对：`CentralChallenge` → `PumpChallenge`（HMAC-SHA1 空消息）→ EC-JPAKE 1a/1b/2/3/4 → 会话密钥
- 签名：影响输注的报文用会话密钥做 HMAC-SHA1，尾部附带 4 字节泵计时

## 为什么不开放给药

向泵写入输注指令需要额外满足：`BolusPermission` 权限票据、带签名的 `InitiateBolus`、剂量上下限、断连重放保护、确认超时。任何一项在真机上出错都可能造成过量或不足输注。这些必须在有备用泵、可完整记录日志的条件下逐条验证，而不是在模拟器里「看起来能跑」就放开。

## iOS 与 Android 版的差异（不是 bug）

| 项 | Android (ControlX2) | iOS |
|---|---|---|
| 后台常驻 | 前台服务常驻连接 | 仅 `bluetooth-central` 后台模式，系统可随时挂起 |
| 设备标识 | 可读 MAC | 只有 per-app UUID，重装会变 |
| 手表 | Wear OS 经手机中转 | 需 watchOS + WatchConnectivity，同样经手机 |
| 分发 | APK 侧载 | 需签名；App Store 上架需医疗器械资质 |

## 许可与归属

- 协议实现参考 [jwoglom/pumpX2](https://github.com/jwoglom/pumpx2)，**MIT License**，其版权声明见 `THIRD_PARTY.md`。
- 上游 App [jwoglom/controlX2](https://github.com/jwoglom/controlX2) **未附任何许可证**，因此本仓库未复制其 Kotlin/Compose 代码，只参考公开的协议行为与 UI 功能面。
- 本仓库代码由你自行决定许可证；在公开发布前建议先取得上游作者对 App 层行为的确认。
