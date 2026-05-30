# Bluetooth Messenger

A native macOS messenger with a graphical interface. Nearby connectivity is powered by `MultipeerConnectivity`, so macOS chooses the available peer-to-peer transport, including Bluetooth.

## Requirements

You need macOS with Xcode or Command Line Tools installed.

## Run

```bash
swift run BluetoothMessenger
```

## Usage

1. Run the app on two nearby Macs.
2. Keep discovery enabled on both devices.
3. When the other Mac appears in the list, select it and click `Connect`.
4. Invitations are accepted automatically.
5. Send messages from the field at the bottom of the window.

## Limitations

- This is a macOS app, not an Android or iOS client.
- `MultipeerConnectivity` can use Bluetooth and peer-to-peer Wi-Fi; Apple does not let the app force Bluetooth only.
- If macOS asks for Local Network or Bluetooth permission, allow it.
