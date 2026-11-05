// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LinkBud",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "LinkBud", targets: ["LinkBud"])],
    targets: [.target(name: "LinkBud"), .testTarget(name: "LinkBudTests", dependencies: ["LinkBud"])]
)
