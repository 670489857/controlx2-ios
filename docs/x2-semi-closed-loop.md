# t:slim X2 上能做成什么：半闭环的实际形态

## 一、先把话说清楚

**X2 上做不出 Loop 那种闭环，但不是因为算法不行，是因为执行器缺了两个方向。**

闭环控制需要执行器能双向调节。X2 的协议层给出的通道是：

| 能力 | 报文 | X2 是否支持 |
|---|---|---|
| 调基础率 | `SetTempRateRequest` 0xA4 | 否，`MOBI_ONLY` |
| 停基础率 | `StopTempRateRequest` 0xA6 | 否，`MOBI_ONLY` |
| **暂停输注** | `SuspendPumpingRequest` 0x9C | 否，`MOBI_ONLY` |
| 恢复输注 | `ResumePumpingRequest` 0x9A | 否，`MOBI_ONLY` |
| **大剂量** | `InitiateBolusRequest` 0x9E | **是**（默认 `ALL`） |
| 读状态 | 各类 `Current*` | 是 |

能读、能加、**不能减、不能停**。这在控制论上不是"精度差一点"，是缺少负向通道。

Loop 的安全模型建立在"判断错了能在下一个 cycle 收回"上：temp basal 可以立刻降到 0%，指令可撤销。X2 上唯一的写入通道是 bolus，一旦开始输注就只能取消剩余，已经进去的收不回来，而且**连急停都做不到**——`Suspend` 也是 MOBI_ONLY。

所以判断很直接：在 X2 上做全自动闭环，等于把回路建在一个只进不出的阀上。

## 二、那"类似 Loop 的软件"能做成什么

拆成三层，边界清楚：

### L1 数据面（已实现）

- BLE 直连泵，读 CGM、IOB、基础率、药筒余量、电量、泵计时
- CGM 采样环形缓冲（720 条 ≈ 60 小时），原子落盘
- 用最近 15 分钟最小二乘拟合斜率，比泵的趋势码细
- 后续：14 天 AGP、TIR 报告、Nightscout 上传、报警外推

这一层**没有任何协议风险**，全是读。价值在于 t:connect 在中国区基本不可用，数据自主是真需求。

### L2 建议层（已实现）

就是 Loop 的大脑，只是不接执行器：

- 胰岛素活性曲线（Walsh 分段线性，峰值消耗 50%）
- 血糖预测 `bg(t) = bg₀ − ISF·IOB·(1−R(t)) + COB·(ISF/CR)·A(t)`
- 九道安全闸门，命中任一即不给建议，并说明理由
- 影子模式：每 5 分钟记录"如果自动会给多少"，**一条指令都不发**

### L3 自动执行（刻意不做）

理由在第一节。如果一定要做，前提是影子模式先跑够两周，且下面三条全部成立：

1. hold 比例合理（大量 hold 说明参数没配好，不是算法保守）
2. 建议剂量分布没有抖动（同一小时内反复 0 / 1.5 / 0）
3. 回看真实 CGM，建议方向的正确率显著高于随机

即使都成立，单次剂量也应压在 0.1–0.2 U，且必须有日累计上限。因为刹车不在你手里。

## 三、为什么不走 Loop 插件

Loop 3 的泵驱动是一个 `.framework`，实现 `PumpManager` 协议即可挂进去。这条路对 Mobi 成立，对 X2 不成立，原因在协议本身：

```swift
func enactTempBasal(unitsPerHour: Double, for duration: TimeInterval,
                    completion: @escaping (PumpManagerError?) -> Void)
```

`PumpManager` 的核心方法就是临时基础率。X2 没有这条指令，任何"绕过去"的实现都会让 Loop 的 `PumpManagerStatus` 判定 `deliveryIsUncertain`，触发报警并暂停闭环——不是在跑闭环，是在跑一个不断自我中断的循环。

所以这一版是**独立 App**，借用 Loop 的数学思路（`eventualBG`、`AutomaticDoseRecommendation` 的语义），但不背 Loop 的协议契约。

## 四、已经落地的代码

```
Sources/X2Advisor/
  InsulinActivityModel.swift   活性曲线，Walsh 分段线性
  GlucoseHistory.swift         采样、去重、环形缓冲、斜率拟合
  BGPPredictor.swift           4 小时预测 + 低/高血糖穿越时间
  DoseAdvisor.swift            九道闸门 + 剂量计算 + 截断
  ShadowLog.swift              JSONL 追加写、CSV 导出、统计摘要
```

44 项测试，与既有 50 项合计 94 项全绿。

### 一道必须说明的设计取舍

第一版活性曲线用的是 Gamma(shape = 2)，数学上干净、有闭式解。但它有个要命的性质：**峰值时刻只消耗 26% 的活性**（CDF 在 `t = τ` 处为 `1 − 2/e`），而临床观察是 40–50%。

这个偏差的方向是危险的——模型低估即将发生的降糖，就会建议更多胰岛素。所以换成了 Walsh 分段线性，代价是预测曲线在峰值处有个折角。折角是模型的真实形状，展示时不该抹平。

## 五、九道闸门

按顺序检查，任一条不过就 `hold`：

| # | 检查 | 拒绝理由 |
|---|---|---|
| 1 | 有无 CGM | `cgmMissing` |
| 2 | CGM 是否过期（> 15 分钟） | `cgmStale` |
| 3 | 当前血糖 ≥ 追加阈值 | `glucoseTooLow` |
| 4 | 不在快速下降（≤ −1 mg/dL/min） | `fallingFast` |
| 5 | IOB ≤ 上限 | `iobTooHigh` |
| 6 | 距上次给药 ≥ 45 分钟 | `doseTooRecent` |
| 7 | 预测 2 小时内不跌破低血糖 | `predictedLow` |
| 8 | 预测稳态高于目标 | `predictedInRange` |
| 9 | 剂量 ≥ 泵最小步进 0.05 U | `doseTooSmall` |

第 7 条排在剂量计算之前，因为"预测要低血糖"的优先级高于"现在偏高"。

## 六、验证顺序（别跳）

1. **影子模式跑两周**，什么都不发
2. 看 `summary`：hold 比例、各类 hold 的分布、建议剂量直方图
3. 导出 CSV，逐条对照当时的真实 CGM，问"如果给了会怎样"
4. 出现下列任一情况就回到参数调整，不要往下走：
   - 同一小时内建议在 0 和 1 U 以上之间跳
   - `fallingFast` 占比过低（说明斜率拟合有问题）
   - 建议剂量频繁撞单次上限（说明 ISF 或目标设错了）
5. 参数稳定后再讨论要不要执行，且执行也要限幅

## 七、如果目标真的是闭环

按代价排序：

1. **换 Mobi**。协议支持 temp basal，是 FDA 批准的 ACE 设备，可以接 Loop 插件，也可以自己写控制器。这是唯一不离谱的路。
2. **换 Omnipod 5 接 Loop**。Loop 3.14.7 正式支持，不需要逆向。
3. **留着 X2 用 Control-IQ+**。TIR 约 71%，很难被 DIY 超过。真正缺的可能是数据和报警，不是算法——那正是 L1 在补的。

## 八、已知未验证

- 真机配对与影子模式连续运行（需要 X2 在手）
- iOS 后台保活：App 进后台 30 分钟后连接是否还在
- IOB 来源为泵上报的净 IOB，受 Control-IQ 计算方式影响；若要更准需解析 history log 自己算
- ISF / CR 目前手填，后续可从 `BolusCalcDataSnapshot` 读取，与泵内保持一致
