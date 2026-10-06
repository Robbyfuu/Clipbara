# Copyd MCP: let AI tools search your clipboard history

- **Date:** 2026-10-06
- **Status:** the user approved the design in chat on 2026-10-06 ("Aprobado todo"). They authorized merging to `main` and installing.
- **Branch:** `feat/copyd-mcp`, cut from `main` at dea60d4.
- **Reference:** Paste MCP, which connects clipboard history to Claude and Cursor.

## 1. What it does

Copyd on the Mac runs a local Model Context Protocol (MCP) server. Claude Code, Cursor and other MCP clients can then search and read your clips, list your pinboards and, if you allow it, put text on the clipboard. The server is off by default and runs only while Copyd runs.

## 2. Transport and security

- **Transport:** MCP Streamable HTTP. One endpoint, `POST http://127.0.0.1:<port>/mcp`, carries JSON-RPC 2.0 messages. The server always answers with `Content-Type: application/json`, never SSE.
  - `GET /mcp` and `DELETE /mcp` return 405.
  - Any other path returns 404.
- **Protocol version:** `2025-06-18`. The server echoes the client's version when it is one it supports, and otherwise answers with `2025-06-18`. It sets the `Mcp-Session-Id` header on the `initialize` response and accepts, but doesn't require, the same header afterwards.
- **Methods:** `initialize`, `notifications/initialized`, `ping`, `tools/list`, `tools/call`.
  - Any other method returns a JSON-RPC `-32601` error.
  - Notifications return `202 Accepted` with an empty body.
- **Binding.** The server binds to `127.0.0.1` only, never to all interfaces. It uses `Network.framework` (`NWListener`) with `requiredLocalEndpoint` on the loopback address.
- **Authentication.** Every request needs `Authorization: Bearer <token>`.
  - The token is 32 random bytes, base64url-encoded, generated on first enable and stored in the Keychain as a generic password, service `com.robbyfuu.copyd.mcp`.
  - A missing or wrong token gets 401. The comparison is constant-time.
- **DNS-rebinding protection** (required by the MCP spec):
  - Reject (403) any request whose `Host` isn't `127.0.0.1:<port>` or `localhost:<port>`.
  - Reject (403) any request whose `Origin` header is present and isn't `http://127.0.0.1:<port>` or `http://localhost:<port>`.
- **Limits:**

  | Limit | Value | On breach |
  |---|---|---|
  | Request body | 1 MB | 413 |
  | Header block | 16 KB | 431 |
  | Concurrent connections | 8 | Extra connections are closed |
  | Idle connection | 30 s | Connection closed |

- **Mac sandbox:** add `com.apple.security.network.server`.
- **Default port:** 39787, configurable from 1024 to 65535. If the port is busy, the setting shows the error and the server stays off.

## 3. Tools

Secrets are never returned by any tool, not even masked, nor counted. Flagged clips (`isSensitive`) are filtered out at the fetch. A clip whose text or OCR text reads as a secret (`SecretDetector`) is dropped too, whatever "Protect secrets" says, as Spotlight drops it.

| Tool | Input | Output |
|---|---|---|
| `search_clips` | `query` (optional string), `type` (optional: `text`, `link`, `image`, `file`, `color`, `code`), `board` (optional: a user pinboard name or a smart board id such as `links` or `work`), `limit` (optional, default 20, max 50) | Newest first. Each result has `id`, `type`, `preview` (first 200 characters, or the OCR text or link title), `app` (source app name), `copied_at` (ISO 8601) and `pinned`. The query matches text, OCR text, link titles and file names, case- and diacritic-insensitive. |
| `get_clip` | `id` | The full text (capped at 100 KB, with `truncated: true` when cut), plus `type`, `app`, `copied_at`, `link_title`, `ocr_text`, `file_names`. Images return metadata and OCR text only, never pixels. A secret or unknown id returns a tool error saying "Clip not found". |
| `list_pinboards` | none | The user's pinboards (`name`, `count`) and the non-empty smart boards (`id`, `name`, `count`). |
| `copy_to_clipboard` | `text` (max 100 KB) | Writes plain text to the clipboard, which Copyd then captures like any copy. At most one copy per second and 20 per rolling 10 minutes; a call over either limit gets the tool error "Too many copies; try again in a moment." While Paste Stack is on or an auto-paste is pending it gets "Copyd is pasting right now; try again in a moment." |

`copy_to_clipboard` is only listed and allowed when "Allow writing to the clipboard" is on. That setting is off by default.

Tool results use MCP `content: [{type: "text", text: <JSON string>}]` plus `structuredContent` with the same object. Each tool declares an `inputSchema`, and an `outputSchema` where it applies.

## 4. Settings (Mac)

