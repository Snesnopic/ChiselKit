#import <Foundation/Foundation.h>
#import "ChiselWrapper.h"
#include "chisel.hpp"
#include "mime_detector.hpp"
#include "logger.hpp"
#include "log_sink.hpp"
#include <string>
#include <vector>
#include <filesystem>
#include <atomic>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <optional>

namespace {

// forwards chisel's internal Logger messages (processor-level warnings/errors,
// e.g. "Missing colormap for palette tiff") to the onLog block. Distinct from
// the EventBus-based events above: this is chisel's own diagnostic logging,
// which otherwise has no registered sink and is silently dropped.
class BlockLogSink final : public chisel::ILogSink {
public:
    explicit BlockLogSink(void (^onLog)(NSString *, NSString *, NSString *)) : onLog_(onLog) {}

    void log(chisel::LogLevel level, std::string_view message, std::string_view tag) override {
        if (!onLog_) return;

        NSString *nsTag = [[NSString alloc] initWithBytes:tag.data() length:tag.size() encoding:NSUTF8StringEncoding];
        NSString *nsMessage = [[NSString alloc] initWithBytes:message.data() length:message.size() encoding:NSUTF8StringEncoding];
        NSString *nsLevel = [NSString stringWithUTF8String:chisel::Logger::level_to_string(level)];
        onLog_(nsTag, nsMessage, nsLevel);
    }

private:
    void (^onLog_)(NSString *, NSString *, NSString *);
};

// Logger is a process-wide static facade, not scoped to a single recompressFiles:
// call, so the sink must be explicitly unregistered when this call ends (success
// or exception) - otherwise it stays registered forever and every future call
// would deliver messages to this same (by-then-stale) block too.
class ScopedLogSink final {
public:
    explicit ScopedLogSink(void (^onLog)(NSString *, NSString *, NSString *)) {
        auto sink = std::make_unique<BlockLogSink>(onLog);
        ptr_ = sink.get();
        chisel::Logger::add_sink(std::move(sink));
    }

    ~ScopedLogSink() {
        chisel::Logger::remove_sink(ptr_);
    }

    ScopedLogSink(const ScopedLogSink &) = delete;
    ScopedLogSink &operator=(const ScopedLogSink &) = delete;

private:
    chisel::ILogSink *ptr_ = nullptr;
};

} // namespace

@implementation ChiselArchiveNode
@end

@implementation ChiselWrapper {
    chisel::ProcessingOptions _options;
    uint32_t _threads;
    std::filesystem::path _outputDir;
    std::atomic<chisel::ProcessorExecutor*> _executor;
    std::unique_ptr<chisel::Chisel> _chiselCore;
    bool _dryRun;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        
        _threads = 4;
        _executor.store(nullptr);
        _chiselCore = std::make_unique<chisel::Chisel>();
        _dryRun = false;
    }
    return self;
}

- (void)setOptionsWithIterations:(uint32_t)iterations
                 iterationsLarge:(uint32_t)iterationsLarge
                       maxTokens:(uint32_t)maxTokens
                preserveMetadata:(BOOL)preserveMetadata
                 verifyChecksums:(BOOL)verifyChecksums
                          dryRun:(BOOL)dryRun
                         threads:(uint32_t)threads
                 outputDirectory:(NSString *)outputDirectory {
    
    _options.iterations = iterations;
    _options.iterations_large = iterationsLarge;
    _options.maxTokens = maxTokens;
    _options.preserve_metadata = preserveMetadata;
    _options.verify_checksums = verifyChecksums;
    _threads = threads;
    _dryRun = dryRun ? true : false;
    
    if (outputDirectory) {
        _outputDir = std::filesystem::path([outputDirectory UTF8String]);
    } else {
        _outputDir = std::filesystem::path();
    }
}

