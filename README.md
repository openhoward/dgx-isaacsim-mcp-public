# Isaac Sim MCP 三層架構 · DGX 部署組態

DGX Spark 上「Isaac Sim ← 閘道 ← NemoClaw 沙箱」三層架構的組態鏡像。

**DGX 是唯一的真相來源。** 這個 repo 用於版控、審閱，以及機器重灌時還原 —— 不是可執行的專案，直接 clone 下來不會跑起來任何東西。

驗證環境：DGX Spark（GB10, 121 GB unified memory, arm64）· Isaac Sim `6.0.0-rc.22` · NemoClaw `v0.0.118-30` · OpenShell `0.0.106` · Docker `29.2.1`

### 佔位符

這份公開鏡像把部署專屬的位址換成了佔位符。照著還原時全部替換成你自己的值：

| 佔位符 | 意義 | 例 |
|---|---|---|
| `<GATEWAY_IP>` | 閘道監聽的位址（Plane C 唯一被放行的目的地） | `10.0.0.5` |
| `<GATEWAY_HOST>` | 憑證 CN / SAN 用的主機名 | `isaac-gw.local` |

一次改完：

```bash
grep -rl '<GATEWAY_IP>\|<GATEWAY_HOST>' . \
  | xargs sed -i "s/<GATEWAY_IP>/10.0.0.5/g; s/<GATEWAY_HOST>/isaac-gw.local/g"
```

---

## 架構

```
┌─ DGX Spark host ─────────────────────────────────────────────┐
│                                                               │
│  Plane A · 模擬          Plane B · 閘道        Plane C · 沙箱   │
│  Isaac Sim 6.0     ←──   mcp-gateway     ←──   OpenClaw       │
│  127.0.0.1:8766          <GATEWAY_IP>:8443     172.19.0.2     │
│  （只綁 loopback）        TLS + bearer          deny-by-default │
│                          工具白名單 + audit                     │
└───────────────────────────────────────────────────────────────┘
```

一次工具呼叫的路徑：

```
sandbox (172.19.0.2)
   │  OPA 政策：僅允許 <GATEWAY_IP>:8443，tls: skip
   ▼
gateway :8443  →  TLS 終結 → Bearer 驗證 → 工具白名單 → 稽核日誌
   │  stdio
   ▼
isaacsim-mcp-server  →  extension 127.0.0.1:8766  →  PhysX
```

Plane A 的 socket 只綁 loopback，Plane C 看不到它。**唯一入口是 Plane B**，三層的安全性全靠這個結構，任何一層繞過都讓其餘兩層失去意義。

| 平面 | 元件 | 監聽 | 目錄 |
|---|---|---|---|
| A · 模擬層 | Isaac Sim + `isaac.sim.mcp_extension` | `127.0.0.1:8766` | `plane-a-isaacsim/` |
| B · 閘道層 | `isaacsim-mcp-gateway`（自行開發） | `<GATEWAY_IP>:8443` | `plane-b-gateway/` |
| C · 代理層 | NemoClaw sandbox `isaacauto` + OpenClaw | `172.19.0.2` | `plane-c-nemoclaw/` |

---

## 檔案對照

| 本 repo | DGX 上的位置 |
|---|---|
| `plane-a-isaacsim/isaacsim-mcp.service` | `~/.config/systemd/user/`（串流版，目前生效） |
| `plane-a-isaacsim/isaacsim-mcp.service.headless.bak` | 同上目錄的備份（無視窗版） |
| `plane-b-gateway/app.py` | `~/isaac-mcp/gateway/app.py` |
| `plane-b-gateway/isaacsim-mcp-gateway.service` | `~/.config/systemd/user/` |
| `plane-b-gateway/gateway.env.example` | `~/isaac-mcp/gateway/gateway.env` 的**範本** |
| `plane-c-nemoclaw/isaacsim-gw.yaml` | `~/isaac-mcp/isaacsim-gw.yaml` |
| `plane-c-nemoclaw/mcporter.json.example` | sandbox 內 `/sandbox/.openclaw/workspace/config/mcporter.json` 的**範本** |
| `plane-c-nemoclaw/skills/franka-motion/` | `nemoclaw skill install` 用的 skill 定義 |
| `scripts/stage.sh` | 白名單同步腳本，在 DGX 上執行 |
| `scripts/verify.sh` | 四層驗收 |
| `scripts/backup-state.sh` | 完整狀態備份（機密另存 `secrets/`，不進版控） |
| `scripts/fetch-from-dgx.sh` | 從筆電端同步組態回來 |

