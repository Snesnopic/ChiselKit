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
                preserveMetadata:(BOOL)preserveMetadata
                 verifyChecksums:(BOOL)verifyChecksums
                 breakSignatures:(BOOL)breakSignatures
                          dryRun:(BOOL)dryRun
                         threads:(uint32_t)threads
                 outputDirectory:(NSString *)outputDirectory {

    _options.iterations = iterations;
    _options.iterations_large = iterationsLarge;
    _options.preserve_metadata = preserveMetadata;
    _options.verify_checksums = verifyChecksums;
    _options.break_signatures = breakSignatures;
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

    // chisel attaches the parent container to FileAnalyzeComplete and to Phase 2's
    // Start/Complete, but not to Error/Skipped events. We remember it here (keyed by
    // path) as soon as analysis reports it, so a Skipped/Error that arrives without
    // a Start (e.g. "Interrupted" after a stop) is still attributed. Scoped to this
    // call; pool threads write concurrently, hence the mutex.
    std::unordered_map<std::string, std::string> parentCache;
    std::mutex parentCacheMutex;

    auto cachedParent = [&parentCache, &parentCacheMutex](const std::filesystem::path& path) -> NSString* {
        std::lock_guard<std::mutex> lock(parentCacheMutex);
        auto it = parentCache.find(path.string());
        return it != parentCache.end() ? [NSString stringWithUTF8String:it->second.c_str()] : nil;
    };

    bus.subscribe<chisel::FileAnalyzeStartEvent>([weakSelf](const chisel::FileAnalyzeStartEvent& e) {
        NSString* nsPath = [NSString stringWithUTF8String:e.path.c_str()];

        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onAnalyzeStart) {
            strongSelf.onAnalyzeStart(nsPath);
        }
    });

    bus.subscribe<chisel::FileAnalyzeCompleteEvent>([weakSelf, &parentCache, &parentCacheMutex](const chisel::FileAnalyzeCompleteEvent& e) {
        NSString* nsPath = [NSString stringWithUTF8String:e.path.c_str()];
        BOOL extracted = e.extracted ? YES : NO;
        NSInteger numChildren = static_cast<NSInteger>(e.num_children);
        NSString* nsParent = nil;

        if (e.parent) {
            std::string parentStr = e.parent->string();
            nsParent = [NSString stringWithUTF8String:parentStr.c_str()];

            std::lock_guard<std::mutex> lock(parentCacheMutex);
            parentCache[e.path.string()] = parentStr;
        }

        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onAnalyzeComplete) {
            strongSelf.onAnalyzeComplete(nsPath, extracted, numChildren, nsParent);
        }
    });

    bus.subscribe<chisel::FileAnalyzeErrorEvent>([weakSelf](const chisel::FileAnalyzeErrorEvent& e) {
        NSString* nsPath = [NSString stringWithUTF8String:e.path.c_str()];
        NSString* nsError = [NSString stringWithUTF8String:e.error_message.c_str()];

        // Phase 1 (analysis) errors: a pure container (can_recompress() == false) whose
        // extraction failed with no fallback - without this, the file would silently
        // vanish (stuck at whatever status .analyzeStart last set, forever). Always
        // refers to the container itself; chisel doesn't attach parent_container/is_container here.
        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onError) {
            strongSelf.onError(nsPath, nsError, nil, NO);
        }
    });

    bus.subscribe<chisel::ContainerFinalizeStartEvent>([weakSelf](const chisel::ContainerFinalizeStartEvent& e) {
        NSString* nsPath = [NSString stringWithUTF8String:e.path.c_str()];
        
        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onFinalizeStart) {
            strongSelf.onFinalizeStart(nsPath);
        }
    });

    bus.subscribe<chisel::FileProcessStartEvent>([weakSelf](const chisel::FileProcessStartEvent& e) {
        NSString* nsPath = [NSString stringWithUTF8String:e.path.c_str()];
        NSString* nsParent = nil;
        if (e.parent_container) {
            nsParent = [NSString stringWithUTF8String:e.parent_container->string().c_str()];
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
    
    bus.subscribe<chisel::FileProcessSkippedEvent>([weakSelf, cachedParent](const chisel::FileProcessSkippedEvent& e) {
        NSString* nsPath = [NSString stringWithUTF8String:e.path.c_str()];
        NSString* nsReason = [NSString stringWithUTF8String:e.reason.c_str()];
        NSString* nsParent = cachedParent(e.path);
        BOOL isContainer = e.is_container ? YES : NO;

        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onSkipped) {
            strongSelf.onSkipped(nsPath, nsReason, nsParent, isContainer, NO);
        }
    });

    bus.subscribe<chisel::FileProcessErrorEvent>([weakSelf, cachedParent](const chisel::FileProcessErrorEvent& e) {
        NSString* nsPath = [NSString stringWithUTF8String:e.path.c_str()];
        NSString* nsError = [NSString stringWithUTF8String:e.error_message.c_str()];
        NSString* nsParent = cachedParent(e.path);
        BOOL isContainer = e.is_container ? YES : NO;

        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onError) {
            strongSelf.onError(nsPath, nsError, nsParent, isContainer);
        }
    });

    bus.subscribe<chisel::FileAnalyzeSkippedEvent>([weakSelf, cachedParent](const chisel::FileAnalyzeSkippedEvent& e) {
        NSString* nsPath = [NSString stringWithUTF8String:e.path.c_str()];
        NSString* nsReason = [NSString stringWithUTF8String:e.reason.c_str()];
        BOOL isSigned = e.is_signed ? YES : NO;

        // a phase 1 skip takes the place of FileAnalyzeComplete, so the cache only knows the
        // parent when chisel publishes this from phase 2 (no processor found at that point)
        NSString* nsParent = cachedParent(e.path);

        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onSkipped) {
            strongSelf.onSkipped(nsPath, nsReason, nsParent, NO, isSigned);
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
