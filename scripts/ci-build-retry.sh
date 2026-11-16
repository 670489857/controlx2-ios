#!/usr/bin/env bash
# IPA 构建重试：每次只做一件事——看最新一次 iOS 流水线，没成就重开一次，成了就把包拉回本地。
#
# 为什么不用 rerun-failed-jobs：对被取消的 run 重跑，GitHub 会在作业创建后立刻再取消一次
# （实测两次都是 steps=[] / runner_name 为空）。workflow_dispatch 是全新 run，行为可预期。
set -uo pipefail

REPO="670489857/controlx2-ios"
ROOT="/home/user/Doubao/chats/38454285704380674/controlx2-ios"
API="https://api.github.com"
TOKEN_FILE="$ROOT/.github-token"

TOKEN=$(tr -d '[:space:]' < "$TOKEN_FILE" 2>/dev/null)
if [ -z "${TOKEN:-}" ]; then
  echo "FATAL: 读不到 $TOKEN_FILE"
  exit 2
fi

api() { curl -s -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" "$@"; }

python_field() { python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('$1',''))"; }

# 最新一次 iOS 流水线（按 workflow 文件过滤，避免把探针 run 看进来）
RUNS=$(api "$API/repos/$REPO/actions/workflows/ios.yml/runs?branch=main&per_page=1")

STATUS=$(echo "$RUNS" | python3 -c "
import json,sys
r=(json.load(sys.stdin).get('workflow_runs') or [{}])[0]
print(r.get('status','none'), r.get('conclusion') or '-', r['id'] if r.get('id') else 0, r.get('run_number',0), (r.get('head_sha') or '')[:7])
")

read -r RSTATUS RCONC RID RNUM RSHA <<< "$STATUS"

if [ "${RID:-0}" = "0" ]; then
  echo "NONE: 还没有 run，触发一次"
  api -X POST "$API/repos/$REPO/actions/workflows/ios.yml/dispatches" -d '{"ref":"main"}' >/dev/null
  exit 0
fi

if [ "$RSTATUS" != "completed" ]; then
  echo "WAIT: run #$RNUM ($RSHA) 仍是 $RSTATUS，可能还压在 macOS 队列里，不重复触发"
  exit 0
fi

if [ "$RCONC" = "success" ]; then
  ARTS=$(api "$API/repos/$REPO/actions/runs/$RID/artifacts")
  AINFO=$(echo "$ARTS" | python3 -c "
import json,sys
a=json.load(sys.stdin).get('artifacts') or []
ipa=[x for x in a if x['name'].endswith('.ipa')]
print((ipa[0]['id'], ipa[0]['name'], ipa[0]['size_in_bytes']) if ipa else (0,'','0'))
")
  read -r AID ANAME ASIZE <<< "$AINFO"
  if [ "${AID:-0}" = "0" ]; then
    echo "SUCCESS-NOART: run #$RNUM 成功但没有 ipa 产物，需要看 build 日志"
    exit 1
  fi

  mkdir -p "$ROOT/dist"
  if [ ! -f "$ROOT/dist/$ANAME.ipa" ]; then
    api -L "$API/repos/$REPO/actions/artifacts/$AID/zip" -o /tmp/$ANAME.zip
    unzip -o -q /tmp/$ANAME.zip -d /tmp/$ANAME-x >/dev/null 2>&1
    FOUND=$(find /tmp/$ANAME-x -name '*.ipa' -type f | head -1)
    [ -n "$FOUND" ] && cp "$FOUND" "$ROOT/dist/$ANAME.ipa"
  fi

  if [ -f "$ROOT/dist/$ANAME.ipa" ]; then
    echo "SUCCESS: run #$RNUM $RSHA -> $ROOT/dist/$ANAME.ipa ($(stat -c%s "$ROOT/dist/$ANAME.ipa") bytes)"
  else
    echo "SUCCESS: run #$RNUM $RSHA 产物 $ANAME ($ASIZE bytes)，但下载失败"
    exit 1
  fi
  exit 0
fi

# 失败或被取消：开一个全新的 run
echo "RETRY: run #$RNUM ($RSHA) 是 $RCONC，重新触发"
api -X POST "$API/repos/$REPO/actions/workflows/ios.yml/dispatches" -d '{"ref":"main"}' >/dev/null
