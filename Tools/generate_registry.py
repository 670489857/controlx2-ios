#!/usr/bin/env python3
"""从 pumpX2 的 Java 注解目录生成 Swift 注册表。

输入：由 parse_messages.py 产出的 message_catalog.json
      （每条含 cls / opCode / size / type / characteristic / signed / stream）
输出：Sources/PumpX2Kit/Protocol/Registry.generated.swift
"""
import json, sys, os

CATALOG = sys.argv[1] if len(sys.argv) > 1 else "message_catalog.json"
OUT = sys.argv[2] if len(sys.argv) > 2 else "Sources/PumpX2Kit/Protocol/Registry.generated.swift"

CHARS = {
    "Characteristic.CURRENT_STATUS": "currentStatus",
    "Characteristic.HISTORY_LOG": "historyLog",
    "Characteristic.AUTHORIZATION": "authorization",
    "Characteristic.CONTROL": "control",
    "Characteristic.CONTROL_STREAM": "controlStream",
}

rows = json.load(open(CATALOG))
entries = []
seen = set()
for r in rows:
    if not r.get("opCode") or not r.get("cls"):
        continue
    op = int(r["opCode"], 0) if isinstance(r["opCode"], str) and not r["opCode"].lstrip("-").isdigit() else int(r["opCode"])
    op &= 0xFF
    size = int(r["size"]) if r.get("size") else 0
    mtype = "request" if "REQUEST" in (r.get("type") or "") else "response"
    ch = CHARS.get(r.get("characteristic") or "", "currentStatus")
    signed = "true" if r.get("signed") == "true" else "false"
    stream = "true" if r.get("stream") == "true" else "false"
    key = (ch, op, mtype)
    if key in seen:
        continue
    seen.add(key)
    entries.append((op, size, mtype, ch, signed, stream, r["cls"]))

entries.sort(key=lambda e: (e[3], e[0], e[2]))

lines = [
    "// 该文件由 Tools/generate_registry.py 从 pumpX2 的 @MessageProps 注解自动生成，请勿手工编辑。",
    "// 来源：jwoglom/pumpX2（MIT License）",
    "",
    "extension MessageRegistry {",
    "    static let generatedEntries: [MessageRegistry.Entry] = [",
]
for op, size, mtype, ch, signed, stream, cls in entries:
    lines.append(
        f'        .init(opCode: 0x{op:02X}, size: {size}, type: .{mtype}, characteristic: .{ch}, '
        f'signed: {signed}, stream: {stream}, name: "{cls}"),'
    )
lines += ["    ]", "}", ""]

os.makedirs(os.path.dirname(OUT), exist_ok=True)
open(OUT, "w").write("\n".join(lines))
print(f"wrote {OUT}: {len(entries)} entries")
