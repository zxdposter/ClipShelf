# MCP connections

Enable MCP in Settings → Intelligence. Click **Copy Connection Configuration**, name
the AI tool, and authorize it. Import the generated `mcpServers` configuration into
the client. Each configuration has its own credential, passed through
`CLIPSHELF_MCP_TOKEN`; ClipShelf stores only its SHA-256 digest and display name.

The client can reconnect without another approval. **Revoke Access** invalidates
that credential on the next request, including requests from an existing session.
The MCP switch temporarily blocks every client. Legacy configurations without a
credential still require approval for each session; an invalid credential never
falls back to a session approval.

Keep connection configurations private. Generated configurations are marked as
confidential and excluded from ClipShelf history even if confidential capture is
enabled. Other applications may still read the system clipboard.

The transport is local stdio (`ClipShelf --mcp`). Available tools are read-only:
`search_items`, `get_item`, and `list_pinboards`. They read the saved history archive;
binary attachments are not exported.

DeepSeek Harness supports this connection through `@deepseek-ai/dsh-mcp-client`.
Add a named `stdio` entry under an `insert` list in the desktop profile's
`cordis.patch.yml`, with the executable, `args: ['--mcp']`, and the credential in
`config.env.CLIPSHELF_MCP_TOKEN`. Tools appear under `mcp__clipshelf__…` when
`serverName` is `clipshelf`.