### 刻意不納入版控

| 未收錄 | 原因 |
|---|---|
| `gateway/token.txt`、`gateway/gateway.env` | Bearer token。重建時重新產生，不要在機器之間搬 |
| `gateway/tls/gateway.key` | 私鑰。憑證要換就重簽 |
| `gateway/tls/gateway.crt` | 公開憑證本身無害，但 SAN 內嵌部署的 IP 與主機名，而 SAN 在簽章涵蓋範圍內、無法改寫。還原時依下方 Plane B 的指令重簽即可 —— 反正你也需要對應的私鑰 |
| `gateway/audit.log` | 執行期產生的稽核紀錄，不是組態 |
| `~/.nemoclaw/rebuild-backups/`、`~/isaac-mcp-backups/` | 含完整沙箱狀態與 bearer token |
| `isaac-mcp/src/`（上游程式碼） | 見下方「上游」一節 |

這份清單靠的是**白名單**而不是 `.gitignore`：`scripts/stage.sh` 只複製列出的檔案，沒列到的不可能意外進來。`.gitignore` 是第二層保險，`.git/hooks/pre-commit` 是第三層。

---

## 同步方式

DGX 上的組態改動之後，在 DGX 本機執行：

```bash
GATEWAY_IP=你的位址 GATEWAY_HOST=你的主機名 bash scripts/stage.sh
git diff --stat
```

`stage.sh` 做三件事，缺一不可：

1. **白名單複製** —— 只取列在腳本裡的檔案
2. **去識別化** —— 抽掉 `mcporter.json` 的 bearer token，並把 `GATEWAY_IP` / `GATEWAY_HOST` 換成佔位符
3. **驗證** —— 複製完回頭掃一次，還找得到真實位址或疑似機密就 `exit 1`，不讓它進到可 commit 的狀態

diff 確認合理再 commit。

⚠️ **不要手動編輯 `plane-*/` 底下的檔案** —— 下次 `stage.sh` 會從 DGX 的真實檔案覆蓋回去，而 diff 看起來會像「組態變了」而不是「編輯被還原了」。需要固定的改寫請加進 `stage.sh`，不要加在檔案裡。

### pre-commit hook

hook 不會跟著 `git clone` 走，每個工作副本都要自己裝一次：

```bash
cat > .git/hooks/pre-commit <<'EOF'
#!/usr/bin/env bash
if git diff --cached -U0 | grep -nE 'BEGIN .*PRIVATE KEY|GATEWAY_TOKEN=[0-9a-f]{16}|Bearer [0-9a-f]{16}|sk-proj-[A-Za-z0-9_-]{40}|nvapi-[A-Za-z0-9_-]{20}'; then
  echo "✗ 偵測到疑似機密，commit 中止。"
  exit 1
fi
EOF
chmod +x .git/hooks/pre-commit
```

---

## 從零還原

各階段之間有依賴，不可跳過或調換。

### Plane A

```bash
mkdir -p ~/isaac-mcp
git clone https://github.com/openhoward/isaacsim-mcp-server.git ~/isaac-mcp/src
export PATH="$HOME/.local/bin:$PATH"
cd ~/isaac-mcp/src && ./scripts/setup_python_env.sh
```

用 repo 自帶的啟動腳本，**不要**自行組裝 Kit 指令，也**不要**把 extension symlink 到 `extsUser` —— Kit 靠 `--ext-folder` 指向 repo 根目錄來發現它。

放回 `plane-a-isaacsim/isaacsim-mcp.service` 到 `~/.config/systemd/user/`，然後：

```bash
sudo loginctl enable-linger nvidia
systemctl --user daemon-reload && systemctl --user enable --now isaacsim-mcp
ss -ltn | grep 8766        # 應為 127.0.0.1:8766
```

### Plane B

```bash
mkdir -p ~/isaac-mcp/gateway/tls && cd ~/isaac-mcp/gateway
uv venv && uv pip install fastmcp uvicorn
```

放回 `app.py`，重簽憑證（**SAN 必須同時含主機名與 IP**，且檔案不可為群組可寫）：

