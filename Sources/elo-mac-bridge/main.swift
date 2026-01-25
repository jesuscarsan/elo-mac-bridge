import SwiftUI
import Photos
import Contacts
import Network

// Configuration
let PORT: UInt16 = 27345

// --- Logic Model ---

class BridgeState: ObservableObject {
    @Published var logs: [String] = []
    @Published var status: String = "Initializing..."
    @Published var port: UInt16 = PORT
    @Published var appVersion: String = "Unknown"
    
    private var server: BridgeServer?
    public let contactsManager = ContactsManager()

    init() {
        if let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            self.appVersion = version
        }
        
        // Wire up logger for ContactsManager
        self.contactsManager.logger = { [weak self] msg in
            self?.appendLog(msg)
        }
        
        appendLog("App Launched. Version: \(self.appVersion)")
    }
    
    func appendLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logLine = "[\(timestamp)] \(message)"
        
        DispatchQueue.main.async {
            self.logs.append(logLine)
            // Keep log size manageable
            if self.logs.count > 1000 {
                self.logs.removeFirst()
            }
        }
        print(logLine) // Keep stdout for Obsidian console too
        
        // Write to file
        let fileURL = URL(fileURLWithPath: "/Users/joshua/my-docs/code/elo-mac-bridge/elo_bridge.log")
        if let data = (logLine + "\n").data(using: .utf8) {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                if let fileHandle = try? FileHandle(forWritingTo: fileURL) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
    
    func startServer() {
        self.server = BridgeServer(logger: self)
        
        // Request Photos Access
        PHPhotoLibrary.requestAuthorization { status in
            self.appendLog("Photos Authorization: \(status.rawValue)")
            if status != .authorized && status != .limited {
                 self.appendLog("WARNING: Access to Photos denied/restricted.")
            }
        }
        
        // Request Contacts Access
        contactsManager.requestAccess { granted in
            self.appendLog("Contacts Authorization: \(granted)")
             if !granted {
                 self.appendLog("WARNING: Access to Contacts denied.")
            }
        }
        
        // Always start server (listeners don't need auth, just handlers do)
        self.server?.start()
    }
    
    func stopServer() {
        // Implement stop if needed
    }
}

// --- Logic Model: Contacts ---

class ContactsManager {
    let store = CNContactStore()
    var logger: ((String) -> Void)?
    
    func log(_ msg: String) {
        logger?(msg) ?? print(msg)
    }
    
    func requestAccess(completion: @escaping (Bool) -> Void) {
        store.requestAccess(for: .contacts) { granted, error in
            if let error = error {
                self.log("Contact access error: \(error)")
            }
            completion(granted)
        }
    }
    
