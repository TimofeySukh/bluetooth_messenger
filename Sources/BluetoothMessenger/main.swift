import AppKit
import AVFoundation
import CryptoKit
import Foundation
import MultipeerConnectivity
import SwiftUI

private let serviceType = "bt-msg"

enum MessageKind: String, Codable {
    case text
    case system
    case sos
    case file
    case voice
}

struct ChatMessage: Identifiable, Codable, Hashable {
    let id: UUID
    let author: String
    let text: String
    let date: Date
    let kind: MessageKind
    var fileName: String?
    var localPath: String?

    init(author: String, text: String, kind: MessageKind = .text, fileName: String? = nil, localPath: String? = nil) {
        self.id = UUID()
        self.author = author
        self.text = text
        self.date = Date()
        self.kind = kind
        self.fileName = fileName
        self.localPath = localPath
    }

    var isSystem: Bool {
        kind == .system
    }
}

struct NetworkPayload: Codable {
    let id: UUID
    let type: String
    let author: String
    let text: String
    let date: Date
    let kind: MessageKind?
    let hops: Int
    let sentAt: TimeInterval?
}

final class HistoryStore {
    private let supportURL: URL
    private let historyURL: URL
    private let keyURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.supportURL = base.appendingPathComponent("BluetoothMessenger", isDirectory: true)
        self.historyURL = supportURL.appendingPathComponent("history.bin")
        self.keyURL = supportURL.appendingPathComponent("history.key")
        try? FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
    }

    func load() -> [ChatMessage] {
        guard let encrypted = try? Data(contentsOf: historyURL) else { return [] }
        do {
            let box = try AES.GCM.SealedBox(combined: encrypted)
            let data = try AES.GCM.open(box, using: key())
            return try JSONDecoder().decode([ChatMessage].self, from: data)
        } catch {
            return [ChatMessage(author: "System", text: "Encrypted history could not be loaded", kind: .system)]
        }
    }

    func save(_ messages: [ChatMessage]) {
        do {
            let data = try JSONEncoder().encode(messages)
            let box = try AES.GCM.seal(data, using: key())
            try box.combined?.write(to: historyURL, options: .atomic)
        } catch {
            return
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: historyURL)
    }

    func attachmentsDirectory() -> URL {
        let url = supportURL.appendingPathComponent("Attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func key() throws -> SymmetricKey {
        if let data = try? Data(contentsOf: keyURL), data.count == 32 {
            return SymmetricKey(data: data)
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw NSError(domain: "BluetoothMessenger", code: Int(status), userInfo: nil)
        }
        let data = Data(bytes)
        try data.write(to: keyURL, options: .atomic)
        return SymmetricKey(data: data)
    }
}

final class VoiceRecorder: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isRecording = false
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?

    func start() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 22_050,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder?.record()
        isRecording = true
    }

    func stop() -> URL? {
        let url = recorder?.url
        recorder?.stop()
        recorder = nil
        isRecording = false
        return url
    }

    func play(url: URL) throws {
        player = try AVAudioPlayer(contentsOf: url)
        player?.delegate = self
        player?.prepareToPlay()
        player?.play()
    }
}

final class ChatModel: NSObject, ObservableObject {
    @Published var nickname: String
    @Published var isAdvertising = false
    @Published var isBrowsing = false
    @Published var availablePeers: [MCPeerID] = []
    @Published var connectedPeers: [MCPeerID] = []
    @Published var messages: [ChatMessage] = []
    @Published var status = "Ready"
    @Published var trustCode = "------"
    @Published var averageLatency: Double?

    private let peerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private let history = HistoryStore()
    private var seenPayloads = Set<UUID>()
    private var pingTimer: Timer?
    private var latencySamples: [Double] = []

