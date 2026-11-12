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
| 只读状态（API 版本 / 药筒余量 / 泵计时） | ✅ 代码完成 | 需真机核对字段 |
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

## 构建

```bash
# 1) 生成 Xcode 工程（需要 XcodeGen）
brew install xcodegen
xcodegen generate

# 2) 打开并签名
open ControlX2.xcodeproj      # 选择你的开发者账号；真机运行需付费账号
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
└── Session/PumpSession      事务、请求响应配对、配对状态机、只读刷新

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
