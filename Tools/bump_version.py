#!/usr/bin/env python3
"""改版本号。一次改完三处，避免 VERSION 与 project.yml 漂移导致 CI 直接失败。

用法:
    python3 Tools/bump_version.py 0.2.1     # 指定版本
    python3 Tools/bump_version.py patch     # 0.2.1 -> 0.2.2
    python3 Tools/bump_version.py minor     # 0.2.1 -> 0.3.0
    python3 Tools/bump_version.py major     # 0.2.1 -> 1.0.0
    python3 Tools/bump_version.py --show    # 只看当前版本

只改文件，不提交。改完自己 commit + push，CI 会按新版本出包。
"""

import datetime
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VERSION_FILE = ROOT / "VERSION"
PROJECT_YML = ROOT / "project.yml"
CHANGELOG = ROOT / "CHANGELOG.md"

SEMVER = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")


def read_version() -> str:
    if not VERSION_FILE.exists():
        sys.exit("找不到 VERSION 文件")
    return VERSION_FILE.read_text().strip()


def bump(current: str, part: str) -> str:
    m = SEMVER.match(current)
    if not m:
        sys.exit(f"VERSION 里的 {current!r} 不是 x.y.z 格式")
    major, minor, patch = (int(x) for x in m.groups())
    if part == "major":
        return f"{major + 1}.0.0"
    if part == "minor":
        return f"{major}.{minor + 1}.0"
    if part == "patch":
        return f"{major}.{minor}.{patch + 1}"
    sys.exit(f"不认识的递增方式: {part}")


def write_version(new: str) -> None:
    if not SEMVER.match(new):
        sys.exit(f"{new!r} 不是 x.y.z 格式")

    VERSION_FILE.write_text(new + "\n")

    spec = PROJECT_YML.read_text()
    pattern = re.compile(r'(MARKETING_VERSION: *)"[^"]+"')

    def replace(match: re.Match) -> str:
        return f'{match.group(1)}"{new}"'

    spec, count = pattern.subn(replace, spec, count=1)
    if count != 1:
        sys.exit("project.yml 里没找到 MARKETING_VERSION，无法同步")
    PROJECT_YML.write_text(spec)

    insert_changelog_entry(new)


def insert_changelog_entry(new: str) -> None:
    """在 CHANGELOG 顶部插入新版本小节。已存在则跳过，允许先手写再 bump。"""
    text = CHANGELOG.read_text()
    heading = f"## {new}"
    if heading in text:
        print(f"CHANGELOG 已有 {new} 小节，跳过")
        return

    today = datetime.date.today().isoformat()
    entry = f"{heading} — {today}\n\n### 变更\n\n- （在这里写这一版改了什么）\n\n"

    marker = "产物命名："
    idx = text.find(marker)
    if idx == -1:
        # 没有约定的分隔段落时插到第一个二级标题之前
        idx = text.find("\n## ")
        idx = 0 if idx == -1 else idx + 1
        CHANGELOG.write_text(text[:idx] + entry + text[idx:])
        return

    end = text.find("\n## ", idx)
    if end == -1:
        CHANGELOG.write_text(text.rstrip() + "\n\n" + entry)
        return
    CHANGELOG.write_text(text[: end + 1] + entry + text[end + 1 :])


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)

    arg = sys.argv[1]
    current = read_version()

    if arg in ("--show", "-s"):
        print(current)
        return

    new = bump(current, arg) if arg in ("major", "minor", "patch") else arg
    if new == current:
        sys.exit(f"版本没变化，还是 {current}")

    write_version(new)
    print(f"版本 {current} -> {new}")
    print("已同步: VERSION, project.yml, CHANGELOG.md")
    print("")
    print("下一步:")
    print("  git add -A && git commit -m \"release: v" + new + "\" && git push")
    print("  CI 会产出 ControlX2-" + new + "-b<构建号>-<sha>.ipa")


if __name__ == "__main__":
    main()
