# 把 Tandem 泵接进 Loop：可行性与路径评估

结论写在最前面，因为答案是分裂的：**取决于你手上是 t:slim X2 还是 Mobi。**

| 泵型 | 能否接 Loop | 决定因素 |
|---|---|---|
| **Tandem Mobi** | **可行**，但有三个硬约束 | temp rate 指令存在，且泵有 ACE 资质 |
| **t:slim X2** | **不可行** | 协议层没有远程设置临时基础率的指令 |

判定依据不是推测，是 pumpX2 的报文元数据，下面给出逐条证据。

---

## 一、为什么 t:slim X2 走不通

Loop 的闭环执行器只有一个：`enactTempBasal(unitsPerHour:for:completion:)`。没有临时基础率，算法算得再准也无法作用于泵。

pumpX2 中所有能改变基础输注的报文，都标了设备限制：

| 报文 | opCode | 设备限制 | 说明 |
|---|---|---|---|
| `SetTempRateRequest` | `0xA4` (-92) | **MOBI_ONLY** | 设百分比临时基础率 |
| `StopTempRateRequest` | `0xA6` (-90) | **MOBI_ONLY** | 取消临时基础率 |
| `SuspendPumpingRequest` | `0x9C` (-100) | **MOBI_ONLY** | 暂停输注 |
| `ResumePumpingRequest` | `0x9A` (-102) | **MOBI_ONLY** | 恢复输注 |
| `SetModesRequest` | `0xCC` (-52) | **MOBI_ONLY** | 开关 Control-IQ 等模式 |

`SupportedDevices.MOBI_ONLY` 的语义在源码里是硬枚举：

```java
public enum SupportedDevices {
    ALL(TSLIM_X2, MOBI),
    TSLIM_X2_ONLY(TSLIM_X2),
    MOBI_ONLY(MOBI),
}
```

controlX2 的作者在自己的功能列表里也写得很直接：

> Temp Basal and Profile settings (Tandem Mobi only)

他是唯一公开逆向过这套协议的人。他在 X2 上试过，结论是没有这条指令。

需要澄清一个容易混淆的点：**X2 并非完全不能被 App 控制**。`InitiateBolusRequest`（0x9E）的 `supportedDevices` 用了默认值 `ALL`，所以 X2 支持远程大剂量，包括延展大剂量。controlX2 的核心功能就是在 X2 上发 bolus。X2 缺的只是**临时基础率**这一条指令。

想绕过这个限制只有两条路：

- **用 bolus 模拟基础率**：技术上能发出去，但破坏闭环成立的前提，第六节给出定量分析。
- **指望固件升级开放**：X2 的 API 最高到 `API_V3_4`（软件 v7.8），而 temp rate 要求 `MOBI_API_V3_5` 以上。这是产品线划分，不是版本落后。

所以：**X2 用户想上 Loop，只能换泵。**

---

## 二、Mobi 为什么可行

### 监管层面本来就允许

Tandem 官方适应症原文：

> The Tandem Mobi insulin pump with interoperable technology (the pump) is intended for the subcutaneous delivery of insulin, at set and variable rates... The pump is able to reliably and securely communicate with compatible, digitally connected devices, **including automated insulin dosing software, to receive, execute, and confirm commands from these devices**.

Mobi 是 FDA 批准的 **ACE pump（Alternate Controller Enabled）**。它的设计前提就是接受第三方算法下发的指令。这不是钻空子，是产品定位。

`SetTempRateRequest` 的注释也印证了这一点：

> Sets a temp rate for basal delivery. **Note that ControlIQ must be off before setting a temp rate.**

翻译过来：关掉 Tandem 自己的闭环，让外部系统接管。这条路是官方留出来的。

### Loop 侧的接入比想象中轻

Loop 3 有插件机制，泵驱动不需要改 `DeviceDataManager`：

