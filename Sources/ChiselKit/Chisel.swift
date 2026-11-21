import Foundation
import ChiselWrapper

/// Represents an internal file structure, often extracted from a container archive.
public struct FileNode: Identifiable, Sendable {
    public let id = UUID()
    
    /// The filename.
    public let name: String
    
    /// The detected MIME type of the file.
    public let mimeType: String
    
    /// The uncompressed size of the file in bytes.
    public let size: UInt64
    
    /// Children nodes if this file is itself a nested container.
    public let children: [FileNode]?
}

/// Why the engine left a file as it was.
public enum SkipReason: Sendable {
    /// A system or metadata file, e.g. .DS_Store or Thumbs.db.
    case junk
    /// The file is zero bytes long.
    case empty
    /// No processor handles its format.
    case unsupported
    /// Left untouched to keep its digital signature valid.
    case signed
    /// Found inside more containers than allowed.
    case nestingTooDeep
    /// Its processor can't recompress it and found nothing inside it.
    case nothingToDo
    /// Recompressing it gave nothing smaller.
    case noImprovement
    /// A stop was requested before it was done.
    case interrupted
    /// It would be replaced in place, but it or its folder can't be written.
    case readOnly
    /// Something else changed it while it was being processed.
    case changedDuringRun

    init(_ reason: ChiselSkipReason) {
        switch reason {
        case .junk: self = .junk
        case .empty: self = .empty
        case .unsupported: self = .unsupported
        case .signed: self = .signed
        case .nestingTooDeep: self = .nestingTooDeep
        case .nothingToDo: self = .nothingToDo
        case .noImprovement: self = .noImprovement
        case .interrupted: self = .interrupted
        case .readOnly: self = .readOnly
        case .changedDuringRun: self = .changedDuringRun
        @unknown default: self = .unsupported
        }
    }
}

/// Represents a lifecycle event emitted by the C++ engine during processing.
public enum ChiselEvent: Sendable {
    /// Emitted when the engine starts analyzing a container file.
    case analyzeStart(path: String)
    
    /// Emitted when analysis is complete. Contains extraction details.
    /// - parentContainer: path of the container this file was extracted from, if any.
    case analyzeComplete(path: String, extracted: Bool, numChildren: Int, parentContainer: String?)
    
    /// Emitted right before a file compression begins.
    /// - parentContainer: path of the container this file was extracted from, if any.
    /// - isContainer: true if this refers to the container's own recompression, not one of its extracted children.
    case start(path: String, parentContainer: String?, isContainer: Bool)

    /// Emitted when compression finishes, reporting size changes.
    case finish(path: String, sizeBefore: UInt64, sizeAfter: UInt64, replaced: Bool, parentContainer: String?, isContainer: Bool)

    /// Emitted if an error halts the processing of a specific file.
    case error(path: String, message: String, parentContainer: String?, isContainer: Bool)

    /// Emitted if a file is left as it was (e.g. no gain, unsupported), or a container isn't rebuilt.
    /// - message: the reason as text, for display.
    case skipped(path: String, reason: SkipReason, message: String, parentContainer: String?, isContainer: Bool)
    
    /// Emitted when an extracted container is being re-assembled.
    case finalizeStart(path: String)
    
    /// A generic log message from the C++ core (either the EventBus-driven
    /// pipeline logs, or chisel's own internal Logger diagnostics).
    case log(tag: String, message: String, level: String)
}

