import Foundation
import ChiselWrapper

public struct FileNode: Identifiable {
    public let id = UUID()
    public let name: String
    public let mimeType: String
    public let size: UInt64
    public let children: [FileNode]?
}

public enum ChiselEvent {
    case analyzeStart(path: String)
    case analyzeComplete(path: String, extracted: Bool, numChildren: Int)
    case start(path: String)
    case finish(path: String, sizeBefore: UInt64, sizeAfter: UInt64, replaced: Bool)
    case error(path: String, message: String)
    case skipped(path: String, reason: String)
    case finalizeStart(path: String)
    case log(tag: String, message: String)
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
    ///   - maxTokens: The maximum token limit for the compression dictionary. Default is 10000.
    ///   - preserveMetadata: If `true`, filesystem metadata (creation date, permissions) is preserved. Default is `true`.
    ///   - verifyChecksums: If `true`, performs a post-compression integrity check. Default is `false`.
    ///   - threads: The number of concurrent threads to use. Defaults to half of the available logical cores.
    ///   - outputDirectory: An optional URL for the processed files. If `nil`, files are processed in-place.
    public func configure(iterations: UInt32 = 15,
                          iterationsLarge: UInt32 = 5,
                          maxTokens: UInt32 = 10000,
                          preserveMetadata: Bool = true,
                          verifyChecksums: Bool = false,
                          threads: UInt32 = UInt32(max(1, ProcessInfo.processInfo.activeProcessorCount / 2)),
                          outputDirectory: URL? = nil) {
        wrapper.setOptionsWithIterations(iterations,
                                         iterationsLarge: iterationsLarge,
                                         maxTokens: maxTokens,
                                         preserveMetadata: preserveMetadata,
                                         verifyChecksums: verifyChecksums,
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

            wrapper.onAnalyzeComplete = { path, extracted, numChildren in
                continuation.yield(.analyzeComplete(path: path, extracted: extracted, numChildren: numChildren))
            }

            wrapper.onFinalizeStart = { path in
                continuation.yield(.finalizeStart(path: path))
            }
            
            wrapper.onStart = { path in
                continuation.yield(.start(path: path))
            }
            
            wrapper.onFinish = { path, before, after, replaced in
                continuation.yield(.finish(path: path, sizeBefore: before, sizeAfter: after, replaced: replaced))
            }
            
            wrapper.onError = { path, error in
                continuation.yield(.error(path: path, message: error))
            }
            
            wrapper.onSkipped = { path, reason in
                continuation.yield(.skipped(path: path, reason: reason))
            }
            
            wrapper.onLog = { tag, msg in
                continuation.yield(.log(tag: tag, message: msg))
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
}