- (void)recompressFiles:(NSArray<NSString *> *)filePaths {
    chisel::ProcessorRegistry registry;
    chisel::EventBus bus;

    __weak ChiselWrapper *weakSelf = self;

    // registered for the duration of this call only; see ScopedLogSink's dtor.
    ScopedLogSink logSink(self.onLog);

    // chisel only attaches parent_container to Start/Complete events (Phase 2).
    // Error/Skipped events lack it, so we remember it here (keyed by path) as soon
    // as it becomes available via Start, and reuse it for the later Error/Skipped
    // of the same path. Scoped to this call; multiple pool threads write different
    // keys concurrently, hence the mutex.
    std::unordered_map<std::string, std::string> parentCache;
    std::mutex parentCacheMutex;

    bus.subscribe<chisel::FileAnalyzeStartEvent>([weakSelf](const chisel::FileAnalyzeStartEvent& e) {
        NSString* nsPath = [NSString stringWithUTF8String:e.path.c_str()];
        
        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onAnalyzeStart) {
            strongSelf.onAnalyzeStart(nsPath);
        }
    });
    
    bus.subscribe<chisel::FileAnalyzeCompleteEvent>([weakSelf](const chisel::FileAnalyzeCompleteEvent& e) {
        NSString* nsPath = [NSString stringWithUTF8String:e.path.c_str()];
        BOOL extracted = e.extracted ? YES : NO;
        NSInteger numChildren = static_cast<NSInteger>(e.num_children);
        
        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onAnalyzeComplete) {
            strongSelf.onAnalyzeComplete(nsPath, extracted, numChildren);
        }
    });

    bus.subscribe<chisel::ContainerFinalizeStartEvent>([weakSelf](const chisel::ContainerFinalizeStartEvent& e) {
        NSString* nsPath = [NSString stringWithUTF8String:e.path.c_str()];
        
        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onFinalizeStart) {
            strongSelf.onFinalizeStart(nsPath);
        }
    });

    bus.subscribe<chisel::FileProcessStartEvent>([weakSelf, &parentCache, &parentCacheMutex](const chisel::FileProcessStartEvent& e) {
        NSString* nsPath = [NSString stringWithUTF8String:e.path.c_str()];
        NSString* nsParent = nil;

        if (e.parent_container) {
            std::string parentStr = e.parent_container->string();
            nsParent = [NSString stringWithUTF8String:parentStr.c_str()];

            std::lock_guard<std::mutex> lock(parentCacheMutex);
            parentCache[e.path.string()] = parentStr;
        }

        BOOL isContainer = e.is_container ? YES : NO;

        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onStart) {
            strongSelf.onStart(nsPath, nsParent, isContainer);
        }
    });
    
    bus.subscribe<chisel::FileProcessCompleteEvent>([weakSelf](const chisel::FileProcessCompleteEvent& e) {
        NSString* nsPath = [NSString stringWithUTF8String:e.path.c_str()];
        uint64_t origSize = static_cast<uint64_t>(e.original_size);
        uint64_t finalSize = static_cast<uint64_t>(e.new_size);
        BOOL replaced = e.replaced ? YES : NO;

        NSString* nsParent = nil;
        if (e.parent_container) {
            nsParent = [NSString stringWithUTF8String:e.parent_container->string().c_str()];
        }
        BOOL isContainer = e.is_container ? YES : NO;

        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onFinish) {
            strongSelf.onFinish(nsPath, origSize, finalSize, replaced, nsParent, isContainer);
        }
    });
    
    bus.subscribe<chisel::FileProcessSkippedEvent>([weakSelf, &parentCache, &parentCacheMutex](const chisel::FileProcessSkippedEvent& e) {
        NSString* nsPath = [NSString stringWithUTF8String:e.path.c_str()];
        NSString* nsReason = [NSString stringWithUTF8String:e.reason.c_str()];
        NSString* nsParent = nil;
        {
            std::lock_guard<std::mutex> lock(parentCacheMutex);
            auto it = parentCache.find(e.path.string());
            if (it != parentCache.end()) {
                nsParent = [NSString stringWithUTF8String:it->second.c_str()];
            }
        }
        BOOL isContainer = e.is_container ? YES : NO;

        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onSkipped) {
            strongSelf.onSkipped(nsPath, nsReason, nsParent, isContainer);
        }
    });
    
    bus.subscribe<chisel::FileProcessErrorEvent>([weakSelf, &parentCache, &parentCacheMutex](const chisel::FileProcessErrorEvent& e) {
        NSString* nsPath = [NSString stringWithUTF8String:e.path.c_str()];
        NSString* nsError = [NSString stringWithUTF8String:e.error_message.c_str()];
        NSString* nsParent = nil;
        {
            std::lock_guard<std::mutex> lock(parentCacheMutex);
            auto it = parentCache.find(e.path.string());
            if (it != parentCache.end()) {
                nsParent = [NSString stringWithUTF8String:it->second.c_str()];
            }
        }
        BOOL isContainer = e.is_container ? YES : NO;

        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onError) {
            strongSelf.onError(nsPath, nsError, nsParent, isContainer);
        }
    });
    
    bus.subscribe<chisel::FileAnalyzeSkippedEvent>([weakSelf](const chisel::FileAnalyzeSkippedEvent& e) {
        NSString* nsPath = [NSString stringWithUTF8String:e.path.c_str()];
        NSString* nsReason = [NSString stringWithUTF8String:e.reason.c_str()];

        // analysis-phase (Phase 1) skips: chisel doesn't attach parent_container/is_container here yet
        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onSkipped) {
            strongSelf.onSkipped(nsPath, nsReason, nil, NO);
        }
    });

    
    bus.subscribe<chisel::ContainerFinalizeErrorEvent>([weakSelf](const chisel::ContainerFinalizeErrorEvent& e) {
        NSString* nsPath = [NSString stringWithUTF8String:e.path.c_str()];
        NSString* nsError = [NSString stringWithUTF8String:e.error_message.c_str()];

        // container finalization (Phase 3) is always the container's own file; it has no parent_container/is_container fields
        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onError) {
            strongSelf.onError(nsPath, nsError, nil, NO);
        }
    });

    bus.subscribe<chisel::ContainerFinalizeCompleteEvent>([weakSelf](const chisel::ContainerFinalizeCompleteEvent& e) {
        NSString* nsPath = [NSString stringWithUTF8String:e.path.c_str()];
        uint64_t origSize = static_cast<uint64_t>(e.original_size);
        uint64_t finalSize = static_cast<uint64_t>(e.final_size);
        BOOL replaced = e.replaced ? YES : NO;

        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onFinish) {
            strongSelf.onFinish(nsPath, origSize, finalSize, replaced, nil, NO);
        }
    });
    
    std::vector<std::filesystem::path> inputs;
    inputs.reserve(filePaths.count);
    for (NSString* path in filePaths) {
        inputs.push_back(std::filesystem::path([path UTF8String]));
    }
    
    chisel::ProcessorExecutor executor(registry,
                                       _options,
                                       chisel::EncodeMode::PIPE,
                                       _dryRun,
                                       _outputDir,
                                       bus,
                                       _threads);
    
    _executor.store(&executor);
    try {
        executor.process(inputs);
    } catch (const std::exception& e) {
        NSString* nsError = [NSString stringWithUTF8String:e.what()];
        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onLog) {
            strongSelf.onLog(@"Executor", [NSString stringWithFormat:@"Uncaught engine exception: %@", nsError], @"ERROR");
        }
    } catch (...) {
        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onLog) {
            strongSelf.onLog(@"Executor", @"Uncaught unknown engine exception", @"ERROR");
        }
    }
    _executor.store(nullptr);
}