/// The main concurrency-safe interface for the Chisel optimization engine.
///
/// `Chisel` is an actor-based wrapper around a C++20 processing core.
/// It manages the lifecycle of the underlying executor and provides
/// a thread-safe way to process files using Swift Structured Concurrency.
public actor Chisel {
    private let wrapper = ChiselWrapper()
    
    public init() {}
    
    /// Configures the underlying C++ compression engine.
    ///
    /// - Parameters:
    ///   - iterations: The number of optimization passes for standard files. Default is 15.
    ///   - iterationsLarge: The number of optimization passes for large files. Default is 5.
    ///   - preserveMetadata: If `false`, processors drop the metadata inside the files they rewrite, such as Vorbis and Opus comments and MP3 text tags (cover art stays). Default is `true`.
    ///   - verifyChecksums: If `true`, performs a post-compression integrity check. Default is `false`.
    ///   - breakSignatures: If `true`, digitally signed files are optimized too, invalidating their signatures. Default is `false` (they are skipped).
    ///   - dryRun: If `true`, performs the analysis and compression but discards the output instead of replacing the original file. Default is `false`.
    ///   - threads: The number of concurrent threads to use. Defaults to half of the available logical cores.
    ///   - outputDirectory: An optional URL for the processed files. If `nil`, files are processed in-place.
    public func configure(iterations: UInt32 = 15,
                          iterationsLarge: UInt32 = 5,
                          preserveMetadata: Bool = true,
                          verifyChecksums: Bool = false,
                          breakSignatures: Bool = false,
                          dryRun: Bool = false,
                          threads: UInt32 = UInt32(max(1, ProcessInfo.processInfo.activeProcessorCount / 2)),
                          outputDirectory: URL? = nil) {
        wrapper.setOptionsWithIterations(iterations,
                                         iterationsLarge: iterationsLarge,
                                         preserveMetadata: preserveMetadata,
                                         verifyChecksums: verifyChecksums,
                                         breakSignatures: breakSignatures,
                                         dryRun: dryRun,
                                         threads: threads,
                                         outputDirectory: outputDirectory?.path)
    }
    /// Starts the recompression process for the provided files.
    ///
    /// This method initializes a C++ `ProcessorExecutor` inside a detached task.
    /// C++ events are captured via an `EventBus`, bridged through Objective-C++,
    /// and yielded to Swift as an `AsyncStream`.
    ///
    /// - Parameter files: An array of local file URLs to process.
    /// - Returns: An `AsyncStream<ChiselEvent>` that yields status updates, logs, and completion data.
    public func process(files: [URL]) -> AsyncStream<ChiselEvent> {
        AsyncStream { continuation in
            wrapper.onAnalyzeStart = { path in
                continuation.yield(.analyzeStart(path: path))
            }

            wrapper.onAnalyzeComplete = { path, extracted, numChildren, parentContainer in
                continuation.yield(.analyzeComplete(path: path, extracted: extracted, numChildren: numChildren, parentContainer: parentContainer))
            }

            wrapper.onFinalizeStart = { path in
                continuation.yield(.finalizeStart(path: path))
            }
            
            wrapper.onStart = { path, parentContainer, isContainer in
                continuation.yield(.start(path: path, parentContainer: parentContainer, isContainer: isContainer))
            }

            wrapper.onFinish = { path, before, after, replaced, parentContainer, isContainer in
                continuation.yield(.finish(path: path, sizeBefore: before, sizeAfter: after, replaced: replaced, parentContainer: parentContainer, isContainer: isContainer))
            }

            wrapper.onError = { path, error, parentContainer, isContainer in
                continuation.yield(.error(path: path, message: error, parentContainer: parentContainer, isContainer: isContainer))
            }

            wrapper.onSkipped = { path, reason, message, parentContainer, isContainer in
                continuation.yield(.skipped(path: path, reason: SkipReason(reason), message: message, parentContainer: parentContainer, isContainer: isContainer))
            }
            
            wrapper.onLog = { tag, msg, level in
                continuation.yield(.log(tag: tag, message: msg, level: level))
            }
            
            let paths = files.map { $0.path }
            
            Task.detached {
                self.wrapper.recompressFiles(paths)
                continuation.finish()
            }
        }
    }
    /// Requests an immediate stop of all running compression tasks.
    ///
    /// This sets an atomic stop flag in the C++ executor. Any file currently
    /// being processed may finish its current chunk before the executor fully shuts down.
    public func stop() {
        wrapper.stop()
    }
    /// Detects the MIME type of a given file by inspecting its magic bytes.
    ///
    /// - Parameter file: The URL of the file to inspect.
    /// - Returns: A string representing the detected MIME type (e.g., "application/zip").
    public func getMimeType(for file: URL) -> String {
        return wrapper.detectMimeType(file.path)
    }
    
    private func mapNode(_ node: ChiselArchiveNode) -> FileNode {
        let mappedChildren = node.children?.compactMap { mapNode($0) }
        return FileNode(name: node.name,
                        mimeType: node.mimeType,
                        size: node.size,
                        children: mappedChildren?.isEmpty == false ? mappedChildren : nil)
    }
    
    /// The current version of the underlying C++ library.
    public var version: String {
        return wrapper.version()
    }
    
    /// A list of all file extensions supported by the registered processors.
    public var supportedExtensions: [String] {
        return wrapper.supportedExtensions()
    }
    
    /// A list of all MIME types supported by the registered processors.
    public var supportedMimeTypes: [String] {
        return wrapper.supportedMimeTypes()
    }

    /// Checks if a file can be processed by any available processor.
    ///
    /// - Parameter file: The URL of the file to check.
    /// - Returns: `true` if the file is compatible, `false` otherwise.
    public func isCompatible(file: URL) -> Bool {
        return wrapper.isCompatible(file.path)
    }
}
