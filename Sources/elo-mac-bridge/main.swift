import SwiftUI
import Photos
import Network

// Configuration
let PORT: UInt16 = 27345

// --- Logic Model ---

class BridgeState: ObservableObject {
    @Published var logs: [String] = []
    @Published var status: String = "Initializing..."
    @Published var port: UInt16 = PORT
    
    private var server: PhotoServer?

    init() {
        appendLog("App Launched.")
    }
    
    func appendLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        DispatchQueue.main.async {
            self.logs.append("[\(timestamp)] \(message)")
            // Keep log size manageable
            if self.logs.count > 1000 {
                self.logs.removeFirst()
            }
        }
        print("[\(timestamp)] \(message)") // Keep stdout for Obsidian console too
    }
    
    func startServer() {
        self.server = PhotoServer(logger: self)
        
        PHPhotoLibrary.requestAuthorization { status in
            self.appendLog("Authorization status: \(status.rawValue)")
            if status == .authorized || status == .limited {
                 self.server?.start()
            } else {
                self.appendLog("ERROR: Access to Photos denied/restricted. Please enable in System Settings.")
                DispatchQueue.main.async { self.status = "Permission Denied" }
            }
        }
    }
    
    func stopServer() {
        // Implement stop if needed
    }
}

// --- Server Logic (Refactored) ---

class PhotoServer {
    var listener: NWListener?
    var activeConnections: [NWConnection] = []
    private let queue = DispatchQueue(label: "server-queue")
    weak var logger: BridgeState?
    
    init(logger: BridgeState) {
        self.logger = logger
    }
    
    func log(_ message: String) {
        logger?.appendLog(message)
    }
    
    func start() {
        log("Attempting to start server on port \(PORT)")
        do {
            let parameters = NWParameters.tcp
            self.listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: PORT)!)
        } catch {
            log("Error creating listener: \(error)")
            DispatchQueue.main.async { self.logger?.status = "Listener Error" }
            return
        }
        
        self.listener?.stateUpdateHandler = { newState in
            switch newState {
            case .ready:
                self.log("Server listening on port \(PORT)")
                DispatchQueue.main.async { self.logger?.status = "Running on :\(PORT)" }
            case .failed(let error):
                self.log("Listener failed: \(error)")
                DispatchQueue.main.async { self.logger?.status = "Failed: \(error.localizedDescription)" }
            default:
                break
            }
        }
        
        self.listener?.newConnectionHandler = { [weak self] newConnection in
            self?.log("New connection received")
            self?.handleConnection(newConnection)
        }
        
        self.listener?.start(queue: .global())
    }
    
    private func handleConnection(_ connection: NWConnection) {
        self.queue.async {
            self.activeConnections.append(connection)
        }

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.queue.async {
                    self?.activeConnections.removeAll { $0 === connection }
                }
            default:
                break
            }
        }

        connection.start(queue: .global())
        // log("Connection started")

        // Read Request
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let error = error {
                self.log("Receive error: \(error)")
                connection.cancel()
                return
            }
            
            if let data = data, let requestString = String(data: data, encoding: .utf8) {
                // log("Received request: \(requestString.prefix(50))...")
                let lines = requestString.components(separatedBy: "\r\n")
                if let requestLine = lines.first {
                    let parts = requestLine.components(separatedBy: " ")
                    if parts.count >= 2 && parts[0] == "GET" {
                         self.log("GET \(parts[1])")
                        self.handleGet(path: parts[1], connection: connection)
                        return
                    }
                }
            }
            connection.cancel()
        }
    }
    
    private func handleGet(path: String, connection: NWConnection) {
        guard let url = URL(string: "http://localhost\(path)"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            sendResponse(status: "400 Bad Request", body: "Invalid URL", connection: connection)
            return
        }
        
        if components.path == "/image",
           let queryItems = components.queryItems,
           let id = queryItems.first(where: { $0.name == "id" })?.value {
            fetchPhoto(localId: id, connection: connection)
            return
        }
        
        if components.path == "/" {
             sendResponse(status: "200 OK", body: "PhotosBridge is running", connection: connection)
             return
        }
        
        sendResponse(status: "404 Not Found", body: "Not Found", connection: connection)
    }
    
    private func fetchPhoto(localId: String, connection: NWConnection) {
        let authStatus = PHPhotoLibrary.authorizationStatus()
        
        if authStatus != .authorized && authStatus != .limited {
            sendResponse(status: "403 Forbidden", body: "Access to Photos not granted", connection: connection)
            return
        }
        
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: nil)
        guard let asset = assets.firstObject else {
            log("Asset not found: \(localId)")
            sendResponse(status: "404 Not Found", body: "Image not found", connection: connection)
            return
        }
        
        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, dataUTI, orientation, info in
            guard let imageData = data else {
                self.log("Failed to load image data")
                self.sendResponse(status: "500 Internal Server Error", body: "Could not load image data", connection: connection)
                return
            }
            
            // Determine Content-Type
            var contentType = "image/jpeg"
            if let uti = dataUTI as String? {
                if uti.contains("png") { contentType = "image/png" }
                else if uti.contains("heic") { contentType = "image/heic" }
                else if uti.contains("gif") { contentType = "image/gif" }
            }
            
            self.sendResponse(status: "200 OK", contentType: contentType, data: imageData, connection: connection)
        }
    }
    
    private func sendResponse(status: String, contentType: String = "text/plain", body: String? = nil, data: Data? = nil, connection: NWConnection) {
        let bodyData = data ?? body?.data(using: .utf8) ?? Data()
        let headers = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(bodyData.count)",
            "Access-Control-Allow-Origin: *",
            "Connection: close",
            "\r\n"
        ].joined(separator: "\r\n")
        
        if let headerData = headers.data(using: .utf8) {
            connection.send(content: headerData, completion: .contentProcessed { _ in
                connection.send(content: bodyData, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            })
        }
    }
}

// --- SwiftUI App Definition ---

@main
struct PhotosBridgeApp: App {
    @StateObject private var state = BridgeState()
    
    init() {
        // Enforce Single Instance
        let bundleId = Bundle.main.bundleIdentifier ?? "com.jesuscarsan.PhotosBridge"
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        
        // runningApplications includes the current instance, so count > 1 means there's another one.
        // Also check if processIdentifier matches to avoid killing self unnecessarily if count is 1.
        let otherApps = runningApps.filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        
        if !otherApps.isEmpty {
            print("Another instance is already running. Terminating this one.")
            // Activate the existing instance
            otherApps.first?.activate(options: .activateIgnoringOtherApps)
            exit(0)
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView(state: state)
                .onAppear {
                    state.startServer()
                }
        }
        .windowStyle(.hiddenTitleBar) // Modern look
    }
}

struct ContentView: View {
    @ObservedObject var state: BridgeState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                Text(state.status)
                    .font(.headline)
                Spacer()
                Text("Port: \(state.port)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Logs
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(state.logs, id: \.self) { log in
                            Text(log)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                }
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: state.logs.count) { _ in
                    if let last = state.logs.last {
                        proxy.scrollTo(last)
                    }
                }
            }
        }
        .frame(minWidth: 400, minHeight: 300)
    }
    
    var statusColor: Color {
        if state.status.contains("Running") { return .green }
        if state.status.contains("Failed") || state.status.contains("Error") { return .red }
        if state.status.contains("Denied") { return .orange }
        return .yellow
    }
}
