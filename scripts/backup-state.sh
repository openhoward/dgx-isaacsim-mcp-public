#!/usr/bin/env bash
# NemoClaw + Isaac Sim 三層架構 — 狀態與設定備份
#
# 用法：  sudo bash backup-state.sh [輸出目錄]
# 預設輸出：/home/nvidia/isaac-mcp-backups/<時間戳>/
#
# 產出結構：
#   config/     可安全版控的設定（無機密）
#   secrets/    含 token / 私鑰，chmod 700，**不要進版控**
#   state/      執行期狀態快照（版本、埠、容器、政策）
#   RESTORE.md  自動產生的還原指引
#
# 不備份的東西（太大，且可重建）：
#   /home/nvidia/nim-cache          31 GB NIM 權重 —— 重抓約 25 分鐘
#   ~/.cache/huggingface            HF 快取
#   docker 映像                      重新 pull 即可

set -uo pipefail

SANDBOX="${SANDBOX:-isaacauto}"
NIM_CONTAINER="${NIM_CONTAINER:-nim-nemotron-nano}"
HOST_USER="${HOST_USER:-nvidia}"
HOME_DIR="/home/${HOST_USER}"
ISAAC_DIR="${HOME_DIR}/isaac-mcp"

TS="$(date +%Y%m%d-%H%M%S)"
OUT="${1:-${HOME_DIR}/isaac-mcp-backups/${TS}}"

mkdir -p "$OUT"/{config,secrets,state}
chmod 700 "$OUT/secrets"

log()  { printf '  %s\n' "$*"; }
sect() { printf '\n=== %s ===\n' "$*"; }
# 盡力而為：單項失敗不中斷整份備份
try()  { if "$@" >/dev/null 2>&1; then return 0; else log "  ! 略過（失敗）: $*"; return 1; fi; }

echo "備份輸出：$OUT"

# ─────────────────────────────────────────────────────────────
sect "版本與主機資訊"
{
  echo "timestamp: $TS"
  echo "hostname : $(hostname)"
  echo "kernel   : $(uname -r)"
  echo "arch     : $(uname -m)"
  echo
  echo "nemoclaw : $(nemoclaw --version 2>&1 | head -2 | tr '\n' ' ')"
  echo "openshell: $(openshell --version 2>&1 | head -1)"
  echo "docker   : $(docker --version 2>&1)"
  echo
  echo "--- free -g ---"; free -g
  echo
  echo "--- nvidia-smi ---"; nvidia-smi --query-gpu=name,memory.total --format=csv 2>&1 | head -3
} > "$OUT/state/versions.txt" 2>&1
log "→ state/versions.txt"

# ─────────────────────────────────────────────────────────────
sect "Plane A · Isaac Sim"
for f in isaacsim-mcp.service isaacsim-mcp.service.headless.bak; do
  src="${HOME_DIR}/.config/systemd/user/${f}"
  [ -f "$src" ] && cp -a "$src" "$OUT/config/" && log "→ config/${f}"
done
{
  systemctl --user --machine="${HOST_USER}@" is-active isaacsim-mcp 2>&1 || \
    su - "$HOST_USER" -c 'systemctl --user is-active isaacsim-mcp' 2>&1
} > "$OUT/state/planeA-active.txt" 2>&1
log "→ state/planeA-active.txt"

# ─────────────────────────────────────────────────────────────
sect "Plane B · MCP 閘道"
[ -f "${ISAAC_DIR}/gateway/app.py" ] && cp -a "${ISAAC_DIR}/gateway/app.py" "$OUT/config/" && log "→ config/app.py"
for f in isaacsim-mcp-gateway.service; do
  src="${HOME_DIR}/.config/systemd/user/${f}"
  [ -f "$src" ] && cp -a "$src" "$OUT/config/" && log "→ config/${f}"
done
# 公開憑證可安全保存；私鑰與 token 進 secrets/
[ -f "${ISAAC_DIR}/gateway/tls/gateway.crt" ] && cp -a "${ISAAC_DIR}/gateway/tls/gateway.crt" "$OUT/config/" && log "→ config/gateway.crt（公開憑證）"
for f in tls/gateway.key gateway.env token.txt; do
  src="${ISAAC_DIR}/gateway/${f}"
  [ -f "$src" ] && cp -a "$src" "$OUT/secrets/$(basename "$f")" && log "→ secrets/$(basename "$f")  ⚠ 機密"
done
# 憑證 SAN（還原時要對得上）
if [ -f "${ISAAC_DIR}/gateway/tls/gateway.crt" ]; then
  openssl x509 -in "${ISAAC_DIR}/gateway/tls/gateway.crt" -noout -subject -ext subjectAltName -enddate \
    > "$OUT/state/gateway-cert-info.txt" 2>&1
  log "→ state/gateway-cert-info.txt"
