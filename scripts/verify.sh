#!/usr/bin/env bash
# End-to-end verification for the Isaac Sim MCP three-plane stack.
# Run this ON THE DGX, not on the laptop.
#
# Deliberately does NOT use `nemoclaw isaacauto mcp status --tools`: that
# command reports "tools discovered: 0" for every --trusted-private-host
# endpoint even when the whole chain works (NemoClaw v0.0.118 passes no
# trustedPrivateHosts into normalizeMcpServerUrl, so the private IP throws and
# the discovery command builder returns null). The checks below look at what
# actually moved instead.

set -uo pipefail

GW=~/isaac-mcp/gateway
pass=0; fail=0
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
head() { printf '\n\033[1m%s\033[0m\n' "$1"; }

head "1. systemd 服務"
for unit in isaacsim-mcp isaacsim-mcp-gateway; do
  if [ "$(systemctl --user is-active "$unit")" = active ]; then
    ok "$unit active"
  else
    bad "$unit 不是 active — systemctl --user status $unit"
  fi
done
if [ "$(loginctl show-user "$USER" -p Linger --value)" = yes ]; then
  ok "linger 已啟用（登出後服務不會被殺）"
else
  bad "linger 未啟用 — sudo loginctl enable-linger $USER"
fi

head "2. 監聽埠"
check_port() {  # <pattern> <說明>
  if ss -tuln 2>/dev/null | grep -q "$1"; then ok "$2"; else bad "$2 未監聽"; fi
}
check_port ':8766 ' 'Plane A  extension  127.0.0.1:8766'
check_port ':8443 ' 'Plane B  gateway    <GATEWAY_IP>:8443'
# UDP 47998 only binds once a viewer connects, so its absence is not a failure.
if ss -tuln 2>/dev/null | grep -q ':49100 '; then
  ok 'GUI      WebRTC 信令 49100（串流版才有）'
else
  printf '  \033[33mSKIP\033[0m 49100 未監聽 — 目前應是無視窗版\n'
fi

head "3. 閘道本身（主機側，繞過沙箱）"
if [ -r "$GW/token.txt" ] && [ -x "$GW/.venv/bin/python" ]; then
  "$GW/.venv/bin/python" - <<'PY'
import asyncio, sys, os
from fastmcp import Client
from fastmcp.client.transports import StreamableHttpTransport
gw = os.path.expanduser("~/isaac-mcp/gateway")
tok = open(f"{gw}/token.txt").read().strip()
t = StreamableHttpTransport("https://<GATEWAY_IP>:8443/mcp",
                            headers={"Authorization": f"Bearer {tok}"},
                            verify=f"{gw}/tls/gateway.crt")
async def main():
    async with Client(t) as c:
        names = {x.name for x in await c.list_tools()}
        blocked = {"execute_script", "reload_script", "clear_scene",
                   "generate_3d", "search_usd"}
        leaked = names & blocked
        print(f"  {'OK  ' if len(names)==37 else 'FAIL'} 透出 {len(names)} 個工具（預期 37）")
        print(f"  {'OK  ' if not leaked else 'FAIL'} 白名單：{'無洩漏' if not leaked else sorted(leaked)}")
        r = await c.call_tool("get_simulation_state", {})
        s = str(r.data)
        print(f"  {'OK  ' if 'success' in s else 'FAIL'} 實際呼叫 get_simulation_state")
        print(f"       {'physx' if 'physx' in s else '(engine?)'} · "
              f"{'6.0.0-rc.22' if '6.0.0-rc.22' in s else '(version?)'}")
asyncio.run(main())
PY
else
  bad "找不到 $GW/token.txt 或 venv"
fi

head "4. 沙箱側（真正的判準 — 走完整政策與網路路徑）"
echo "  需要 sudo，手動執行："
echo "    sudo nemoclaw isaacauto exec -- \\"
echo "      sh -c 'cd /sandbox/.openclaw/workspace && mcporter list isaacsim'"
echo "  預期列出 37 個工具。出現 self-signed certificate 或 other side closed 即為未通。"

head "5. 稽核日誌（Agent 是否真的執行過）"
if [ -r "$GW/audit.log" ]; then
  n=$(wc -l < "$GW/audit.log")
  ok "audit.log 共 $n 筆"
  echo "  最近 3 筆："
  tail -3 "$GW/audit.log" | sed 's/^/    /'
else
  bad "找不到 $GW/audit.log"
fi

printf '\n\033[1m通過 %d · 失敗 %d\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
