#!/usr/bin/env bash
# Re-sync this mirror from the DGX. Run on the laptop, from the repo root.
#
# Pulls configuration only. Secrets (token.txt, gateway.env, tls/gateway.key)
# are deliberately never fetched -- the .example files carry the shape, and a
# rebuild regenerates them. Copying a bearer token between machines multiplies
# the places it can leak from without making anything easier.

set -euo pipefail
cd "$(dirname "$0")/.."

HOST=${1:-dgx}
echo "從 $HOST 同步組態…"

scp -q "$HOST":/home/nvidia/isaac-mcp/gateway/app.py                          plane-b-gateway/
scp -q "$HOST":/home/nvidia/isaac-mcp/gateway/tls/gateway.crt                 plane-b-gateway/
scp -q "$HOST":/home/nvidia/.config/systemd/user/isaacsim-mcp-gateway.service plane-b-gateway/
scp -q "$HOST":/home/nvidia/isaac-mcp/isaacsim-gw.yaml                        plane-c-nemoclaw/
scp -q "$HOST":/home/nvidia/.config/systemd/user/isaacsim-mcp.service         plane-a-isaacsim/
scp -q "$HOST":/home/nvidia/.config/systemd/user/isaacsim-mcp.service.headless.bak \
                                                                              plane-a-isaacsim/ 2>/dev/null || true

# The sandbox copy carries the real bearer token, so redact before it lands here.
ssh "$HOST" 'sudo nemoclaw isaacauto exec -- cat /sandbox/.openclaw/workspace/config/mcporter.json' 2>/dev/null \
  | sed -E 's/"Bearer [0-9a-f]+"/"Bearer <REDACTED>"/' \
  > plane-c-nemoclaw/mcporter.json.redacted 2>/dev/null || \
  echo "  (略過 mcporter.json — 需要 sudo，非必要)"

echo
echo "完成。變更："
git diff --stat 2>/dev/null || find plane-* -type f -newermt '-2 minutes' | sed 's/^/  /'
