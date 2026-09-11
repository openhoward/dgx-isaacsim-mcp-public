# Isaac Sim MCP · Three-Plane Deployment on DGX

> **A security-conscious deployment pattern for connecting Isaac Sim to a NemoClaw sandbox through a dedicated MCP Gateway.**

[![Isaac Sim](https://img.shields.io/badge/Isaac%20Sim-6.0.0--rc.22-76B900?logo=nvidia&logoColor=white)](#)
[![NemoClaw](https://img.shields.io/badge/NemoClaw-v0.0.118--30-76B900?logo=nvidia&logoColor=white)](#)
[![OpenShell](https://img.shields.io/badge/OpenShell-0.0.106-444444)](#)
[![Docker](https://img.shields.io/badge/Docker-29.2.1-2496ED?logo=docker&logoColor=white)](#)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Configuration mirror for an "Isaac Sim ← gateway ← NemoClaw sandbox" deployment on a DGX Spark.

This repo exists for version control, review, and rebuilding the machine from scratch — it is not a runnable project, and cloning it will not start anything.

Verified on: DGX Spark (GB10, 121 GB unified memory, arm64) · Isaac Sim `6.0.0-rc.22` · NemoClaw `v0.0.118-30` · OpenShell `0.0.106` · Docker `29.2.1`

## At a Glance

| Plane | Role | Endpoint | Trust Boundary |
|---|---|---|---|
| **A · Simulation** | Isaac Sim + MCP extension | `127.0.0.1:8766` | Loopback only |
| **B · Gateway** | TLS, auth, allowlist, audit | `<GATEWAY_IP>:8443` | Sole external entry point |
| **C · Sandbox** | NemoClaw + OpenClaw | `172.19.0.2` | Deny by default |

> [!IMPORTANT]
> **Plane B is mandatory.** Plane A is intentionally isolated from the sandbox; all MCP traffic must pass through the Gateway, where authentication, tool allowlisting, and auditing are enforced.


## Contents

- [At a Glance](#at-a-glance)
- [Deployment Placeholders](#-deployment-placeholders)
- [Architecture](#-architecture)
- [File Map](#-file-map)
- [Synchronization](#-synchronization)
- [Restoring from Scratch](#-restoring-from-scratch)
- [Why `tls: skip`](#-why-tls-skip)
- [Four-Layer Acceptance](#-four-layer-acceptance)
- [Troubleshooting Quick Reference](#-troubleshooting-quick-reference)
- [Rules That Bite Repeatedly](#-rules-that-bite-repeatedly)
- [Upstream](#-upstream)
- [License](#-license)

## 🔧 Deployment Placeholders

This public mirror replaces deployment-specific addresses with placeholders. Substitute your own values before following the restore guide:

| Placeholder | Meaning | Example |
|---|---|---|
| `<GATEWAY_IP>` | Address the gateway listens on — the only destination Plane C is allowed to reach | `10.0.0.5` |
| `<GATEWAY_HOST>` | Hostname used for the certificate's CN and SAN | `isaac-gw.local` |

Replace them all at once:

```bash
grep -rl '<GATEWAY_IP>\|<GATEWAY_HOST>' . \
  | xargs sed -i "s/<GATEWAY_IP>/10.0.0.5/g; s/<GATEWAY_HOST>/isaac-gw.local/g"
```

---

## 🏗️ Architecture

```
┌─ DGX Spark host ─────────────────────────────────────────────┐
│                                                               │
│  Plane A · simulation   Plane B · gateway    Plane C · sandbox │
│  Isaac Sim 6.0     ←──  mcp-gateway      ←── OpenClaw         │
│  127.0.0.1:8766         <GATEWAY_IP>:8443    172.19.0.2       │
│  (loopback only)        TLS + bearer         deny-by-default  │
│                         tool allowlist + audit                │
└───────────────────────────────────────────────────────────────┘
```

**Request path for a single tool call**

```
sandbox (172.19.0.2)
   │  OPA policy: <GATEWAY_IP>:8443 only, tls: skip
   ▼
gateway :8443  →  TLS termination → bearer auth → tool allowlist → audit log
   │  stdio
   ▼
isaacsim-mcp-server  →  extension 127.0.0.1:8766  →  PhysX
```

Plane A's socket binds to loopback only, so Plane C cannot see it. **Plane B is the sole entry point.** The whole security argument rests on that structure: bypass any one plane and the other two stop meaning anything.

| Plane | Component | Listens on | Directory |
|---|---|---|---|
| A · simulation | Isaac Sim + `isaac.sim.mcp_extension` | `127.0.0.1:8766` | `plane-a-isaacsim/` |
| B · gateway | `isaacsim-mcp-gateway` (written for this deployment) | `<GATEWAY_IP>:8443` | `plane-b-gateway/` |
| C · agent | NemoClaw sandbox `isaacauto` + OpenClaw | `172.19.0.2` | `plane-c-nemoclaw/` |

---

## 📁 File Map

| In this repo | Where it lives on the DGX |
|---|---|
| `plane-a-isaacsim/isaacsim-mcp.service` | `~/.config/systemd/user/` (streaming build, currently active) |
| `plane-a-isaacsim/isaacsim-mcp.service.headless.bak` | same directory, headless variant kept as a backup |
| `plane-b-gateway/app.py` | `~/isaac-mcp/gateway/app.py` |
| `plane-b-gateway/isaacsim-mcp-gateway.service` | `~/.config/systemd/user/` |
| `plane-b-gateway/gateway.env.example` | **template** for `~/isaac-mcp/gateway/gateway.env` |
| `plane-c-nemoclaw/isaacsim-gw.yaml` | `~/isaac-mcp/isaacsim-gw.yaml` |
| `plane-c-nemoclaw/mcporter.json.example` | **template** for `/sandbox/.openclaw/workspace/config/mcporter.json` inside the sandbox |
| `plane-c-nemoclaw/skills/franka-motion/` | skill definition for `nemoclaw skill install` |
| `scripts/stage.sh` | allowlist sync script, run on the DGX |
| `scripts/verify.sh` | the four-layer acceptance check |
| `scripts/backup-state.sh` | full state backup (secrets go to `secrets/`, never to version control) |
| `scripts/fetch-from-dgx.sh` | pull configuration back from a laptop |

### 🔒 Deliberately Not Tracked

| Excluded | Why |
|---|---|
| `gateway/token.txt`, `gateway/gateway.env` | Bearer token. Regenerate on rebuild; do not carry it between machines |
| `gateway/tls/gateway.key` | Private key. If the certificate needs replacing, re-sign it |
| `gateway/tls/gateway.crt` | The certificate itself is harmless, but its SAN embeds the deployment's IP and hostname — and the SAN is inside the signed blob, so it cannot be rewritten. Re-sign it using the Plane B command below; you need the matching private key anyway |
| `gateway/audit.log` | Runtime audit output, not configuration |
| `~/.nemoclaw/rebuild-backups/`, `~/isaac-mcp-backups/` | Full sandbox state, including bearer tokens |
| `isaac-mcp/src/` (upstream code) | See [Upstream](#upstream) |

This list is enforced by an **allowlist**, not by `.gitignore`: `scripts/stage.sh` copies only the files it names, so anything absent from that list cannot arrive by accident. `.gitignore` is the second layer and `.git/hooks/pre-commit` the third.

---

## 🔄 Synchronization

After changing configuration on the DGX, run this on the DGX itself:

```bash
GATEWAY_IP=your.address GATEWAY_HOST=your.hostname bash scripts/stage.sh
git diff --stat
```

`stage.sh` does three things, and all three matter:

1. **Allowlist copy** — only the files named in the script
2. **De-identification** — strips the bearer token out of `mcporter.json`, and rewrites `GATEWAY_IP` / `GATEWAY_HOST` to placeholders
3. **Verification** — re-scans afterwards and exits non-zero if a real address or a likely secret survived, so it never reaches a committable state

Review the diff before committing.

> [!WARNING]
> **Do not hand-edit files under `plane-*/`.** The next `stage.sh` run overwrites them from the live DGX files, and the diff will read as "the configuration changed" rather than "my edit was reverted."
>
> Any rewrite you want to persist belongs in `stage.sh`, not in the staged file.

### pre-commit hook

Hooks do not travel with `git clone`, so install this once in every working copy:

```bash
cat > .git/hooks/pre-commit <<'EOF'
#!/usr/bin/env bash
if git diff --cached -U0 | grep -nE 'BEGIN .*PRIVATE KEY|GATEWAY_TOKEN=[0-9a-f]{16}|Bearer [0-9a-f]{16}|sk-proj-[A-Za-z0-9_-]{40}|nvapi-[A-Za-z0-9_-]{20}'; then
  echo "Possible secret detected — commit aborted."
  exit 1
fi
EOF
chmod +x .git/hooks/pre-commit
```

---

## ♻️ Restoring from Scratch

The stages depend on each other. **Do not skip or reorder them.**

```text
Plane A · Isaac Sim
        │
        ▼
Plane B · MCP Gateway
        │  TLS · Bearer Auth · Allowlist · Audit
        ▼
Plane C · NemoClaw / OpenClaw
        │
        ▼
Real Agent Turn
```

### Plane A · Simulation

```bash
mkdir -p ~/isaac-mcp
git clone https://github.com/openhoward/isaacsim-mcp-server.git ~/isaac-mcp/src
export PATH="$HOME/.local/bin:$PATH"
cd ~/isaac-mcp/src && ./scripts/setup_python_env.sh
```

Use the launcher the repo ships. Do **not** assemble the Kit command yourself, and do **not** symlink the extension into `extsUser` — Kit discovers it through `--ext-folder` pointing at the repo root.

Put `plane-a-isaacsim/isaacsim-mcp.service` back into `~/.config/systemd/user/`, then:

```bash
sudo loginctl enable-linger nvidia
systemctl --user daemon-reload && systemctl --user enable --now isaacsim-mcp
ss -ltn | grep 8766        # expect 127.0.0.1:8766
```

### Plane B · Gateway

```bash
mkdir -p ~/isaac-mcp/gateway/tls && cd ~/isaac-mcp/gateway
uv venv && uv pip install fastmcp uvicorn
```

Put `app.py` back and re-sign the certificate. **The SAN must carry both the hostname and the IP**, and the files must not be group-writable:

```bash
openssl req -x509 -newkey rsa:4096 -sha256 -days 825 -nodes \
  -keyout tls/gateway.key -out tls/gateway.crt \
  -subj "/CN=<GATEWAY_HOST>" \
  -addext "subjectAltName=DNS:<GATEWAY_HOST>,IP:<GATEWAY_IP>"
chmod 644 tls/gateway.crt && chmod 600 tls/gateway.key
```

Generate the token and `gateway.env`:

```bash
openssl rand -hex 32 > token.txt && chmod 600 token.txt
printf 'GATEWAY_TOKEN=%s\n' "$(cat token.txt)" > gateway.env && chmod 600 gateway.env
```

The unit reads it through `EnvironmentFile=`, so the token never appears in the unit file, in argv, or in `ps` output.

```bash
systemctl --user daemon-reload && systemctl --user enable --now isaacsim-mcp-gateway
ss -ltn | grep 8443        # expect <GATEWAY_IP>:8443
```

### Plane C · Sandbox / Agent

```bash
sudo nemoclaw onboard --name isaacauto
```

Pick the interactive options **by their text, not by their number** — the numbering in the provider menu shifts with whatever the tool detects in the environment.

> [!CAUTION]
> **Do not choose the `Personal` policy tier.** It is a one-way door (`policy/index.js:1487`: *"Personal open internet cannot be removed in place"*), and the only way out is rebuilding the sandbox.

> [!WARNING]
> **Always paste the API key at the interactive prompt.** Never write `sudo NVIDIA_API_KEY=... nemoclaw ...` — with `sudo`, `VAR=value` is part of argv, so it lands in `ps` output and in shell history.

```bash
# bake the gateway certificate into the sandbox image
sudo bash -c 'NEMOCLAW_CORPORATE_CA_BUNDLE=/home/nvidia/isaac-mcp/gateway/tls/gateway.crt \
  nemoclaw isaacauto rebuild -y'

# apply the network policy
sudo nemoclaw isaacauto policy add \
  --from-file /home/nvidia/isaac-mcp/isaacsim-gw.yaml \
  --trusted-private-host <GATEWAY_IP> -y

# drop the managed MCP registration (deliberate — see the next section)
sudo nemoclaw isaacauto mcp remove isaacsim --force
```

Fill in the real token following the shape of `plane-c-nemoclaw/mcporter.json.example`, upload it, and then restart so OpenClaw re-reads it — this restart is **not** optional:

```bash
sudo nemoclaw isaacauto upload ~/isaac-mcp/mcporter.json \
  /sandbox/.openclaw/workspace/config/mcporter.json
sudo nemoclaw isaacauto gateway restart
```

**Uploading `mcporter.json` is not enough on its own.** It also has to be registered as OpenClaw-managed, or the agent's tool list will contain no Isaac tools at all:

```bash
sudo nemoclaw isaacauto exec -- sh -c 'openclaw mcp set isaacsim "$(python3 -c "
import json
d=json.load(open(\"/sandbox/.openclaw/workspace/config/mcporter.json\"))
s=d[\"mcpServers\"][\"isaacsim\"]
print(json.dumps({\"type\":\"http\",\"url\":s[\"baseUrl\"],\"headers\":s[\"headers\"]}))
")"'
```

The endpoint and token are transcribed straight out of the file — they never cross the screen and never enter shell history.

---

## 🔐 Why `tls: skip`

This is a trade-off, not a default.

The original design used NemoClaw's managed L7 bridge (`mcp add`, `protocol: mcp`). It **cannot work** with a self-signed certificate: the OpenShell router terminates TLS itself, and its rustls client loads the native root store once at container start — before managed startup writes the CA anchor. The failure looks like the policy allowing the connection and the connection dying anyway:

```
NET:OPEN ALLOWED /usr/local/bin/node -> <GATEWAY_IP>:8443 [policy:mcp_bridge_isaacsim]
NET:FAIL  <GATEWAY_IP>:8443        ← roughly 10 ms later
```

The agent reports `fetch failed: other side closed` and the gateway logs nothing at all. Restarting the gateway, restarting the container, and installing the CA into the host trust store all fail, because the load happens before any of them.

Switching to `tls: skip` (L4 passthrough) hands verification back to node, which does trust the CA, and it works. **The cost:** the router can no longer see inside the connection, so it cannot rewrite `Authorization` — the real token has to live in `mcporter.json` inside the sandbox.

The tool allowlist, the audit log, and the single-destination restriction are **unaffected**; the gateway still enforces all three. That is precisely why Plane B cannot be dropped.

---

## ✅ Four-Layer Acceptance

> [!IMPORTANT]
> **All four checks are required, but only the fourth actually proves end-to-end functionality.**

```bash
# 1. routing
sudo nemoclaw inference get

# 2. policy
sudo nemoclaw isaacauto policy list | grep "●"        # expect isaacsim-gw

# 3. tool count
sudo nemoclaw isaacauto exec -- openclaw mcp probe    # isaacsim: 38 tools

# 4. a real agent turn ← the only layer that counts
sudo nemoclaw isaacauto agent --agent main --timeout 300 -m "<prompt>"
tail -5 ~/isaac-mcp/gateway/audit.log                 # must contain "event": "call_tool"
```

A response with no `call_tool` means the model wrote the tool call out as prose, or the tools were never attached in the first place.

Tag the commit whenever the check passes, to record the version combination it passed with:

```bash
git tag -a verified-$(date +%Y%m%d) -m "Isaac Sim 6.0.0-rc.22 · NemoClaw v0.0.118-30 · four-layer check passed"
git push origin verified-$(date +%Y%m%d)
```

When a later upgrade breaks something, that gives you a known-good point to diff against.

---

## 🧭 Troubleshooting Quick Reference

| Symptom | Likely Cause | What to Check |
|---|---|---|
| `tools discovered: 0` | `mcp status --tools` limitation with `--trusted-private-host` | Use `openclaw mcp probe` or the audit log |
| `doctor` says healthy, but Agent fails | Reachability ≠ usability | Run the real Agent-turn validation |
| Agent has no Isaac tools | MCP registration/config was not reloaded | Re-upload `mcporter.json` and run `gateway restart` |
| Isaac tools disappear after `onboard` / `inference set` | Sandbox config writer bug | Run `openclaw config validate` |
| Gateway has no `call_tool` entry | Tool call never reached the Gateway | Check MCP registration and run a real Agent turn |

---

## ⚠️ Rules That Bite Repeatedly

### 1. Always run `nemoclaw` with `sudo` The registry lives in `/root/.local/state/nemoclaw/`. Running `nemoclaw list` as an ordinary user reports nothing, which does not mean the sandbox is gone.

### 2. Do not judge success by `mcp status --tools` Against any `--trusted-private-host` endpoint it always reports `tools discovered: 0`, even when everything works — a defect in NemoClaw v0.0.118, where `buildMcpToolDiscoveryCommand()` does not pass `trustedPrivateHosts` to `normalizeMcpServerUrl()`. Use `openclaw mcp probe` or the audit log instead.

### 3. `doctor` reporting healthy does not mean it works What doctor checks is reachability, not usability.

### 4. Always `gateway restart` after editing `mcporter.json` or restarting Isaac Sim OpenClaw reads its configuration into memory at startup and never re-reads it. The symptom is misleading: `nemoclaw exec` running `mcporter list` succeeds — it re-reads the file every time — while the agent itself fails.

### 5. `onboard` and `inference set` can corrupt the sandbox configuration Both commands "sync the sandbox model identity," and the writer has a bug that produces an invalid `agents.defaults`. The consequence is OpenClaw degrading to built-in tools only, with all 38 Isaac tools disappearing. Verify after every run:

```bash
sudo nemoclaw isaacauto exec -- openclaw config validate
```

### 6. Reset the session between tasks Constraints from the previous task persist and distort the model's judgement.

---

## 🔗 Upstream

Plane A uses [whats2000/isaacsim-mcp-server](https://github.com/whats2000/isaacsim-mcp-server) (MIT), which is itself a fork of [omni-mcp/isaac-sim-mcp](https://github.com/omni-mcp/isaac-sim-mcp).

This deployment runs the `feat/set-drive-params` branch of [openhoward/isaacsim-mcp-server](https://github.com/openhoward/isaacsim-mcp-server), which carries four changes not yet upstream:

| Change | Status |
|---|---|
| Report drive gains in radians rather than degrees | [PR submitted](https://github.com/whats2000/isaacsim-mcp-server/pulls) |
| Read the stage scale instead of assuming centimetres | not yet submitted |
| Index joints in the order `get_robot_info` reports | not yet submitted |
| `set_drive_params` (writes `UsdPhysicsDriveAPI`) | feature request pending |

Upstream code is **not copied into this repo** — clone it from the fork instead, which avoids both attribution questions and version drift.

---

## 🚦 Operational Checklist

Before declaring the deployment healthy:

- [ ] Plane A listens only on `127.0.0.1:8766`
- [ ] Plane B listens on `<GATEWAY_IP>:8443`
- [ ] Plane C policy allows only the Gateway destination
- [ ] `openclaw mcp probe` reports the expected Isaac tools
- [ ] A real Agent turn produces a `call_tool` entry in `audit.log`
- [ ] No bearer token, private key, or deployment-specific secret is tracked by Git

---

## 📜 License

[MIT](LICENSE) · Copyright (c) 2026 Howard Chang

The contents of this repo — systemd units, the gateway implementation, the OPA policy, and the documentation — are original work. The upstream MCP server carries its own license.