```swift
// Loop/Plugins/PluginManager.swift
public init(pluginsURL: URL? = Bundle.main.privateFrameworksURL) {
    for pluginURL in try FileManager.default.contentsOfDirectory(at: pluginsURL, ...)
        .filter({ $0.path.hasSuffix(".framework") }) {
        if bundle.isLoopPlugin { bundles.append(bundle) }
    }
}
```

一个泵插件就是一个 `.framework`，需要满足：

1. `Info.plist` 里三个 key：`LoopPluginBundleKey.pumpManagerIdentifier` / `pumpManagerDisplayName` / 版本
2. `principalClass` 实现 `PumpManagerUIPlugin`，返回 `pumpManagerType`
3. 实现 `PumpManager` + `PumpManagerUI` 两个协议
4. 在 Loop 的 xcodeproj 里以 Embed & Sign 放进 private frameworks

`availablePumpManagers` 会自动合并 `pluginManager.availablePumpManagers + availableStaticPumpManagers`，所以插件装上就会出现在泵选择列表里。

**这是本次评估里最有价值的发现**：不需要维护一个 Loop 的深度 fork，插件可以独立演进，Loop 升级时冲突面很小。

### PumpX2Kit 能直接复用

已经写完并测过的部分，一行都不用改：

| 模块 | 状态 | 在 Loop 里的角色 |
|---|---|---|
| `Crypto/ECJPAKE.swift`、`P256.swift` | 31 项测试通过 | 配对，与现有 App 完全一致 |
| `Protocol/Packetize.swift` | 对真实抓包校验 | 分片、重组、CRC、HMAC |
| `Messages/Auth.swift` | 双端密钥一致性已验证 | 配对与快速重连 |
| `Session/PumpSession.swift` | 只读刷新稳定 | 改造成 PumpManager 的传输层 |
| `PumpX2BLE/BLETransport.swift` | 未真机验证 | 换成 Loop 的 BLE 调度模型 |

新增的只有 `PumpManager` 适配层，约 2,800–3,200 行。

---

## 三、三个硬约束（这才是真正的难点）

### 约束一：Loop 要绝对速率，Tandem 只认百分比

LoopKit 的签名是绝对速率：

```swift
func enactTempBasal(unitsPerHour: Double, for duration: TimeInterval,
                    completion: @escaping (_ error: PumpManagerError?) -> Void)
```

Tandem 只接受相对当前 profile 基础率的**整数百分比**，范围 0–250%：

```java
public static int MIN_PERCENT = 0;
public static int MAX_PERCENT = 250;
public static byte[] buildCargo(int minutes, int percent) { ... }
```

换算公式是 `percent = round(目标速率 / 当前段基础率 × 100)`。这不是等价变换，误差必须先算清楚再交给算法，否则 Loop 会以为给了 1.2 U/hr，实际只给了 1.176。

我已经把这段逻辑实现成可测试模块 `Sources/TandemLoopKit/TempBasalTranslator.swift`，并写了 19 项测试。关键结论来自实测：

| 场景 | 请求 | 泵能给的 | 偏差 |
|---|---|---|---|
| base 1.0 | 1.25 U/hr | 125% → 1.25 | 0 |
| base 0.8 | 1.05 U/hr | 131% → 1.048 | −0.002（−0.2%） |
| base 2.0 | 5.0 U/hr | 250% → 5.0 | 0 |
| **base 2.0** | **6.0 U/hr** | **250% → 5.0** | **−1.0（−16.7%）** |
| **base 0.1（儿童夜间）** | **0.3 U/hr** | **250% → 0.25** | **−0.05（−16.7%）** |
| base 0 | 任意正值 | 无法表达 | 拒绝 |

成人常见 profile 下的量化误差在 0.5% 以内，可以接受。真正的问题是两个：

**① 250% 上限是硬天花板。** 泵能给的最高速率永远是当前段基础率的 2.5 倍。base 0.8 的成人，上限 2.0 U/hr；base 0.1 的儿童夜间，上限只有 0.25 U/hr。Loop 想给 0.3 却只能给 0.25，**这不是误差，是能力缺失**。

