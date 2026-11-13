// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ControlX2iOS",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PumpX2Kit", targets: ["PumpX2Kit"]),
        .library(name: "PumpX2BLE", targets: ["PumpX2BLE"]),
        .library(name: "TandemLoopKit", targets: ["TandemLoopKit"]),
    ],
    targets: [
        .target(name: "PumpX2Kit"),
        // CoreBluetooth 只在 Apple 平台存在；Linux 上该 target 编译为空壳，保证 CI 可跑协议层测试
        .target(name: "PumpX2BLE", dependencies: ["PumpX2Kit"]),
        // LoopKit PumpManager 的适配层：泵无关的换算与模型，可在 Linux 上验证
        .target(name: "TandemLoopKit", dependencies: ["PumpX2Kit"]),
        .testTarget(name: "PumpX2KitTests", dependencies: ["PumpX2Kit"]),
        .testTarget(name: "TandemLoopKitTests", dependencies: ["TandemLoopKit"]),
    ]
)