    override init() {
        let defaultName = Host.current().localizedName ?? "Mac"
        self.nickname = defaultName
        self.peerID = MCPeerID(displayName: defaultName)
        self.session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        self.advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: serviceType)
        self.browser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
        messages = history.load()
        startPings()
    }

    deinit {
        stop()
    }

    func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        isAdvertising = true
        isBrowsing = true
        appendSystem("Discovery and advertising started")
        status = "Searching for devices..."
    }

    func stop() {
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
        isAdvertising = false
        isBrowsing = false
        availablePeers.removeAll()
        connectedPeers.removeAll()
        averageLatency = nil
        trustCode = "------"
        status = "Stopped"
    }

    func connect(to peer: MCPeerID) {
        browser.invitePeer(peer, to: session, withContext: nil, timeout: 20)
        appendSystem("Invitation sent to \(peer.displayName)")
        status = "Connecting to \(peer.displayName)..."
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard hasPeers() else {
            appendSystem("No connected devices")
            return
        }

        let message = ChatMessage(author: displayName(), text: trimmed)
        sendPayload(from: message)
        append(message)
    }

    func sendSOS() {
        guard hasPeers() else {
            appendSystem("No connected devices")
            return
        }
        let host = Host.current().localizedName ?? "Unknown Mac"
        let message = ChatMessage(
            author: displayName(),
            text: "SOS: \(displayName()) needs help. Device: \(host). Time: \(Date().formatted(date: .abbreviated, time: .standard)).",
            kind: .sos
        )
        sendPayload(from: message)
        append(message)
    }

    func sendFile(_ url: URL, kind: MessageKind = .file) {
        guard hasPeers() else {
            appendSystem("No connected devices")
            return
        }
        let resourceName = "\(kind.rawValue)__\(UUID().uuidString)__\(url.lastPathComponent)"
        for peer in session.connectedPeers {
            session.sendResource(at: url, withName: resourceName, toPeer: peer) { [weak self] error in
                DispatchQueue.main.async {
                    if let error {
                        self?.appendSystem("Could not send \(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
        }
        let text = kind == .voice ? "Voice message: \(url.lastPathComponent)" : "File sent: \(url.lastPathComponent)"
        append(ChatMessage(author: displayName(), text: text, kind: kind, fileName: url.lastPathComponent, localPath: url.path))
    }

    func clearHistory() {
        messages.removeAll()
        history.clear()
        appendSystem("Local encrypted history cleared")
    }

    func reveal(_ message: ChatMessage) {
        guard let path = message.localPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func receive(_ data: Data, from peer: MCPeerID) {
        do {
            let payload = try JSONDecoder().decode(NetworkPayload.self, from: data)
            handle(payload, from: peer)
        } catch {
            appendSystem("Received invalid data from \(peer.displayName)")
        }
    }

    private func handle(_ payload: NetworkPayload, from peer: MCPeerID) {
        if payload.type == "ping" {
            let pong = NetworkPayload(id: payload.id, type: "pong", author: displayName(), text: "", date: Date(), kind: nil, hops: 0, sentAt: payload.sentAt)
            sendPayload(pong, to: [peer])
            return
        }

        if payload.type == "pong", let sentAt = payload.sentAt {
            let latency = max(0, (Date().timeIntervalSince1970 - sentAt) * 1000)
            latencySamples.append(latency)
            latencySamples = Array(latencySamples.suffix(8))
            averageLatency = latencySamples.reduce(0, +) / Double(latencySamples.count)
            return
        }

        guard !seenPayloads.contains(payload.id) else { return }
        seenPayloads.insert(payload.id)

        if payload.type == "message" {
            append(ChatMessage(author: payload.author, text: payload.text, kind: payload.kind ?? .text))
            status = "Received a message from \(peer.displayName)"
            if payload.hops < 3 {
                forward(payload, excluding: peer)
            }
        }
    }

    private func sendPayload(from message: ChatMessage) {
        let payload = NetworkPayload(id: message.id, type: "message", author: message.author, text: message.text, date: message.date, kind: message.kind, hops: 0, sentAt: nil)
        seenPayloads.insert(payload.id)
        sendPayload(payload, to: session.connectedPeers)
    }

    private func sendPayload(_ payload: NetworkPayload, to peers: [MCPeerID]) {
        guard !peers.isEmpty, let data = try? JSONEncoder().encode(payload) else { return }
        try? session.send(data, toPeers: peers, with: .reliable)
    }

    private func forward(_ payload: NetworkPayload, excluding peer: MCPeerID) {
        let peers = session.connectedPeers.filter { $0 != peer }
        guard !peers.isEmpty else { return }
        let forwarded = NetworkPayload(id: payload.id, type: payload.type, author: payload.author, text: payload.text, date: payload.date, kind: payload.kind, hops: payload.hops + 1, sentAt: payload.sentAt)
        sendPayload(forwarded, to: peers)
    }

    private func append(_ message: ChatMessage) {
        messages.append(message)
        history.save(messages)
    }

    private func appendSystem(_ text: String) {
        append(ChatMessage(author: "System", text: text, kind: .system))
    }

    private func displayName() -> String {
        nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? peerID.displayName : nickname
    }

    private func hasPeers() -> Bool {
        !session.connectedPeers.isEmpty
    }

    private func updateConnectedPeers() {
        connectedPeers = session.connectedPeers.sorted { $0.displayName < $1.displayName }
        updateTrustCode()
    }

    private func updateTrustCode() {
        guard !connectedPeers.isEmpty else {
            trustCode = "------"
            return
        }
        let names = ([peerID.displayName] + connectedPeers.map(\.displayName)).sorted().joined(separator: "|")
        let digest = SHA256.hash(data: Data(names.utf8))
        trustCode = digest.prefix(3).map { String(format: "%02X", $0) }.joined()
    }

    private func startPings() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, !self.session.connectedPeers.isEmpty else { return }
            let payload = NetworkPayload(id: UUID(), type: "ping", author: self.displayName(), text: "", date: Date(), kind: nil, hops: 0, sentAt: Date().timeIntervalSince1970)
            self.sendPayload(payload, to: self.session.connectedPeers)
        }
    }

    private func saveResource(_ localURL: URL, name: String, from peer: MCPeerID) {
        let parts = name.split(separator: "__", maxSplits: 2).map(String.init)
        let kind = MessageKind(rawValue: parts.first ?? "") ?? .file
        let originalName = parts.count == 3 ? parts[2] : name
        let destination = history.attachmentsDirectory().appendingPathComponent("\(UUID().uuidString)-\(originalName)")
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: localURL, to: destination)
            let text = kind == .voice ? "Voice message from \(peer.displayName): \(originalName)" : "File from \(peer.displayName): \(originalName)"
            append(ChatMessage(author: peer.displayName, text: text, kind: kind, fileName: originalName, localPath: destination.path))
            status = "Received \(originalName)"
        } catch {
            appendSystem("Could not save \(originalName): \(error.localizedDescription)")
        }
    }
}