对策是必须诚实地把 `maximumBasalRate` 报成 `2.5 × max(profile 基础率)`，并让 `roundToSupportedBasalRate` 返回真实可实现的值。如果谎报成 3.0，Loop 的预测会持续乐观，表现为"按算法给了足量却一直偏高"。

**② base = 0 的时段完全无法加基础率。** 0 的任意百分比还是 0。这类 profile 需要在上层拒绝并提示用户改 profile。

**③ 跨段边界会改变实际速率。** 临时基础率期间若跨过 profile 段边界，泵按新段 base 乘同一百分比，实际速率跳变。我的处理是把下发时长截到边界前；距边界不足 15 分钟（泵的最小时长）时无法截断，只能接受一个 cycle 的不精确，由下一轮 cycle 立刻纠正。

### 约束二：必须关掉 Control-IQ

`SetTempRateRequest` 的前提是 Control-IQ 关闭。这意味着：

- 你放弃 Tandem 自己那套算法（Control-IQ+ 真实世界 TIR 约 71%）
- 泵退回普通模式，完全由 Loop 决定基础输注
- 手机上 Loop 崩了、没电了、被杀后台，泵会在 temp rate 到期后回落到 profile 基础率——注意，**回落的是 profile，不是 Loop 最后想要的速率**，这反而是安全兜底

这条没有技术解法，是使用方式的改变。做决定前先想清楚：你是在用 Loop 换 Control-IQ+，不是叠加。

### 约束三：iOS 后台 BLE 保活（最大未知）

Loop 每 5 分钟一个 cycle，要求 App 能持续唤醒连泵。iOS 没有 Android 的前台服务，只能靠 `bluetooth-central` 后台模式加状态恢复。

参考先例：Loop 支持 Dana 泵的 BLE 直连（DanaKit），说明 iPhone 直连 BLE 泵在 Loop 里是成立的。但 Tandem 的连接参数（连接间隔、从机延迟、是否要求系统级 bonding）与 Dana 不同，**这一条只能真机验证，读代码回答不了**。

如果保活不成立，Loop 会频繁报 "Pump not connected"，闭环断断续续，体验不如 Control-IQ。

---

## 四、要写什么、写多久

### 代码清单

| 模块 | 行数 | 难度 | 说明 |
|---|---|---|---|
| `TandemPumpManager`（协议实现） | 400 | 中 | status、`ensureCurrentPumpData`、观察者 |
| `enactTempBasal` 适配 | 150 | 低 | translator 已就绪，接上 SetTempRate 即可 |
| `enactBolus` / `cancelBolus` | 350 | **高** | 必须走 BolusPermission 票据流程，不能裸发 |
| `suspend` / `resume` | 80 | 低 | 两条无载荷指令 |
| `syncBasalRateSchedule` | 400 | **高** | 写 IDP 需要 Create + SetSegment × N + SetActive |
| 泵事件映射（history log → `NewPumpEvent`） | 700 | **高** | 最琐碎，IOB 准不准全看这里 |
| `PumpManagerUI`（onboarding + 状态页） | 700 | 中 | 配对界面可复用现有 SwiftUI |
| 插件打包与工程集成 | 100 + 配置 | 中 | Info.plist、principal class、xcodeproj |

事件映射值得单独说：Loop 的 IOB 完全依赖泵上报的每一次输注事件。Tandem 的 history log 有 30 多种记录类型（`BolusDelivered`、`BasalDelivery`、`TempRateActivated`、`PumpingSuspended`…），controlX2 的 `db` 模块已经做了解析，可以对照移植。这块如果映射错，表现是"Loop 显示的 IOB 与泵不一致"，然后算法基于错的 IOB 给量——**这是最危险的错误类型**。

### 工期