There is a new Settings tab, "Integrations" / "Integraciones":

| Control | English | Spanish | Default |
|---|---|---|---|
| Toggle | "Copyd MCP server" | "Servidor MCP de Copyd" | off |
| Status line | "Running on 127.0.0.1:39787" / "Off" / an error such as "Port 39787 is in use" | "Activo en 127.0.0.1:39787" / "Apagado" / "El puerto 39787 está en uso" | — |
| Number field | "Port" | "Puerto" | 39787 |
| Masked field with Copy and Regenerate buttons | "Access token" | "Token de acceso" | — |
| Toggle | "Allow writing to the clipboard" | "Permitir escribir en el portapapeles" | off |

**Copy buttons.** Each one puts a ready-to-use configuration on the clipboard, and skips Copyd's own capture so the token never lands in the history:
- "Copy Claude Code command" / "Copiar comando para Claude Code":

  ```
  claude mcp add --transport http --scope user copyd http://127.0.0.1:<port>/mcp --header "Authorization: Bearer <token>"
  ```

  `--scope user` adds Copyd to every project: clipboard history isn't tied to one (ruling M2).

- "Copy Cursor config" / "Copiar configuración para Cursor":

  ```json
  {"mcpServers": {"copyd": {"url": "http://127.0.0.1:<port>/mcp", "headers": {"Authorization": "Bearer <token>"}}}}
  ```

**Footnote:** "Only apps on this Mac can connect, and only with the token. Apps you connect can read your clipboard history and may send it to their AI service. Secrets are never shared." / "Solo las apps de este Mac pueden conectarse, y solo con el token. Las apps que conectes pueden leer tu historial y enviarlo a su servicio de IA. Los secretos nunca se comparten." (App Review 5.1.2(i).)

**Under the write switch:** "Connected apps can replace what you paste." / "Las apps conectadas pueden cambiar lo que pegas."

**Copies stay on this Mac.** The token and both configurations are written with `.currentHostOnly` and marked `org.nspasteboard.ConcealedType` and `org.nspasteboard.TransientType`, so Universal Clipboard never sends them and clipboard managers skip them.

**Regenerate** replaces the token, so existing clients must be reconfigured. It asks first: "Regenerate the token?" / "¿Generar un nuevo token?", "Apps using the current token will stop connecting." / "Las apps que usan el token actual dejarán de conectarse." It is disabled until the server has been enabled once.

**Keychain.** The token lives in the data-protection keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Only a missing item creates a token; any other Keychain error keeps the server off and shows "Couldn't read the access token." / "No se pudo leer el token de acceso."

**Debug-only override.** `-CopydMCPToken <value>` sets the token for local testing. It is compiled only in DEBUG.

## 5. Architecture

- **Pure units in `Copyd/MCP/`,** all unit-tested:
  - `HTTPRequestParser`: incremental parsing with limits.
  - `MCPRequestGuard`: host, origin and token checks.
  - `MCPRouter`: JSON-RPC in, JSON-RPC out, with an injected `ClipLibrary` protocol.
  - `MCPTools`: schemas and argument validation.
- **`MCPServer`** owns the `NWListener` and the connections. All socket I/O runs on its own serial queue, never on the main actor.
- **`StoreClipLibrary`** implements `ClipLibrary` with a background `ModelContext` and read-only fetches. It always applies `isSensitive == false` in the predicate (no captured Bools) and uses `propertiesToFetch` for search. `copy_to_clipboard` hops to the main actor to write the pasteboard.
- **Mac only.** Nothing changes on iOS.

## 6. Testing

**Unit tests:**
- the parser (limits, partial reads, chunked bodies rejected with 411/400);
- the guard (host, origin, token, constant-time comparison);
- the router (`initialize` and its version negotiation, `tools/list` with and without write, `tools/call` for each tool, errors, notifications → 202);
- the tools against an in-memory store (secrets never returned, caps, search fields, boards);
- a loopback test that starts `MCPServer` on an ephemeral port in the test process and sends real HTTP with `URLSession` (200, 401, 403, 404, 405, 413).

**Sandbox spike:**
- Build a tiny ad-hoc-signed CLI with the sandbox and `network.server` entitlements.
- Bind `NWListener` to 127.0.0.1 and `curl` it.
- If the sandbox blocks the bind, stop and report.

**Orchestrator, after install:**
- Launch the installed Debug app with `-CopydMCPToken`, the server enabled through `defaults`.
- `curl` `initialize`, `tools/list` and `search_clips` against it.
- Run `claude mcp add` against it, then quit it.

## 7. Out of scope

- iPhone.
- Remote access.
- OAuth.
- SSE streaming and resumability.
- MCP resources and prompts.
- Returning image pixels.