extension ChatModel: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            self.updateConnectedPeers()
            switch state {
            case .connected:
                self.status = "Connected: \(peerID.displayName)"
                self.appendSystem("Connected: \(peerID.displayName)")
            case .connecting:
                self.status = "Connecting: \(peerID.displayName)"
            case .notConnected:
                self.status = "Disconnected: \(peerID.displayName)"
                self.appendSystem("Disconnected: \(peerID.displayName)")
            @unknown default:
                self.status = "Unknown connection state"
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            self.receive(data, from: peerID)
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        DispatchQueue.main.async {
            if let error {
                self.appendSystem("Resource transfer failed: \(error.localizedDescription)")
                return
            }
            guard let localURL else {
                self.appendSystem("Resource transfer finished without a file")
                return
            }
            self.saveResource(localURL, name: resourceName, from: peerID)
        }
    }
}

extension ChatModel: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
        DispatchQueue.main.async {
            self.appendSystem("Accepted invitation from \(peerID.displayName)")
            self.status = "Connecting to \(peerID.displayName)..."
        }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async {
            self.isAdvertising = false
            self.appendSystem("Could not start advertising: \(error.localizedDescription)")
            self.status = "Advertising error"
        }
    }
}

extension ChatModel: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async {
            guard !self.availablePeers.contains(peerID), peerID != self.peerID else { return }
            self.availablePeers.append(peerID)
            self.availablePeers.sort { $0.displayName < $1.displayName }
            self.status = "Found: \(peerID.displayName)"
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            self.availablePeers.removeAll { $0 == peerID }
            self.status = "Device disappeared: \(peerID.displayName)"
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async {
            self.isBrowsing = false
            self.appendSystem("Could not start discovery: \(error.localizedDescription)")
            self.status = "Discovery error"
        }
    }
}

