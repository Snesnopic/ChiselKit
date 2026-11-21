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

NSString* NSStringFromPath(const std::filesystem::path& path) {
    return [NSString stringWithUTF8String:path.string().c_str()];
}

NSString* _Nullable NSStringFromPath(const std::optional<std::filesystem::path>& path) {
    return path ? NSStringFromPath(*path) : nil;
}

NSString* NSStringFromText(const std::string& text) {
    return [NSString stringWithUTF8String:text.c_str()];
}

ChiselSkipReason ToChiselSkipReason(chisel::SkipReason reason) {
    switch (reason) {
        case chisel::SkipReason::Junk: return ChiselSkipReasonJunk;
        case chisel::SkipReason::Empty: return ChiselSkipReasonEmpty;
        case chisel::SkipReason::Unsupported: return ChiselSkipReasonUnsupported;
        case chisel::SkipReason::Signed: return ChiselSkipReasonSigned;
        case chisel::SkipReason::NestingTooDeep: return ChiselSkipReasonNestingTooDeep;
        case chisel::SkipReason::NothingToDo: return ChiselSkipReasonNothingToDo;
        case chisel::SkipReason::NoImprovement: return ChiselSkipReasonNoImprovement;
        case chisel::SkipReason::Interrupted: return ChiselSkipReasonInterrupted;
        case chisel::SkipReason::ReadOnly: return ChiselSkipReasonReadOnly;
        case chisel::SkipReason::ChangedDuringRun: return ChiselSkipReasonChangedDuringRun;
    }
    return ChiselSkipReasonUnsupported;
}

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

    bus.subscribe<chisel::FileAnalyzeStartEvent>([weakSelf](const chisel::FileAnalyzeStartEvent& e) {
        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onAnalyzeStart) {
            strongSelf.onAnalyzeStart(NSStringFromPath(e.path));
        }
    });

    bus.subscribe<chisel::FileAnalyzeCompleteEvent>([weakSelf](const chisel::FileAnalyzeCompleteEvent& e) {
        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onAnalyzeComplete) {
            strongSelf.onAnalyzeComplete(NSStringFromPath(e.path), e.extracted ? YES : NO,
                                         static_cast<NSInteger>(e.num_children), NSStringFromPath(e.parent_container));
        }
    });

    // a container whose extraction failed with no fallback: without this it would sit
    // at whatever status .analyzeStart last set, forever
    bus.subscribe<chisel::FileAnalyzeErrorEvent>([weakSelf](const chisel::FileAnalyzeErrorEvent& e) {
        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onError) {
            strongSelf.onError(NSStringFromPath(e.path), NSStringFromText(e.error_message), NSStringFromPath(e.parent_container), NO);
        }
    });

    bus.subscribe<chisel::FileAnalyzeSkippedEvent>([weakSelf](const chisel::FileAnalyzeSkippedEvent& e) {
        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onSkipped) {
            strongSelf.onSkipped(NSStringFromPath(e.path), ToChiselSkipReason(e.reason), NSStringFromText(e.message),
                                 NSStringFromPath(e.parent_container), NO);
        }
    });

    bus.subscribe<chisel::FileProcessStartEvent>([weakSelf](const chisel::FileProcessStartEvent& e) {
        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onStart) {
            strongSelf.onStart(NSStringFromPath(e.path), NSStringFromPath(e.parent_container), e.is_container ? YES : NO);
        }
    });

    bus.subscribe<chisel::FileProcessCompleteEvent>([weakSelf](const chisel::FileProcessCompleteEvent& e) {
        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onFinish) {
            strongSelf.onFinish(NSStringFromPath(e.path), static_cast<uint64_t>(e.original_size), static_cast<uint64_t>(e.new_size),
                                e.replaced ? YES : NO, NSStringFromPath(e.parent_container), e.is_container ? YES : NO);
        }
    });

    bus.subscribe<chisel::FileProcessSkippedEvent>([weakSelf](const chisel::FileProcessSkippedEvent& e) {
        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onSkipped) {
            strongSelf.onSkipped(NSStringFromPath(e.path), ToChiselSkipReason(e.reason), NSStringFromText(e.message),
                                 NSStringFromPath(e.parent_container), e.is_container ? YES : NO);
        }
    });

    bus.subscribe<chisel::FileProcessErrorEvent>([weakSelf](const chisel::FileProcessErrorEvent& e) {
        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onError) {
            strongSelf.onError(NSStringFromPath(e.path), NSStringFromText(e.error_message), NSStringFromPath(e.parent_container),
                               e.is_container ? YES : NO);
        }
    });

    bus.subscribe<chisel::ContainerFinalizeStartEvent>([weakSelf](const chisel::ContainerFinalizeStartEvent& e) {
        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onFinalizeStart) {
            strongSelf.onFinalizeStart(NSStringFromPath(e.path));
        }
    });

    // a container's rebuild outcome is its final result, never its own stream's (isContainer stays NO)
    bus.subscribe<chisel::ContainerFinalizeCompleteEvent>([weakSelf](const chisel::ContainerFinalizeCompleteEvent& e) {
        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onFinish) {
            strongSelf.onFinish(NSStringFromPath(e.path), static_cast<uint64_t>(e.original_size), static_cast<uint64_t>(e.final_size),
                                e.replaced ? YES : NO, NSStringFromPath(e.parent_container), NO);
        }
    });

    bus.subscribe<chisel::ContainerFinalizeErrorEvent>([weakSelf](const chisel::ContainerFinalizeErrorEvent& e) {
        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onError) {
            strongSelf.onError(NSStringFromPath(e.path), NSStringFromText(e.error_message), NSStringFromPath(e.parent_container), NO);
        }
    });

    bus.subscribe<chisel::ContainerFinalizeSkippedEvent>([weakSelf](const chisel::ContainerFinalizeSkippedEvent& e) {
        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onSkipped) {
            strongSelf.onSkipped(NSStringFromPath(e.path), ToChiselSkipReason(e.reason), NSStringFromText(e.message),
                                 NSStringFromPath(e.parent_container), NO);
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