    func searchContacts(query: String) -> [[String: Any]] {
        var results: [[String: Any]] = []
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactIdentifierKey] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        
        do {
            try store.enumerateContacts(with: request) { contact, stop in
                let fullName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                let orgName = contact.organizationName
                let nickName = contact.nickname
                
                let matchesName = fullName.localizedCaseInsensitiveContains(query)
                let matchesOrg = orgName.localizedCaseInsensitiveContains(query)
                let matchesNick = nickName.localizedCaseInsensitiveContains(query)
                
                if query.isEmpty || matchesName || matchesOrg || matchesNick {
                    self.log("DEBUG: Match found: \(fullName)")
                    var dict: [String: Any] = [
                        "id": contact.identifier,
                        "name": fullName,
                        "emails": contact.emailAddresses.map { $0.value as String },
                        "phones": contact.phoneNumbers.map { $0.value.stringValue }
                    ]
                    results.append(dict)
                }
            }
        } catch {
            self.log("Fetch error: \(error)")
        }
        return results
    }
    
    func serializeContact(_ contact: CNContact) -> [String: Any] {
        var dict: [String: Any] = [
            "id": contact.identifier,
            "name": "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces),
            "emails": contact.emailAddresses.map { $0.value as String },
            "phones": contact.phoneNumbers.map { $0.value.stringValue }
        ]
        
        if let birthday = contact.birthday,
           let year = birthday.year, let month = birthday.month, let day = birthday.day {
               // Format YYYY-MM-DD
               dict["birthday"] = String(format: "%04d-%02d-%02d", year, month, day)
        }
        
        return dict
    }

    func upsertContact(data: [String: Any]) throws -> [String: Any] {
        self.log("DEBUG: upsertContact called with data: \(data)")
        // Note: CNContactNoteKey removed due to missing entitlement causing crashes
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactBirthdayKey, CNContactIdentifierKey] as [CNKeyDescriptor]
        
        var contactToUpdate: CNMutableContact?
        
        // 1. Try Find by ID
        if let id = data["id"] as? String {
             self.log("DEBUG: Searching by ID: \(id)")
             do {
                 let contact = try store.unifiedContact(withIdentifier: id, keysToFetch: keys)
                 contactToUpdate = contact.mutableCopy() as? CNMutableContact
                 self.log("DEBUG: Found by ID")
                 
                 // DEBUG CONTAINER
                 do {
                    let containerPred = CNContainer.predicateForContainerOfContact(withIdentifier: contact.identifier)
                    let containers = try store.containers(matching: containerPred)
                    for c in containers {
                        self.log("DEBUG: Container: \(c.name), Type: \(c.type.rawValue), ID: \(c.identifier)")
                    }
                 } catch {
                    self.log("DEBUG: Failed to get container info: \(error)")
                 }
             } catch {
                 self.log("DEBUG: Could not find contact by ID: \(id) - \(error)")
             }
        }
        
        // 2. If not found by ID, Try Find by Name
        if contactToUpdate == nil {
            if let name = data["name"] as? String, !name.isEmpty {
                self.log("DEBUG: Searching by Name: \(name)")
                do {
                    var allContacts: [CNContact] = []
                    let request = CNContactFetchRequest(keysToFetch: keys)
                    try store.enumerateContacts(with: request) { contact, _ in
                        let fullName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                        if fullName.caseInsensitiveCompare(name) == .orderedSame {
                            allContacts.append(contact)
                        }
                    }
                    if let existing = allContacts.first {
                        contactToUpdate = existing.mutableCopy() as? CNMutableContact
                        self.log("DEBUG: Found by Name")
                    } else {
                        self.log("DEBUG: Not found by Name")
                    }
                } catch {
                    self.log("DEBUG: Search error: \(error)")
                }
            }
        }
        
        let contact = contactToUpdate ?? CNMutableContact()
        
        // Always Update Name (Enforce Note Title as Source of Truth)
        if let name = data["name"] as? String, !name.isEmpty {
           let parts = name.components(separatedBy: " ")
           if parts.count > 1 {
               contact.givenName = parts.dropLast().joined(separator: " ")
               contact.familyName = parts.last ?? ""
           } else {
               contact.givenName = name
               contact.familyName = ""
           }
        } else if contactToUpdate == nil {
             throw NSError(domain: "Bridge", code: 400, userInfo: [NSLocalizedDescriptionKey: "Name is required for new contacts"])
        }
        
        // Phone (Merge)
        if let phone = data["phone"] as? String, !phone.isEmpty {
            let digitsOnly = phone.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            let existing = contact.phoneNumbers.first { 
                $0.value.stringValue.components(separatedBy: CharacterSet.decimalDigits.inverted).joined() == digitsOnly 
            }
            
            if existing == nil {
                let phoneNumber = CNPhoneNumber(stringValue: phone)
                var currentPhones = contact.phoneNumbers
                currentPhones.append(CNLabeledValue(label: CNLabelPhoneNumberMobile, value: phoneNumber))
                contact.phoneNumbers = currentPhones
            }
        }
        
        // Email (Merge)
        if let email = data["email"] as? String, !email.isEmpty {
            let existing = contact.emailAddresses.first { $0.value as String == email }
            if existing == nil {
                var currentEmails = contact.emailAddresses
                currentEmails.append(CNLabeledValue(label: CNLabelHome, value: email as NSString))
                contact.emailAddresses = currentEmails
            }
        }
        
        // Birthday (YYYY-MM-DD or DD-MM)
        if let birthdayStr = data["birthday"] as? String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            if let date = formatter.date(from: birthdayStr) {
                let components = Calendar.current.dateComponents([.day, .month, .year], from: date)
                contact.birthday = components
            }
        }
        
        // Note: Logic to update 'note' field removed to prevent crash.
        
        // 3. Save
        self.log("DEBUG: Executing CNSaveRequest...")
        let saveRequest = CNSaveRequest()
        if contactToUpdate != nil {
            saveRequest.update(contact)
        } else {
            saveRequest.add(contact, toContainerWithIdentifier: nil)
        }
        
        do {
            try store.execute(saveRequest)
            self.log("DEBUG: Save successful")
        } catch {
             self.log("DEBUG: Save FAILED: \(error)")
             if contactToUpdate != nil {
                 self.log("WARNING: Proceeding despite save failure (likely Read-Only contact). Returning ID to valid link.")
             } else {
                 throw error
             }
        }
        
        // Return full object including generated ID
        return serializeContact(contact)
    }
}