fi

# ─────────────────────────────────────────────────────────────
sect "Plane C · NemoClaw 沙箱"
try nemoclaw list --json > "$OUT/state/nemoclaw-list.json"           && log "→ state/nemoclaw-list.json"
nemoclaw inference get            > "$OUT/state/inference-get.txt" 2>&1 && log "→ state/inference-get.txt"
nemoclaw "$SANDBOX" status        > "$OUT/state/sandbox-status.txt" 2>&1 && log "→ state/sandbox-status.txt"
nemoclaw "$SANDBOX" policy list   > "$OUT/state/policy-list.txt" 2>&1 && log "→ state/policy-list.txt"
nemoclaw "$SANDBOX" policy get --raw > "$OUT/config/policy-base.yaml" 2>&1 && log "→ config/policy-base.yaml"
[ -f "${ISAAC_DIR}/isaacsim-gw.yaml" ] && cp -a "${ISAAC_DIR}/isaacsim-gw.yaml" "$OUT/config/" && log "→ config/isaacsim-gw.yaml"

# 沙箱內的 OpenClaw 設定（含 isaacsim 的 bearer token → secrets/）
nemoclaw "$SANDBOX" exec -- cat /sandbox/.openclaw/openclaw.json \
  > "$OUT/secrets/openclaw.json" 2>/dev/null && log "→ secrets/openclaw.json  ⚠ 含 bearer token"
nemoclaw "$SANDBOX" exec -- cat /sandbox/.openclaw/workspace/config/mcporter.json \
  > "$OUT/secrets/mcporter.json" 2>/dev/null && log "→ secrets/mcporter.json  ⚠ 含 bearer token"

# 去機密版本，可安全版控
python3 - "$OUT" <<'PY' 2>/dev/null && echo "  → config/openclaw.redacted.json（去機密）"
import json, sys, os
out = sys.argv[1]
src = os.path.join(out, "secrets", "openclaw.json")
if not os.path.exists(src): raise SystemExit
def red(o):
    if isinstance(o, dict):
        return {k: ("<REDACTED>" if k.lower() in ("headers","authorization","token","apikey","api_key") else red(v))
                for k, v in o.items()}
    if isinstance(o, list): return [red(x) for x in o]
    if isinstance(o, str) and len(o) > 60: return o[:8] + "...<REDACTED>"
    return o
try:
    d = json.load(open(src))
except Exception:
    raise SystemExit
json.dump(red(d), open(os.path.join(out, "config", "openclaw.redacted.json"), "w"),
          indent=2, ensure_ascii=False)
PY

# MCP 註冊與連線能力
nemoclaw "$SANDBOX" exec -- openclaw mcp list  > "$OUT/state/openclaw-mcp-list.txt" 2>&1 && log "→ state/openclaw-mcp-list.txt"
nemoclaw "$SANDBOX" exec -- openclaw mcp probe > "$OUT/state/openclaw-mcp-probe.txt" 2>&1 && log "→ state/openclaw-mcp-probe.txt"
nemoclaw "$SANDBOX" exec -- openclaw config validate > "$OUT/state/openclaw-config-validate.txt" 2>&1 && log "→ state/openclaw-config-validate.txt"
nemoclaw "$SANDBOX" exec -- sh -c 'cd /sandbox/.openclaw/workspace && mcporter list isaacsim' \
  > "$OUT/state/mcporter-list.txt" 2>&1 && log "→ state/mcporter-list.txt"

# 已安裝的 skills
nemoclaw "$SANDBOX" exec -- sh -c 'ls -R /sandbox/.openclaw/skills 2>/dev/null' \
  > "$OUT/state/skills-installed.txt" 2>&1 && log "→ state/skills-installed.txt"
[ -d "${ISAAC_DIR}/skills" ] && cp -a "${ISAAC_DIR}/skills" "$OUT/config/" && log "→ config/skills/"

# NemoClaw 原生快照（工作區狀態，之後可 snapshot restore）
if nemoclaw "$SANDBOX" snapshot create --name "backup-${TS}" > "$OUT/state/snapshot-create.txt" 2>&1; then
  log "→ NemoClaw 快照 backup-${TS} 已建立（見 state/snapshot-create.txt）"
else
  log "  ! 快照建立失敗，見 state/snapshot-create.txt"
fi

# ─────────────────────────────────────────────────────────────
sect "地端推論 · NIM 容器"
if docker inspect "$NIM_CONTAINER" > "$OUT/state/nim-inspect.json" 2>/dev/null; then
  log "→ state/nim-inspect.json"
  # 從 inspect 重建可執行的 docker run（token 以變數帶入，不寫死）
  python3 - "$OUT" "$NIM_CONTAINER" <<'PY' && log "→ config/nim-run.sh（可直接執行的重建指令）"
