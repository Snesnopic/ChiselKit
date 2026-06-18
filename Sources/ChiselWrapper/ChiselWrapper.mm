#import <Foundation/Foundation.h>
#import "ChiselWrapper.h"
#include "chisel.hpp"
#include "mime_detector.hpp"
#include <string>
#include <vector>
#include <filesystem>
#include <atomic>
#include <memory>

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

    bus.subscribe<chisel::FileProcessStartEvent>([weakSelf](const chisel::FileProcessStartEvent& e) {
        NSString* nsPath = [NSString stringWithUTF8String:e.path.c_str()];
        
        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onStart) {
            strongSelf.onStart(nsPath);
        }
    });
    
    bus.subscribe<chisel::FileProcessCompleteEvent>([weakSelf](const chisel::FileProcessCompleteEvent& e) {
        NSString* nsPath = [NSString stringWithUTF8String:e.path.c_str()];
        uint64_t origSize = static_cast<uint64_t>(e.original_size);
        uint64_t finalSize = static_cast<uint64_t>(e.new_size);
        BOOL replaced = e.replaced ? YES : NO;
        
        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onFinish) {
            strongSelf.onFinish(nsPath, origSize, finalSize, replaced);
        }
    });
    
    bus.subscribe<chisel::FileProcessSkippedEvent>([weakSelf](const chisel::FileProcessSkippedEvent& e) {
        NSString* nsPath = [NSString stringWithUTF8String:e.path.c_str()];
        NSString* nsReason = [NSString stringWithUTF8String:e.reason.c_str()];
        
        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onSkipped) {
            strongSelf.onSkipped(nsPath, nsReason);
        }
    });
    
    bus.subscribe<chisel::FileProcessErrorEvent>([weakSelf](const chisel::FileProcessErrorEvent& e) {
        NSString* nsPath = [NSString stringWithUTF8String:e.path.c_str()];
        NSString* nsError = [NSString stringWithUTF8String:e.error_message.c_str()];
        
        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onError) {
            strongSelf.onError(nsPath, nsError);
        }
    });
    
    bus.subscribe<chisel::FileAnalyzeSkippedEvent>([weakSelf](const chisel::FileAnalyzeSkippedEvent& e) {
        NSString* nsPath = [NSString stringWithUTF8String:e.path.c_str()];
        NSString* nsReason = [NSString stringWithUTF8String:e.reason.c_str()];
        
        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onSkipped) {
            strongSelf.onSkipped(nsPath, nsReason);
        }
    });

    
    bus.subscribe<chisel::ContainerFinalizeErrorEvent>([weakSelf](const chisel::ContainerFinalizeErrorEvent& e) {
        NSString* nsPath = [NSString stringWithUTF8String:e.path.c_str()];
        NSString* nsError = [NSString stringWithUTF8String:e.error_message.c_str()];
        
        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onError) {
            strongSelf.onError(nsPath, nsError);
        }
    });
    
    bus.subscribe<chisel::ContainerFinalizeCompleteEvent>([weakSelf](const chisel::ContainerFinalizeCompleteEvent& e) {
        NSString* nsPath = [NSString stringWithUTF8String:e.path.c_str()];
        uint64_t origSize = static_cast<uint64_t>(e.original_size);
        uint64_t finalSize = static_cast<uint64_t>(e.final_size);
        BOOL replaced = e.replaced ? YES : NO;
        
        ChiselWrapper* strongSelf = weakSelf;
        if (strongSelf && strongSelf.onFinish) {
            strongSelf.onFinish(nsPath, origSize, finalSize, replaced);
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
    executor.process(inputs);
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