// --- Server Logic (Refactored) ---

class BridgeServer {
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
                    if parts.count >= 2 {
                        let method = parts[0]
                        let path = parts[1]
                        
                        self.log("\(method) \(path) [\(data.count) bytes]")
                        
                        if method == "GET" {
                            self.handleGet(path: path, connection: connection)
                        } else if method == "OPTIONS" {
                             self.log("Handling OPTIONS for CORS")
                             self.sendResponse(status: "204 No Content", body: "", connection: connection)
                        } else if method == "POST" {
                            // Simple Body Extraction
                            let split = requestString.components(separatedBy: "\r\n\r\n")
                            if split.count > 1 {
                                // Re-join rest in case body contained \r\n\r\n (unlikely for simple JSON but possible)
                                let body = split.dropFirst().joined(separator: "\r\n\r\n") 
                                self.log("Body extracted (\(body.count) chars): \(body)")
                                self.handlePost(path: path, body: body, connection: connection)
                            } else {
                                self.log("No body separator found. Raw: \(requestString)")
                                self.handlePost(path: path, body: "{}", connection: connection)
                            }
                        }
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
        
        // Photos Image
        if components.path == "/image",
           let queryItems = components.queryItems,
           let id = queryItems.first(where: { $0.name == "id" })?.value {
            fetchPhoto(localId: id, connection: connection)
            return
        }
        
        // Contacts Search
        if components.path == "/contacts" {
            let query = components.queryItems?.first(where: { $0.name == "query" })?.value ?? ""
            if let bridge = logger {
                bridge.appendLog("Searching contacts for: '\(query)'")
                let results = bridge.contactsManager.searchContacts(query: query)
                bridge.appendLog("Found \(results.count) candidates")
                if let jsonData = try? JSONSerialization.data(withJSONObject: results, options: []) {
                    sendResponse(status: "200 OK", contentType: "application/json", data: jsonData, connection: connection)
                } else {
                    sendResponse(status: "500 Internal Server Error", body: "JSON Error", connection: connection)
                }
            }
            return
        }
        
        if components.path == "/" {
             sendResponse(status: "200 OK", body: "EloMacBridge is running", connection: connection)
             return
        }
        
        sendResponse(status: "404 Not Found", body: "Not Found", connection: connection)
    }

    private func handlePost(path: String, body: String, connection: NWConnection) {
         if path == "/contact" {
             guard let data = body.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                 sendResponse(status: "400 Bad Request", body: "Invalid JSON", connection: connection)
                 return
             }
             
             if let bridge = logger {
                 let name = json["name"] as? String ?? "Unknown"
                 bridge.appendLog("Received contact update/link for: \(name)")
                 do {
                     let resultDict = try bridge.contactsManager.upsertContact(data: json)
                     bridge.appendLog("Success: \(resultDict["id"] as? String ?? "unknown")")
                     
                     if let jsonData = try? JSONSerialization.data(withJSONObject: resultDict, options: []) {
                         sendResponse(status: "200 OK", contentType: "application/json", data: jsonData, connection: connection)
                     } else {
                         sendResponse(status: "200 OK", body: "{}", connection: connection) // Should rarely happen
                     }
                 } catch {
                     bridge.appendLog("Error upserting contact: \(error.localizedDescription)")
                     sendResponse(status: "500 Internal Server Error", body: "Error: \(error.localizedDescription)", connection: connection)
                 }
             }
             return
         }
        
        sendResponse(status: "404 Not Found", body: "Endpoint Not Found", connection: connection)
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
            "Access-Control-Allow-Methods: GET, POST, OPTIONS",
            "Access-Control-Allow-Headers: Content-Type",
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
                Text("v\(state.appVersion)")
                    .font(.caption)
                    .foregroundColor(.secondary)
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