import json, sys, os, shlex
out, name = sys.argv[1], sys.argv[2]
d = json.load(open(os.path.join(out, "state", "nim-inspect.json")))[0]
cfg, hc = d["Config"], d["HostConfig"]
lines = ["#!/usr/bin/env bash",
         "# 由 backup-state.sh 產生 —— 重建 NIM 容器",
         "# 先讀金鑰（不進 history、不進 argv）：",
         "#   read -rsp 'NGC API Key: ' NGC_API_KEY; echo; export NGC_API_KEY NIM_NGC_API_KEY=\"$NGC_API_KEY\"",
         "set -euo pipefail",
         'if [ -z "${NGC_API_KEY:-}" ]; then echo "請先設定 NGC_API_KEY"; exit 1; fi',
         'export NIM_NGC_API_KEY="${NIM_NGC_API_KEY:-$NGC_API_KEY}"',
         "", "docker rm -f %s 2>/dev/null || true" % name, "", "docker run -d \\"]
if hc.get("DeviceRequests"): lines.append("  --gpus all \\")
if hc.get("ShmSize"): lines.append("  --shm-size %dg \\" % (hc["ShmSize"] // (1024**3)))
rp = (hc.get("RestartPolicy") or {}).get("Name")
if rp and rp != "no": lines.append("  --restart %s \\" % rp)
lines.append("  --name %s \\" % name)
for cport, binds in sorted((hc.get("PortBindings") or {}).items()):
    for b in binds or []:
        lines.append("  -p %s:%s:%s \\" % (b.get("HostIp") or "0.0.0.0", b.get("HostPort"), cport.split("/")[0]))
SECRET = ("NGC_API_KEY", "NIM_NGC_API_KEY")
for e in cfg.get("Env") or []:
    k, _, v = e.partition("=")
    if k in SECRET:
        lines.append("  -e %s \\" % k)                      # 只給變數名，值由環境帶入
    elif k.startswith("NIM_") and k not in ("NIM_MODEL_NAME", "NIM_SERVED_MODEL_NAME"):
        lines.append("  -e %s \\" % shlex.quote("%s=%s" % (k, v)))
for m in d.get("Mounts") or []:
    if m.get("Type") == "bind":
        lines.append("  -v %s:%s \\" % (m["Source"], m["Destination"]))
lines.append("  %s" % (cfg.get("Image") or ""))
lines += ["", 'echo "等待就緒（首次含下載可能 25-40 分鐘）..."',
          'until [ "$(curl -s -o /dev/null -w %{http_code} http://127.0.0.1:8000/v1/health/ready)" = "200" ]; do sleep 15; done',
          'echo "ready"']
p = os.path.join(out, "config", "nim-run.sh")
open(p, "w").write("\n".join(lines) + "\n")
os.chmod(p, 0o755)
PY
  docker logs --tail 5 "$NIM_CONTAINER" > "$OUT/state/nim-log-tail.txt" 2>&1
else
  log "  ! 找不到容器 $NIM_CONTAINER（若目前走雲端可忽略）"
fi
du -sh /home/nvidia/nim-cache 2>/dev/null > "$OUT/state/nim-cache-size.txt"

# ─────────────────────────────────────────────────────────────
sect "執行期環境"
{
  echo "--- 監聽埠 ---"; ss -ltnp 2>/dev/null | grep -E ':(22|8000|8080|8443|8766|11434|18789|18790|49100)'
  echo; echo "--- 容器 ---"; docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'
  echo; echo "--- 稽核日誌尾端 ---"; tail -10 "${ISAAC_DIR}/gateway/audit.log" 2>/dev/null
} > "$OUT/state/runtime.txt" 2>&1
log "→ state/runtime.txt"

# ─────────────────────────────────────────────────────────────
sect "產生還原指引"
ROUTE="$(grep -oE '(vllm-local|nvidia-prod)[^ ]*' "$OUT/state/inference-get.txt" 2>/dev/null | head -1)"
cat > "$OUT/RESTORE.md" <<EOF
# 還原指引 — 備份於 ${TS}

主機：$(hostname) · 沙箱：\`${SANDBOX}\` · 推論路由：\`${ROUTE:-見 state/inference-get.txt}\`

完整的從零建置流程見 \`nemoclaw_claud.md\`（雲端）與 \`nemoclaw_local.md\`（地端）。
本目錄是**當時可運作狀態的存檔**，用來對照與快速還原。

## 目錄

| 路徑 | 內容 | 可版控 |
|---|---|---|
| \`config/\` | systemd unit、gateway app.py、公開憑證、政策、skills、\`nim-run.sh\` | ✅ |
| \`config/openclaw.redacted.json\` | 沙箱 OpenClaw 設定（機密已遮蔽） | ✅ |
| \`secrets/\` | **私鑰、bearer token、含 token 的設定** | ❌ 絕對不要 |
| \`state/\` | 版本、埠、容器、政策、MCP 探測結果 | ✅ |

## 快速還原順序

1. **Plane A/B** — 依 \`nemoclaw_claud.md\` 第二、三節，用 \`config/\` 裡的 unit 與 \`app.py\`
   - 憑證：\`secrets/gateway.key\` + \`config/gateway.crt\`（SAN 見 \`state/gateway-cert-info.txt\`）
   - token：\`secrets/token.txt\`、\`secrets/gateway.env\`
2. **地端推論**（若原本是地端）
   \`\`\`bash
   read -rsp 'NGC API Key: ' NGC_API_KEY; echo; export NGC_API_KEY
   bash config/nim-run.sh
   \`\`\`
   ⚠️ NIM 權重快取（31 GB）**不在備份內**，首次會重新下載約 25 分鐘。
   要免下載就一併保留 \`/home/nvidia/nim-cache\`。
3. **Plane C** — 依對應文件的 onboard + policy add + mcporter 上傳
4. **MCP 註冊**（本次驗證有效的做法）
   \`\`\`bash
   sudo nemoclaw ${SANDBOX} exec -- sh -c 'openclaw mcp set isaacsim "\$(python3 -c "
   import json
   d=json.load(open(\\"/sandbox/.openclaw/workspace/config/mcporter.json\\"))
   s=d[\\"mcpServers\\"][\\"isaacsim\\"]
   print(json.dumps({\\"type\\":\\"http\\",\\"url\\":s[\\"baseUrl\\"],\\"headers\\":s[\\"headers\\"]}))
   ")"'
   sudo nemoclaw ${SANDBOX} exec -- openclaw mcp probe   # 應顯示 isaacsim: 38 tools
   \`\`\`

## ⚠️ 已知會破壞設定的操作

\`nemoclaw inference set\` 與 \`nemoclaw onboard\` 會同步沙箱設定，而寫入器有 bug，
會產生**非法的 \`agents.defaults\`**（扁平的 \`"sandbox.mode"\` 鍵，或字面 \`\\n\` 造成 JSON 損毀）。
\`nemoclaw doctor\` **不會**偵測到。

**每次執行這兩個指令之後都要驗證：**

\`\`\`bash
sudo nemoclaw ${SANDBOX} exec -- openclaw config validate
\`\`\`

報錯就修：

\`\`\`bash
sudo nemoclaw ${SANDBOX} exec -- sh -c 'python3 -c "
import json
p=\\"/sandbox/.openclaw/openclaw.json\\"
s=open(p).read().replace(chr(92)+chr(110), chr(10))
d=json.loads(s)
d[\\"agents\\"][\\"defaults\\"].pop(\\"sandbox.mode\\", None)
d[\\"agents\\"][\\"defaults\\"].pop(\\"sandbox\\", None)
json.dump(d, open(p,\\"w\\"), indent=2, ensure_ascii=False)
print(\\"fixed\\")
"'
\`\`\`

## ⚠️ 每次換任務前重設 session

前一個任務的約束會殘留並影響判斷（例如煙霧測試的「不要改變場景」會擋住 \`grip_cycle\`）。

\`\`\`bash
sudo nemoclaw ${SANDBOX} sessions reset agent:main:main
\`\`\`

## 驗收

\`\`\`bash
sudo nemoclaw ${SANDBOX} exec -- openclaw mcp probe            # isaacsim: 38 tools
sudo nemoclaw ${SANDBOX} agent --agent main -m "\$(cat ~/isaac-mcp/demo/prompt_smoke.txt)"
tail -5 ~/isaac-mcp/gateway/audit.log                          # 必須有 call_tool
\`\`\`
EOF
log "→ RESTORE.md"

# ─────────────────────────────────────────────────────────────
chown -R "${HOST_USER}:${HOST_USER}" "$OUT" 2>/dev/null
chmod -R go-rwx "$OUT/secrets" 2>/dev/null

sect "完成"
echo "  輸出目錄：$OUT"
du -sh "$OUT" 2>/dev/null
echo
echo "  ⚠️  $OUT/secrets/ 含私鑰與 bearer token —— 不要進版控、不要在機器之間隨意搬。"
echo "  📄  還原步驟見 $OUT/RESTORE.md"