- (void)stop {
    auto* exec = _executor.load();
    if (exec) {
        exec->request_stop();
    }
}

- (NSString *)detectMimeType:(NSString *)filePath {
    std::string mime = chisel::MimeDetector::detect([filePath UTF8String]);
    return [NSString stringWithUTF8String:mime.c_str()];
}

- (NSString *)version {
    auto v = chisel::Chisel::version();
    return [[NSString alloc] initWithBytes:v.data() length:v.size() encoding:NSUTF8StringEncoding];
}

- (BOOL)isCompatible:(NSString *)filePath {
    if (!_chiselCore) return NO;
    
    std::filesystem::path path([filePath UTF8String]);
    return _chiselCore->isCompatible(path) ? YES : NO;
}

- (NSArray<NSString *> *)supportedExtensions {
    if (!_chiselCore) return @[];
    
    auto exts = _chiselCore->supportedExtensions();
    NSMutableArray *array = [NSMutableArray arrayWithCapacity:exts.size()];
    
    for (const auto& ext : exts) {
        NSString *nsExt = [[NSString alloc] initWithBytes:ext.data() length:ext.size() encoding:NSUTF8StringEncoding];
        [array addObject:nsExt];
    }
    
    return array;
}

- (NSArray<NSString *> *)supportedMimeTypes {
    if (!_chiselCore) return @[];
    
    auto mimes = _chiselCore->supportedMimeTypes();
    NSMutableArray *array = [NSMutableArray arrayWithCapacity:mimes.size()];
    
    for (const auto& mime : mimes) {
        NSString *nsMime = [[NSString alloc] initWithBytes:mime.data() length:mime.size() encoding:NSUTF8StringEncoding];
        [array addObject:nsMime];
    }
    
    return array;
}

@end
