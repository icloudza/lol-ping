// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LPRooms",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LPRooms", targets: ["LPRooms"]),
        .executable(name: "lprooms-peer", targets: ["lprooms-peer"]),
    ],
    targets: [
        // scrypt and BIP-340 Schnorr: the two primitives CryptoKit doesn't have.
        .target(name: "CLPRoomsCrypto"),
        .target(name: "LPRooms", dependencies: ["CLPRoomsCrypto"]),
        // A room member for the terminal, the counterpart of upstream's tools/room-peer.
        .executableTarget(name: "lprooms-peer", dependencies: ["LPRooms"]),
        .testTarget(name: "LPRoomsTests", dependencies: ["LPRooms", "CLPRoomsCrypto"], resources: [.copy("Fixtures")]),
    ]
)