| 阶段 | 单人耗时 | 交付判定 |
|---|---|---|
| 插件骨架 + 配对 + 只读状态 | 2 周 | Loop 里能添加泵、能读到数据 |
| temp basal 闭环 | 2 周 | Loop 能下指令、泵速率跟着变 |
| bolus + 事件历史 | 3 周 | IOB 与泵一致 |
| UI + 设置同步 | 1.5 周 | 可日常使用 |
| 真机联调（后台保活、固件差异） | 2–6 周 | 不确定项 |

**能跑起来约 4 周，能放心日常用 8–14 周。** 上限取决于后台保活，那部分不是写代码能解决的。

---

## 五、验证顺序（别跳步）

1. **确认泵型**。X2 到此为止，不用往下看。
2. **确认 Mobi 固件 API ≥ 3.5**（`MOBI_API_V3_5`），否则 temp rate 报文不存在。
3. **确认能关闭 Control-IQ**，并在关闭后仍能正常输注。
4. **真机验证 temp rate**：用现有 App 发一条 100%/30 分钟，看泵屏幕（或官方 App）是否显示临时基础率。这一步通过，协议层就通了。
5. **验证后台保活**：App 进后台、锁屏 30 分钟，看连接是否还在。**这一步决定 Loop 能不能用。**
6. **验证 250% 上限的行为**：发 250%，确认泵接受且实际速率 = 2.5 × base。
7. 再开始写 PumpManager。

第 4、5 步我用现有 App 就能做——`SetTempRateRequest` 只要在 `PumpSession` 里加一个方法，不需要 Loop。这是最便宜的验证方式。

---

## 六、为什么不用微型 bolus 模拟基础率

这是最容易被想到的绕过办法：既然 X2 不能设临时基础率，那就每 5 分钟发一个 0.05 U 的 bolus，等效成基础输注。技术上能发出去，但闭环会失效，原因分六层，前两层是结构性的，后四层是量化的。

### 6.1 算法层：Loop 的控制器不产生这种指令

LoopKit 的自动剂量推荐结构是：

```swift
public struct AutomaticDoseRecommendation: Equatable {
    public let basalAdjustment: TempBasalRecommendation?
    public let bolusUnits: Double?
}
```

`basalAdjustment` 是连续可调的临时基础率，`bolusUnits` 是叠加其上的校正剂量（SMB，原生 Loop 不填，Trio/iAPS 才用）。**两者不是替代关系**：SMB 的前提是仍然有 basal 在跑。要"用 bolus 替代 basal"，必须改算法层，而不是改驱动层。

### 6.2 驱动层：上报的事件对不上账

Loop 下发 temp basal，期望泵回 `BasalDeliveryHistoryLog`；实际执行的是 bolus，泵回 `BolusDeliveryHistoryLog`。Loop 的 `PumpManagerStatus` 会判定 `deliveryIsUncertain`，触发报警并暂停闭环。这是结构性的不匹配，调参数解决不了。

### 6.3 量化精度：差 10 到 60 倍

`InitiateBolusRequest` 的硬常量是 `MIN_BOLUS_MILLIUNITS = 50`（0.05 U）。这个步进决定了等效速率的分辨率：

| 粒度 | 等效速率只能是 | 典型误差 |
|---|---|---|
| 5 分钟一次（Loop 一个 cycle） | **0.6 U/hr 的整数倍** | 0.05–0.3 U/hr 完全无法表达（−100%）；0.5、1.0 U/hr 误差 ±20% |
| 30 分钟一次（拉长到 temp basal 时长） | **0.1 U/hr 的整数倍** | 0.05 U/hr 无法表达；0.25 U/hr 误差 −20% |
| temp basal（base 1.0，1% 步进） | 0.01 U/hr | < 0.5% |
| temp basal（base 0.5，1% 步进） | 0.005 U/hr | < 0.5% |

闭环需要的是连续调节，而 5 分钟粒度下 bolus 只能表达 0 / 0.6 / 1.2 U/hr 这几个离散值。这已经不是在调节基础率，是在开关一个 0.6 U/hr 的泵。

### 6.4 不可撤销性

temp basal 可以随时改速率，设 0% 立即停止基础输注。bolus 一旦开始输注，只能取消剩余部分，已输进去的收不回来。