struct ContentView: View {
    @StateObject private var model = ChatModel()
    @StateObject private var recorder = VoiceRecorder()
    @State private var draft = ""
    @State private var selectedPeer: MCPeerID?
    @State private var selectedFile: URL?
    @State private var showFileImporter = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            chatView
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
            if case let .success(url) = result {
                selectedFile = url
                model.sendFile(url)
            }
        }
        .onAppear {
            model.start()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bluetooth Messenger")
                .font(.title2.bold())

            TextField("Name", text: $model.nickname)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button(model.isBrowsing || model.isAdvertising ? "Restart" : "Start Discovery") {
                    model.stop()
                    model.start()
                }
                Button("Stop") {
                    model.stop()
                }
            }

            infoPanel

            Divider()

            Text("Available Devices")
                .font(.headline)

            List(selection: $selectedPeer) {
                ForEach(model.availablePeers, id: \.self) { peer in
                    Text(peer.displayName)
                        .tag(Optional(peer))
                }
            }
            .frame(minHeight: 140)

            Button("Connect") {
                if let selectedPeer {
                    model.connect(to: selectedPeer)
                }
            }
            .disabled(selectedPeer == nil)

            Divider()

            Text("Connected")
                .font(.headline)

            if model.connectedPeers.isEmpty {
                Text("No active connections")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.connectedPeers, id: \.self) { peer in
                    Label(peer.displayName, systemImage: "dot.radiowaves.left.and.right")
                }
            }

            Spacer()
        }
        .padding()
        .frame(minWidth: 280)
    }

    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Trust code: \(model.trustCode)", systemImage: "checkmark.shield")
            Label(connectionQuality, systemImage: "waveform.path.ecg")
            Label("\(model.connectedPeers.count) connected", systemImage: "person.2")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(10)
        .background(Color.gray.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var chatView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(model.status)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("SOS") {
                    model.sendSOS()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                Button("Clear History") {
                    model.clearHistory()
                }
            }
            .padding()

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.messages) { message in
                            MessageRow(message: message, ownName: model.nickname, reveal: {
                                model.reveal(message)
                            }, playVoice: {
                                playVoice(message)
                            })
                            .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: model.messages.count) { _ in
                    if let last = model.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button("Attach") {
                    showFileImporter = true
                }
                Button(recorder.isRecording ? "Stop Voice" : "Voice") {
                    toggleVoice()
                }
                .tint(recorder.isRecording ? .red : .accentColor)
                TextField("Message", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button("Send", action: send)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 620, minHeight: 560)
    }

    private var connectionQuality: String {
        guard let averageLatency = model.averageLatency else {
            return "Link quality: waiting"
        }
        if averageLatency < 80 {
            return "Link quality: excellent (\(Int(averageLatency)) ms)"
        }
        if averageLatency < 180 {
            return "Link quality: good (\(Int(averageLatency)) ms)"
        }
        return "Link quality: weak (\(Int(averageLatency)) ms)"
    }

    private func send() {
        model.send(draft)
        draft = ""
    }

    private func toggleVoice() {
        if recorder.isRecording {
            if let url = recorder.stop() {
                model.sendFile(url, kind: .voice)
            }
            return
        }
        do {
            try recorder.start()
        } catch {
            model.send("Voice recording failed: \(error.localizedDescription)")
        }
    }

    private func playVoice(_ message: ChatMessage) {
        guard let path = message.localPath else { return }
        do {
            try recorder.play(url: URL(fileURLWithPath: path))
        } catch {
            model.send("Voice playback failed: \(error.localizedDescription)")
        }
    }
}

struct MessageRow: View {
    let message: ChatMessage
    let ownName: String
    let reveal: () -> Void
    let playVoice: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(message.isSystem ? "System" : message.author)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text(message.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(background)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                if message.kind == .file {
                    Button("Reveal", action: reveal)
                }
                if message.kind == .voice {
                    Button("Play", action: playVoice)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: isOwn ? .trailing : .leading)
    }

    private var isOwn: Bool {
        !message.isSystem && message.author == ownName
    }

    private var background: Color {
        switch message.kind {
        case .system:
            return Color.gray.opacity(0.12)
        case .sos:
            return Color.red.opacity(0.18)
        case .file:
            return Color.green.opacity(0.14)
        case .voice:
            return Color.orange.opacity(0.16)
        case .text:
            return Color.accentColor.opacity(isOwn ? 0.18 : 0.1)
        }
    }
}

@main
struct BluetoothMessengerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
    }
}
