// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BluetoothMessenger",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "BluetoothMessenger", targets: ["BluetoothMessenger"])
    ],
    targets: [
        .executableTarget(
            name: "BluetoothMessenger",
            path: "Sources/BluetoothMessenger"
        )
    ]
)