闭环的安全性依赖"判断错了能在一个 cycle 内收回"。bolus 破坏的正是这个前提：算法的单次误判会直接变成不可撤回的胰岛素。

### 6.5 泵端 IOB 失真

Tandem 会为每个 bolus 累加 IOB。一天 144–288 个 bolus 全部落在 6 小时 DIA 窗口内，泵显示的 IOB 会是真实基础 IOB 的数倍。即使关掉 Control-IQ，泵自身的低血糖预警也建立在错误的 IOB 上。

### 6.6 票据独占与往返开销

每次 bolus 是两步：`BolusPermissionRequest`（0xA2）拿票据 → `InitiateBolusRequest`（0x9E）带 `bolusID` 执行。票据是独占的，`NackReason.PUMP_HAS_PERMISSION` 表示泵已把权限给了别的客户端——官方 t:connect App 持有票据时，第三方会被直接拒绝。一天 288 次申请，每次两次往返，BLE 失败率会累积。

### 6.7 那延展大剂量呢

延展 bolus 是均匀输注，机制上确实等价于基础率，是 bolus 路线里唯一像样的选项。但它受 `MIN_EXTENDED_BOLUS_MILLIUNITS = 400`（0.40 U）约束：

| 基础率 | 0.40 U 相当于 | 实际含义 |
|---|---|---|
| 0.10 U/hr | 240 分钟 | 一次要设 4 小时，期间不能调速 |
| 0.25 U/hr | 96 分钟 | 调节延迟超过 1.5 小时 |
| 0.50 U/hr | 48 分钟 | 勉强可用 |
| 1.00 U/hr | 24 分钟 | 可用 |
| 2.00 U/hr | 12 分钟 | 可用 |

而且延展期间**不能改速率，只能取消重发**，又是两次往返加一次票据申请。

结论：延展 bolus 只在基础率高于约 1 U/hr 时勉强跟得上，而低基础率恰恰是最需要精细调节的场景。它不是 temp basal 的替代品。

### 6.8 一句话

"用 bolus 模拟基础率"在工程上发得出去，但它同时破坏了闭环的三根支柱：**指令可撤销、速率可连续、事件可对账**。不是能不能做的问题，是做出来也不能用。

---

## 七、如果不做 Loop

按投入产出排序：

1. **继续用 Control-IQ+，把现有 App 当数据看板**。Control-IQ+ 的 TIR 数据很难被 DIY 方案超过，你真正缺的可能是数据自主和报警外推，不是算法。
2. **换 Omnipod 5 / DASH 接 Loop**。Loop 3.14.7 已正式支持 Omnipod 5，这条路的成熟度高一个数量级，且不需要逆向。
3. **用 Trio（原 FreeAPS X）**。同样是 LoopKit 生态，多了 SMB，泵驱动的要求与 Loop 相同——所以约束一、二、三一条都跑不掉。
4. **自己写一个轻量闭环**，不走 Loop。算法、安全限幅、报警全自己负责。工作量不比接 Loop 小，但没有社区验证，不建议。

---

## 八、已经落地的部分

本轮不是只写评估，`Sources/TandemLoopKit/TempBasalTranslator.swift` 已经实现并通过 19 项测试（全仓 50 项全绿）：

- `BasalSchedule` / `BasalSegment`：与 `IDPSegmentResponse` 一一对应的基础率计划模型，含段查找、边界计算、跨零点处理
- `TempBasalTranslator.translate(...)`：绝对速率 → 百分比，返回 `percent`、`effectiveRate`、`rateError`、`saturation`、`truncatedAtSegmentBoundary`
- 明确区分三种情况：正常换算、四舍五入偏差（`.rounding`）、撞 250% 上限（`.highLimit`）
- 失败路径：零基础率、时长越界、负速率、计划格式错误

这个模块是整个移植里唯一有算法风险的部分，现在它可测、可复算。剩下的都是工程量，不是未知数。
