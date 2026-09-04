// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MSeriesVideoConverter",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MSeriesVideoConverter", targets: ["MSeriesVideoConverter"])
    ],
    targets: [
        .executableTarget(name: "MSeriesVideoConverter")
    ],
    swiftLanguageVersions: [.v5]
)
