# ChiselKit

ChiselKit is a Swift framework for file recompression and optimization, built on top of a C++20 core. It leverages a three-tier architecture: a C++ engine for heavy data manipulation, an Objective-C++ wrapper for interoperability, and a modern Swift interface powered by Actors and Structured Concurrency.

## Requirement

- macOS 14.0+ / iOS 16.0+ / visionOS 1.0+ / tvOS 16.0+ / watchOS 9.0+
- Swift 5.9+

## Architecture

The package exposes the `Chisel` actor, which strictly isolates the state of the underlying `ChiselWrapper`. File processing happens asynchronously, streaming progress and status updates back to Swift via an `AsyncStream` of events. This design guarantees thread safety and ensures the main thread is never blocked during I/O-intensive operations.

## Quick Start

```swift
import ChiselKit

// Initialize the Chisel actor
let chisel = Chisel()

// Optional: Configure the C++ engine parameters
await chisel.configure(iterations: 20, threads: 4)

let filesToProcess = [URL(fileURLWithPath: "/path/to/archive.zip")]

// Consume the event stream
for await event in await chisel.process(files: filesToProcess) {
    switch event {
    case .start(let path):
        print("Processing started: \(path)")
        
    case .finish(let path, let before, let after, let replaced):
        let ratio = (Double(after) / Double(before)) * 100
        print("Finished \(path): \(String(format: "%.2f", ratio))% of original size")
        
    case .error(let path, let message):
        print("Error processing \(path): \(message)")
        
    case .skipped(let path, let reason):
        print("Skipped \(path): \(reason)")
        
    default:
        // Handle other events like .analyzeStart, .log
        break
    }
}
```
