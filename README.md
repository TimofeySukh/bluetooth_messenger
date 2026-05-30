# Bluetooth Messenger

A native macOS nearby messenger with a graphical interface. It works without internet access by using `MultipeerConnectivity`; macOS chooses the available peer-to-peer transport, including Bluetooth and peer-to-peer Wi-Fi.

## Features

- Offline nearby text chat
- Group chat with multiple connected peers
- Basic mesh-style message forwarding across connected peers
- File sharing
- Voice messages
- Emergency SOS broadcast
- Trust code for connected peers
- Link quality indicator based on ping latency
- Encrypted local chat history
- One-click local history clearing

## Requirements

You need macOS with Xcode or Command Line Tools installed.

## Run

```bash
swift run BluetoothMessenger
```

## Build a macOS App

Create a double-clickable `.app` bundle and a zip archive:

```bash
./scripts/package_app.sh
```

The packaged app is written to:

```text
dist/Bluetooth Messenger.app
dist/BluetoothMessenger-macOS.zip
```

Because this app is not notarized, macOS may require opening it from Finder with `Control` + click, then `Open`.

If macOS says the downloaded app is damaged, remove the quarantine flag after unzipping:

```bash
xattr -dr com.apple.quarantine "/Applications/Bluetooth Messenger.app"
```

If the app is still in Downloads, use that path instead:

```bash
xattr -dr com.apple.quarantine "$HOME/Downloads/Bluetooth Messenger.app"
```

## Usage

1. Run the app on two nearby Macs.
2. Keep discovery enabled on both devices.
3. When the other Mac appears in the list, select it and click `Connect`.
4. Invitations are accepted automatically.
5. Compare the trust code shown on both devices.
6. Send messages, files, voice notes, or SOS alerts from the chat window.

## Voice Messages

Click `Voice` to start recording and `Stop Voice` to send the recording. macOS may ask for microphone permission the first time.

## File Sharing

Click `Attach`, choose a file, and it will be sent to connected peers. Received files are saved under the app's Application Support directory and can be revealed from the message row.

## Emergency Mode

Click `SOS` to broadcast an emergency message with the sender name, device name, and local timestamp.

## Local History

Messages are saved locally in encrypted form using `CryptoKit`. The local key is generated on first launch and stored in the app support directory on the same Mac. Use `Clear History` to remove the encrypted history file.

## Limitations

- This is a macOS app, not an Android or iOS client.
- `MultipeerConnectivity` can use Bluetooth and peer-to-peer Wi-Fi; Apple does not let the app force Bluetooth only.
- If macOS asks for Local Network or Bluetooth permission, allow it.
- Live calls are not implemented yet; the current audio feature is asynchronous voice messages.
