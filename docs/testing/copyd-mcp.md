# Copyd MCP: end-to-end check

- **Date:** 2026-10-06
- **Build:** a signed Debug build of `feat/copyd-mcp`, installed at `/Applications/Copyd.app`.
- **Spec:** `docs/superpowers/specs/2026-10-06-copyd-mcp-design.md` §6
- **Automated:** 844 unit tests pass, including a loopback HTTP test against a real listener. `check_es` reports 0 missing.

## Results

| # | Check | Result |
|---|---|---|
| 1 | The sandboxed listener binds `127.0.0.1:39787` only (`lsof`). The app has `com.apple.security.network.server` | Pass |
| 2 | The data-protection Keychain token works in the signed app, and the server starts | Pass |
| 3 | No token → 401. Foreign `Host` → 403 | Pass |
| 4 | `initialize` returns `2025-06-18`, `serverInfo` and `Mcp-Session-Id`. `notifications/initialized` returns 202 | Pass |
| 5 | `tools/list` returns `search_clips`, `get_clip` and `list_pinboards` when writing is off | Pass |
| 6 | `search_clips` (limit 3), `get_clip` and `list_pinboards` return real data | Pass |
| 7 | `copy_to_clipboard` with writing off returns -32602, because the tool is not listed | Pass |
| 8 | `claude mcp add --transport http … --header "Authorization: Bearer …"`, then `claude mcp list`, shows ✔ Connected. The test registration was removed afterwards | Pass |
| 9 | Server turned off again, and nothing listens after a relaunch | Pass |
| 10 | Settings > Integrations: the layout fits, the en/es copy is right, the copy buttons work, and Regenerate asks first | Pending (visual) |
| 11 | With "Allow writing" on, an agent copy shows "Copyd MCP" as its source, and copies are refused while Copyd is pasting | Pending |

## Setup for Cursor

Paste the copied config into `~/.cursor/mcp.json`, then run `chmod 600 ~/.cursor/mcp.json` so other users on this Mac can't read the token.
