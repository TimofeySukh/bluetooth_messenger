import Foundation
import MultipeerConnectivity
import SwiftUI

private let serviceType = "bt-msg"

struct ChatMessage: Identifiable, Codable, Hashable {
    let id: UUID
    let author: String
    let text: String
    let date: Date
    let system: Bool

    init(author: String, text: String, system: Bool = false) {
        self.id = UUID()
        self.author = author
        self.text = text
        self.date = Date()
        self.system = system
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

    private let peerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser

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
        guard !session.connectedPeers.isEmpty else {
            appendSystem("No connected devices")
            return
        }

        let message = ChatMessage(author: nickname.isEmpty ? peerID.displayName : nickname, text: trimmed)
        do {
            let data = try JSONEncoder().encode(message)
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
            messages.append(message)
        } catch {
            appendSystem("Could not send message: \(error.localizedDescription)")
        }
    }

    private func receive(_ data: Data, from peer: MCPeerID) {
        do {
            let message = try JSONDecoder().decode(ChatMessage.self, from: data)
            messages.append(message)
            status = "Received a message from \(peer.displayName)"
        } catch {
            appendSystem("Received invalid data from \(peer.displayName)")
        }
    }

    private func appendSystem(_ text: String) {
        messages.append(ChatMessage(author: "System", text: text, system: true))
    }

    private func updateConnectedPeers() {
        connectedPeers = session.connectedPeers.sorted { $0.displayName < $1.displayName }
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
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
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
    @State private var draft = ""
    @State private var selectedPeer: MCPeerID?

    var body: some View {
        NavigationSplitView {
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

                Divider()

                Text("Available Devices")
                    .font(.headline)

                List(selection: $selectedPeer) {
                    ForEach(model.availablePeers, id: \.self) { peer in
                        Text(peer.displayName)
                            .tag(Optional(peer))
                    }
                }
                .frame(minHeight: 160)

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
            .frame(minWidth: 260)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    Text(model.status)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding()

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(model.messages) { message in
                                MessageRow(message: message, ownName: model.nickname)
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
                    TextField("Message", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(send)
                    Button("Send", action: send)
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding()
            }
            .frame(minWidth: 560, minHeight: 520)
        }
        .onAppear {
            model.start()
        }
    }

    private func send() {
        model.send(draft)
        draft = ""
    }
}

struct MessageRow: View {
    let message: ChatMessage
    let ownName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(message.system ? "System" : message.author)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(message.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(message.system ? Color.gray.opacity(0.12) : Color.accentColor.opacity(isOwn ? 0.18 : 0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: isOwn ? .trailing : .leading)
    }

    private var isOwn: Bool {
        !message.system && message.author == ownName
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
