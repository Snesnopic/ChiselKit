# ChiselKit

ChiselKit is a Swift framework for file recompression and optimization, built on top of a C++20 core. It leverages a three-tier architecture: a C++ engine for heavy data manipulation, an Objective-C++ wrapper for interoperability, and a modern Swift interface powered by Actors and Structured Concurrency.

## Requirement

- macOS 14.0+ / iOS 16.0+ / visionOS 1.0+ / tvOS 16.0+ / watchOS 9.0+
- Swift 5.9+

## Architecture

The package exposes the `Chisel` actor, which strictly isolates the state of the underlying `ChiselWrapper`. File processing happens asynchronously, streaming progress and status updates back to Swift via an `AsyncStream` of events. This design guarantees thread safety and ensures the main thread is never blocked during I/O-intensive operations.

## Quick Start

```swift
import Foundation
import ChiselKit

// Initialize the Chisel actor
let chisel = Chisel()

// Optional: Configure the C++ engine parameters
await chisel.configure(iterations: 20, threads: 4)

let filesToProcess = [URL(fileURLWithPath: "/path/to/archive.zip")]

// Consume the event stream
for await event in await chisel.process(files: filesToProcess) {
    switch event {
    case .start(let path, _, _):
        print("Processing started: \(path)")

    // A mixed container (e.g. a FLAC with a cover) first reports its own stream with isContainer == true,
    // then its rebuild with isContainer == false: only the latter is its final result
    case .finish(let path, let before, let after, _, _, let isContainer) where !isContainer:
        let ratio = (Double(after) / Double(before)) * 100
        print("Finished \(path): \(String(format: "%.2f", ratio))% of original size")

    case .error(let path, let message, _, _):
        print("Error processing \(path): \(message)")

    case .skipped(let path, let reason, let message, _, _):
        print("Skipped \(path) (\(reason)): \(message)")

    default:
        // Handle other events like .analyzeStart, .analyzeComplete, .finalizeStart, .log
        break
    }
}
```

## Events

- Files found inside containers (archives, documents, audio covers) get their own events, and `parentContainer` names the container each one came from. A container's `.analyzeComplete` arrives before any event of the files inside it.
- `.skipped` carries a `SkipReason` (`junk`, `empty`, `unsupported`, `signed`, `nestingTooDeep`, `nothingToDo`, `noImprovement`, `interrupted`, `readOnly`, `changedDuringRun`) and a human-readable `message`.
- Without an output directory files are replaced in place: an input that can't be written, or whose folder can't, is skipped as `readOnly`, and one that something else changes during the run as `changedDuringRun`.
- After `stop()`, every file that was running or waiting to be recompressed reports `.skipped` with reason `interrupted`. Files still waiting to be analyzed get no event.
- The callbacks are rebound on every `process(files:)` call, so two runs at the same time need two `Chisel` instances.
