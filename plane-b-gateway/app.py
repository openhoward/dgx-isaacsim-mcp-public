"""isaacsim-mcp-gateway — Plane B.

Fronts the stdio isaacsim-mcp-server with:
  1. bearer auth (TLS is terminated by uvicorn, see the systemd unit)
  2. a tool denylist, enforced on both list and call
  3. an append-only audit log of every tool invocation

The denylist is enforced in on_call_tool as well as on_list_tools because
hiding a tool from tools/list does not stop a client that already knows the
name from calling it.
"""

import json
import logging
import os
import time

from fastmcp import Client
from fastmcp.exceptions import ToolError
from fastmcp.client.transports import StdioTransport
from fastmcp.server.auth.providers.jwt import StaticTokenVerifier
from fastmcp.server.middleware import Middleware, MiddlewareContext
from fastmcp.server.providers.proxy import FastMCPProxy, ProxyClient

HOME = os.path.expanduser("~")
UPSTREAM = os.environ.get(
    "ISAAC_MCP_SERVER_BIN", f"{HOME}/isaac-mcp/src/.venv/bin/isaacsim-mcp-server"
)

# Arbitrary code execution inside Kit, and two tools that reach external APIs
# (Beaver3D / NVIDIA USD Search) — both incompatible with a one-address egress
# policy on the sandbox side.
DENY = {
    "execute_script",
    "reload_script",
    "clear_scene",
    "generate_3d",
    "search_usd",
}

audit = logging.getLogger("isaac_gateway_audit")
audit.setLevel(logging.INFO)
_h = logging.FileHandler(f"{HOME}/isaac-mcp/gateway/audit.log")
_h.setFormatter(logging.Formatter("%(message)s"))
audit.addHandler(_h)


def _log(**fields):
    audit.info(json.dumps({"ts": round(time.time(), 3), **fields}))


class Allowlist(Middleware):
    async def on_list_tools(self, context: MiddlewareContext, call_next):
        tools = await call_next(context)
        kept = [t for t in tools if t.name not in DENY]
        _log(event="list_tools", exposed=len(kept), hidden=len(tools) - len(kept))
        return kept

    async def on_call_tool(self, context: MiddlewareContext, call_next):
        name = context.message.name
        t0 = time.monotonic()
        if name in DENY:
            _log(event="call_tool", tool=name, result="BLOCKED")
            raise ToolError(f"tool '{name}' is blocked by gateway policy")
        try:
            result = await call_next(context)
        except Exception as exc:
            _log(
                event="call_tool",
                tool=name,
                result="error",
                ms=int((time.monotonic() - t0) * 1000),
                error=str(exc)[:400],
            )
            raise
        _log(
            event="call_tool",
            tool=name,
            result="ok",
            ms=int((time.monotonic() - t0) * 1000),
        )
        return result


def _client_factory() -> Client:
    # A fresh stdio child per session: isaacsim-mcp-server holds one long-lived
    # socket to Kit on 127.0.0.1:8766 and reconnects on its own if Kit restarts.
    return ProxyClient(StdioTransport(command=UPSTREAM, args=[]))


mcp = FastMCPProxy(
    client_factory=_client_factory,
    name="isaacsim-mcp-gateway",
    auth=StaticTokenVerifier(
        {os.environ["GATEWAY_TOKEN"]: {"client_id": "nemoclaw", "scopes": []}}
    ),
)
mcp.add_middleware(Allowlist())

# allowed_hosts must name every host the sandbox may dial us as, or Starlette's
# host-header protection rejects the request before auth even runs.
# json_response: OpenShell's protocol: mcp L7 inspector parses one JSON body per
# method; FastMCP's default text/event-stream response makes it close the
# connection before we ever produce output (the agent sees "SSE error: other
# side closed" and this gateway logs nothing at all).
# stateless_http is deliberately NOT set: mcporter opens the GET /mcp SSE
# stream first, and disabling it makes that GET return 405 before any MCP
# traffic flows.
app = mcp.http_app(
    path="/mcp",
    json_response=True,
    allowed_hosts=["<GATEWAY_HOST>:8443", "<GATEWAY_IP>:8443", "localhost:8443"],
)
