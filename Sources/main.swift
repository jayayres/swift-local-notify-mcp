import Foundation
import MCP
import ServiceLifecycle
import Logging

// Configure logging
LoggingSystem.bootstrap { label in
    var handler = StreamLogHandler.standardOutput(label: label)
    handler.logLevel = .info
    return handler
}

let logger = Logger(label: "com.example.mcp-local-notify")

func showDialog(title: String, message: String) throws {
    let script = "display dialog \"\(message)\" with title \"\(title)\""
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    
    try process.run()
    process.waitUntilExit()
    
    if process.terminationStatus != 0 {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let error = String(data: data, encoding: .utf8) {
            throw NSError(domain: "NotificationError",
                         code: Int(process.terminationStatus),
                         userInfo: ["error": error])
        }
    }
}

// Create the MCP server
let server = Server(
    name: "swift-local-notify",
    version: "1.0.0",
    capabilities: .init(
        tools: .init(listChanged: false)
    )
)

// Add tool handlers
await server.withMethodHandler(ListTools.self) { _ in
    return .init(tools: [
        Tool(
            name: "local-notify",
            description: "Shows a dialog with this text",
            inputSchema: .object([
                "properties":
                    ["text": [
                        "description": "Text to include in the dialog",
                        "type": "string"],
                     "title": [
                        "description": "Title of the dialog (optional)",
                        "type": "string"]
                    ],
                "$schema": "http://json-schema.org/draft-07/schema#",
                "additionalProperties": false,
                "required": ["text"],
                "type": "object"
            ])
        )
    ])
}

await server.withMethodHandler(CallTool.self) { params in
    guard params.name == "local-notify" else {
        throw MCPError.invalidParams("Unknown tool: \(params.name)")
    }
    
    guard let textString = params.arguments?["text"]?.stringValue else {
        throw MCPError.invalidParams("Not enough data")
    }
    let titleString = params.arguments?["title"]?.stringValue ?? ""
    
    do {
        try showDialog(title: titleString, message: textString)
        return .init(content: [.text("Complete")], isError: false)
    } catch {
        return .init(content: [.text("Failed to show notification: \(error)")], isError: true)
    }
}

// Create transport and service
let transport = StdioTransport(logger: logger)
let mcpService = MCPService(server: server, transport: transport)

// Create and run service group
let serviceGroup = ServiceGroup(
    services: [mcpService],
    configuration: .init(
        gracefulShutdownSignals: [.sigterm, .sigint]
    ),
    logger: logger
)

actor MCPService: Service {
    let server: Server
    let transport: Transport
    
    init(server: Server, transport: Transport) {
        self.server = server
        self.transport = transport
    }
    
    func run() async throws {
        try await server.start(transport: transport)
        try await Task.sleep(for: Duration.seconds(365 * 24 * 60 * 60))
    }
    
    func shutdown() async throws {
        await server.stop()
    }
}

// Run the service group
try await serviceGroup.run()
