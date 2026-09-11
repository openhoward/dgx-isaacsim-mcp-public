#!/usr/bin/env bash
#
# 從 DGX 上的真實組態同步到這個 repo。在 DGX 本機執行。
#
# 兩道機制：
#   1. 白名單 —— 只有下面列出的檔案會被複製。私鑰、token、gateway.env、
#      audit.log、備份目錄不在清單上，所以不可能意外進來。
#   2. 佔位符化 —— 複製之後把部署專屬的位址換掉。這一步必須在腳本裡，
#      不能手動改檔案：下次同步會從 DGX 覆蓋回真值，而 diff 看起來會像
#      「組態變了」而不是「我的編輯被還原了」。
#
# gateway.crt 刻意不同步：SAN 內嵌 IP 與主機名，而 SAN 在簽章涵蓋範圍內，
# sed 對它無效。還原時重簽即可（README 的 Plane B 一節有指令）。

set -euo pipefail
cd "$(dirname "$0")/.."

# 刻意沒有預設值：部署專屬的位址不該寫進公開的腳本裡。
GATEWAY_IP="${GATEWAY_IP:?請指定，例：GATEWAY_IP=10.0.0.5 bash scripts/stage.sh}"
GATEWAY_HOST="${GATEWAY_HOST:-isaac-gw.local}"

# --- 白名單複製 ---------------------------------------------------------

cp ~/.config/systemd/user/isaacsim-mcp.service              plane-a-isaacsim/
cp ~/.config/systemd/user/isaacsim-mcp.service.headless.bak plane-a-isaacsim/ 2>/dev/null || true
cp ~/isaac-mcp/gateway/app.py                               plane-b-gateway/
cp ~/.config/systemd/user/isaacsim-mcp-gateway.service      plane-b-gateway/
cp ~/isaac-mcp/isaacsim-gw.yaml                             plane-c-nemoclaw/

# 沙箱那份帶真 token，抽掉之後才落地
sudo nemoclaw isaacauto exec -- cat /sandbox/.openclaw/workspace/config/mcporter.json \
  | sed -E 's/"Bearer [0-9a-fA-F-]+"/"Bearer <REPLACE_WITH_CONTENTS_OF_gateway\/token.txt>"/' \
  > plane-c-nemoclaw/mcporter.json.example

# --- 佔位符化 -----------------------------------------------------------

sed -i "s/${GATEWAY_IP//./\\.}/<GATEWAY_IP>/g; s/${GATEWAY_HOST//./\\.}/<GATEWAY_HOST>/g" \
  plane-a-isaacsim/*.service plane-a-isaacsim/*.bak \
  plane-b-gateway/app.py plane-b-gateway/*.service \
  plane-c-nemoclaw/isaacsim-gw.yaml plane-c-nemoclaw/mcporter.json.example \
  2>/dev/null || true

# --- 驗證 ---------------------------------------------------------------

if grep -rInE "${GATEWAY_IP//./\\.}|${GATEWAY_HOST//./\\.}" plane-* scripts 2>/dev/null; then
  echo "✗ 佔位符化不完整，上面列出的位置仍含真實位址。" >&2
  exit 1
fi

if grep -rInE 'BEGIN .*PRIVATE KEY|GATEWAY_TOKEN=[0-9a-f]{16}|Bearer [0-9a-f]{16}' plane-* scripts 2>/dev/null; then
  echo "✗ 偵測到疑似機密。" >&2
  exit 1
fi

echo "✓ 同步完成，佔位符與機密檢查通過。"
git diff --stat 2>/dev/null || true