```bash
openssl req -x509 -newkey rsa:4096 -sha256 -days 825 -nodes \
  -keyout tls/gateway.key -out tls/gateway.crt \
  -subj "/CN=<GATEWAY_HOST>" \
  -addext "subjectAltName=DNS:<GATEWAY_HOST>,IP:<GATEWAY_IP>"
chmod 644 tls/gateway.crt && chmod 600 tls/gateway.key
```

產生 token 與 `gateway.env`：

```bash
openssl rand -hex 32 > token.txt && chmod 600 token.txt
printf 'GATEWAY_TOKEN=%s\n' "$(cat token.txt)" > gateway.env && chmod 600 gateway.env
```

service 檔以 `EnvironmentFile=` 讀取，所以 token 不會出現在 unit 檔、argv 或 `ps` 輸出裡。

```bash
systemctl --user daemon-reload && systemctl --user enable --now isaacsim-mcp-gateway
ss -ltn | grep 8443        # 應為 <GATEWAY_IP>:8443
```

### Plane C

```bash
sudo nemoclaw onboard --name isaacauto
```

互動選項**照文字找，不要照編號按** —— provider 選單的編號會隨偵測到的環境浮動。

⚠️ 不要選 `Personal` policy tier，它是單向門（`policy/index.js:1487`：*"Personal open internet cannot be removed in place"*），只能重建沙箱。
⚠️ API Key 一律在互動提示裡貼，不要寫成 `sudo NVIDIA_API_KEY=... nemoclaw ...` —— `sudo` 的 `VAR=value` 是 argv 的一部分，會出現在 `ps` 輸出和 shell history。

```bash
# 把閘道憑證烤進沙箱映像
sudo bash -c 'NEMOCLAW_CORPORATE_CA_BUNDLE=/home/nvidia/isaac-mcp/gateway/tls/gateway.crt \
  nemoclaw isaacauto rebuild -y'

# 套用網路政策
sudo nemoclaw isaacauto policy add \
  --from-file /home/nvidia/isaac-mcp/isaacsim-gw.yaml \
  --trusted-private-host <GATEWAY_IP> -y

# 移除 managed MCP 註冊（刻意為之，見下節）
sudo nemoclaw isaacauto mcp remove isaacsim --force
```

依 `plane-c-nemoclaw/mcporter.json.redacted` 的形狀填入真 token 後上傳，然後**必須**重啟讓 OpenClaw 重讀：

```bash
sudo nemoclaw isaacauto upload ~/isaac-mcp/mcporter.json \
  /sandbox/.openclaw/workspace/config/mcporter.json
sudo nemoclaw isaacauto gateway restart
```

**只上傳 `mcporter.json` 不夠**，還要註冊成 OpenClaw-managed，否則 agent 的工具清單裡一個 Isaac 工具都不會有：

```bash
sudo nemoclaw isaacauto exec -- sh -c 'openclaw mcp set isaacsim "$(python3 -c "
import json
d=json.load(open(\"/sandbox/.openclaw/workspace/config/mcporter.json\"))
s=d[\"mcpServers\"][\"isaacsim\"]
print(json.dumps({\"type\":\"http\",\"url\":s[\"baseUrl\"],\"headers\":s[\"headers\"]}))
")"'
```

端點與 token 直接從檔案讀出轉寫，不經過螢幕也不進 shell history。

---

## 為什麼是 `tls: skip`

這是取捨，不是預設值。

原始設計走 NemoClaw 受管的 L7 橋接（`mcp add`、`protocol: mcp`）。它在自簽憑證下**無法運作**：OpenShell router 自行終結 TLS，而它的 rustls 客戶端在容器啟動時一次性載入系統根憑證 —— 早於 managed startup 寫入 CA 錨點。表現為政策放行後隨即失敗：

```
NET:OPEN ALLOWED /usr/local/bin/node -> <GATEWAY_IP>:8443 [policy:mcp_bridge_isaacsim]
NET:FAIL  <GATEWAY_IP>:8443        ← 約 10 ms 後
```

Agent 端顯示 `fetch failed: other side closed`，閘道端毫無日誌。重啟 gateway、重啟容器、把 CA 裝進主機信任庫三種方法都無效，因為載入時機在其之前。

改用 `tls: skip`（L4 直通）後由 node 自行驗證憑證即可運作。**代價**：router 看不到內容就無法改寫 `Authorization`，真 token 必須落在沙箱內的 `mcporter.json`。

