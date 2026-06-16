# How MCP Works

## What Is MCP?

The Model Context Protocol (MCP) is an open standard for connecting AI models like Claude to external tools, data sources, and services. Think of it as a type-safe, structured alternative to telling Claude "please run this bash command" — instead, the server declares what it can do (its tools), and the AI model calls those tools with structured JSON parameters.

## The Transport: stdin / stdout

Gentepede MCP uses `StdioServerTransport`. The MCP client (Claude Desktop) starts the server as a subprocess and communicates with it by:
- Writing JSON-RPC messages to the server's **stdin**
- Reading JSON-RPC responses from the server's **stdout**

This is deliberately simple: no HTTP server, no port binding, no TLS configuration. The OS manages the pipe between the two processes.

## JSON-RPC Message Format

Each message is a single JSON object followed by a newline character — one line per message (newline-delimited JSON, NDJSON):

```
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_available_blueprints","arguments":{}}}
```

No `Content-Length` header, no blank-line separator — just one JSON object per line. The MCP SDK handles this framing automatically. You never write newline logic in Gentepede's code.

## The Initialize Handshake

When Claude Desktop starts your MCP server for the first time in a session:

1. **Client → Server** `initialize` request: "I am Claude, using MCP protocol version 2024-11-05"
2. **Server → Client** `initialize` response: "I am Gentepede MCP v1.0.0; I have tools capability with 8 tools"
3. **Client → Server** `initialized` notification: "Acknowledged, we are ready"
4. **Client → Server** `tools/list` request: "What tools do you offer?"
5. **Server → Client** `tools/list` response: list of 8 tools with their input schemas

After this handshake, the client knows the server's capabilities and Claude can decide when to call each tool.

## Why the Official MCP Kotlin SDK?

Gentepede uses `io.modelcontextprotocol:kotlin-sdk:0.13.0` rather than hand-rolling JSON-RPC for several reasons:

1. **Correctness**: The SDK implements the exact MCP spec, including the initialize handshake, capability negotiation, and error response format. Hand-rolled implementations miss edge cases.
2. **Maintenance**: When the protocol evolves, updating the SDK version is one line in `build.gradle.kts`.
3. **Tool registration**: `server.addTool(name, description, inputSchema) { handler }` is declarative and type-safe.

## Configuring Claude Desktop

Add this to your Claude Desktop configuration file:

**macOS**: `~/Library/Application Support/Claude/claude_desktop_config.json`
**Windows**: `%APPDATA%\Claude\claude_desktop_config.json`
**Linux**: `~/.config/Claude/claude_desktop_config.json`

```json
{
  "mcpServers": {
    "gentepede": {
      "command": "java",
      "args": ["-jar", "/absolute/path/to/gentepede-mcp-all.jar"],
      "env": {
        "AWS_PROFILE": "my-aws-profile",
        "AWS_DEFAULT_REGION": "us-east-1"
      }
    }
  }
}
```

Field explanations:
- `command`: the executable to start (`java` must be in PATH, or use the full path)
- `args`: passed directly to `java` — the JAR path must be absolute
- `env.AWS_PROFILE`: AWS CLI named profile for credential lookup (optional if credentials are already in the environment)
- `env.AWS_DEFAULT_REGION`: AWS region for deployments

## Step-by-Step: What Happens When You Ask Claude

**You type:** "Generate AWS infrastructure for my Spring Boot app with a PostgreSQL database"

1. **Claude** understands you want ECS Fargate with RDS. It decides to call `generate_infrastructure_package`.
2. **MCP SDK** sends a `tools/call` JSON-RPC request to the Gentepede server's stdin.
3. **Main.kt** receives the request via the registered tool handler lambda.
4. **Engine.kt** extracts `blueprint_name`, `project_name`, and `variables` from the JSON arguments.
5. **InfrastructureService** loads the blueprint, creates workspace files, and returns a result.
6. **Engine.kt** formats the result as a human-readable string.
7. **MCP SDK** wraps it in a `CallToolResult` with `isError = false`.
8. **Claude Desktop** shows the formatted result to you in the conversation.

The entire round trip (excluding Terraform subprocess time) takes milliseconds.

## How Tool Errors Appear

If `validate_infrastructure_package` finds a checkov HIGH or CRITICAL violation, Engine.kt returns:
```kotlin
CallToolResult(content = listOf(TextContent(text = "Error: ...")), isError = true)
```

Claude Desktop surfaces this as an error in the conversation, and Claude can explain the finding and suggest a fix — without you needing to read raw JSON.
