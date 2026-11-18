// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TranslationRuntime",
    platforms: [.iOS(.v18)],
    products: [.library(name: "LlamaRuntime", targets: ["LlamaRuntime"])],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b12499/llama-b12499-xcframework.zip",
            checksum: "f186154b2897439d2594d0a22727d65323f187bc21bd1e58b75f07bf5e741f8d"
        ),
        .target(name: "LlamaRuntime", dependencies: ["llama"])
    ]
)