工具白名單、稽核日誌、單一位址限制**都不受影響**，仍由閘道執行 —— 這也是為什麼 Plane B 那層不能省。

---

## 四層驗收

缺一不可，而且只有第四層算數。

```bash
# 1. 路由
sudo nemoclaw inference get

# 2. 政策
sudo nemoclaw isaacauto policy list | grep "●"        # 應含 isaacsim-gw

# 3. 工具數
sudo nemoclaw isaacauto exec -- openclaw mcp probe    # isaacsim: 38 tools

# 4. 真實 agent 回合 ← 唯一算數的一層
sudo nemoclaw isaacauto agent --agent main --timeout 300 -m "<prompt>"
tail -5 ~/isaac-mcp/gateway/audit.log                 # 必須出現 "event": "call_tool"
```

只有回應、沒有 `call_tool`，代表模型把工具呼叫寫成文字，或工具根本沒掛上。

驗收通過時打 tag 記錄這組版本組合：

```bash
git tag -a verified-$(date +%Y%m%d) -m "Isaac Sim 6.0.0-rc.22 · NemoClaw v0.0.118-30 · 四層驗收通過"
git push origin verified-$(date +%Y%m%d)
```

升級之後爛掉時，有一個明確的「已知可用」的點可以 diff 回去比對。

---

## 會反覆咬人的規則

**1. `nemoclaw` 一律加 `sudo`。** 註冊表在 `/root/.local/state/nemoclaw/`。以一般使用者執行 `nemoclaw list` 會顯示為空，那不代表沙箱不存在。

**2. 不要用 `mcp status --tools` 判斷成敗。** 對任何 `--trusted-private-host` 端點它永遠回報 `tools discovered: 0`，即使一切正常（NemoClaw v0.0.118 的缺陷：`buildMcpToolDiscoveryCommand()` 沒把 `trustedPrivateHosts` 傳給 `normalizeMcpServerUrl()`）。用 `openclaw mcp probe` 或稽核日誌判斷。

**3. `doctor` 說 healthy ≠ 實際能用。** doctor 檢查的是「連得上」，不是「能用」。

**4. 改 `mcporter.json` 或重啟 Isaac Sim 之後一定要 `gateway restart`。** OpenClaw 在啟動時把設定讀進記憶體就不再重讀。症狀很有迷惑性：`nemoclaw exec` 跑 `mcporter list` 成功（每次重新讀檔），Agent 本身卻失敗。

**5. `onboard` 和 `inference set` 會寫壞沙箱設定，而 `doctor` 查不出來。** 兩個指令都會「同步沙箱模型識別」，寫入器有 bug，會產生非法的 `agents.defaults`。後果是 OpenClaw 降級運作、只剩內建工具，Isaac 的 38 個工具全部消失。每次跑完都要驗：

```bash
sudo nemoclaw isaacauto exec -- openclaw config validate
```

**6. 每次換任務前重設 session。** 前一個任務的約束會殘留並影響判斷。

---

## 上游

Plane A 使用 [whats2000/isaacsim-mcp-server](https://github.com/whats2000/isaacsim-mcp-server)（MIT），其本身 fork 自 [omni-mcp/isaac-sim-mcp](https://github.com/omni-mcp/isaac-sim-mcp)。

本部署跑的是 [openhoward/isaacsim-mcp-server](https://github.com/openhoward/isaacsim-mcp-server) 的 `feat/set-drive-params` 分支，含四個尚未進入上游的修改：

| 修改 | 狀態 |
|---|---|
| drive gains 以弧度回報（而非度） | [PR 已送出](https://github.com/whats2000/isaacsim-mcp-server/pulls) |
| 讀 stage scale 而非假設公分 | 待送 |
| joint 索引順序與 `get_robot_info` 一致 | 待送 |
| `set_drive_params`（寫入 `UsdPhysicsDriveAPI`） | 待開 Feature Request |

上游程式碼**不複製到這個 repo** —— 從 fork clone 即可，避免授權歸屬問題與版本漂移。

---

## 授權

[MIT](LICENSE) · Copyright (c) 2026 Howard Chang

本 repo 的內容（systemd unit、gateway 實作、OPA 政策、文件）為原創。上游 MCP server 的授權見該專案本身。
