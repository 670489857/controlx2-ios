# 第三方代码与许可

## jwoglom/pumpX2

本项目的协议实现（帧格式、CRC16、HMAC 签名、EC-JPAKE、消息 opCode 表）移植自：

- https://github.com/jwoglom/pumpx2
- MIT License, Copyright (c) 2022 James Woglom

```
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

其中 `ECJPAKE.swift` 的算法结构对应 pumpX2 的 `io.particle.crypto.EcJpake`，
后者基于 mbed TLS 的 EC-JPAKE 实现（Apache-2.0, Copyright ARM Limited）。

## jwoglom/controlX2

- https://github.com/jwoglom/controlX2
- 仓库**未提供 LICENSE 文件**，默认保留所有权利。

本仓库未复制其 Kotlin/Compose 源码；仅参考了 README 中公开的功能清单与交互流程。
如果你计划公开分发本项目，建议先联系上游作者确认 App 层行为的授权。
