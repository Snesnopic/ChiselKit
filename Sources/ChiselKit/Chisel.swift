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
    case start(path: String)
    case finish(path: String, sizeBefore: UInt64, sizeAfter: UInt64, replaced: Bool)
    case error(path: String, message: String)
    case skipped(path: String, reason: String)
    case log(tag: String, message: String)
}

public actor Chisel {
    private let wrapper = ChiselWrapper()
    
    public init() {}
    
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
    
    public func process(files: [URL]) -> AsyncStream<ChiselEvent> {
        AsyncStream { continuation in
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
    
    public func stop() {
        wrapper.stop()
    }
    
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
