#ifndef ChiselWrapper_h
#define ChiselWrapper_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ChiselArchiveNode : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *mimeType;
@property (nonatomic, assign) uint64_t size;
@property (nonatomic, strong, nullable) NSArray<ChiselArchiveNode *> *children;
@end

@interface ChiselWrapper : NSObject

@property (nonatomic, copy, nullable) void (^onAnalyzeStart)(NSString *path);
@property (nonatomic, copy, nullable) void (^onAnalyzeComplete)(NSString *path, BOOL extracted, NSInteger numChildren);
@property (nonatomic, copy, nullable) void (^onFinalizeStart)(NSString *path);
@property (nonatomic, copy, nullable) void (^onStart)(NSString *path);
@property (nonatomic, copy, nullable) void (^onFinish)(NSString *path, uint64_t sizeBefore, uint64_t sizeAfter, BOOL replaced);
@property (nonatomic, copy, nullable) void (^onError)(NSString *path, NSString *error);
@property (nonatomic, copy, nullable) void (^onSkipped)(NSString *path, NSString *reason);
@property (nonatomic, copy, nullable) void (^onLog)(NSString *tag, NSString *message);

- (void)setOptionsWithIterations:(uint32_t)iterations
                 iterationsLarge:(uint32_t)iterationsLarge
                       maxTokens:(uint32_t)maxTokens
                preserveMetadata:(BOOL)preserveMetadata
                 verifyChecksums:(BOOL)verifyChecksums
                         threads:(uint32_t)threads
                 outputDirectory:(nullable NSString *)outputDirectory;

- (void)recompressFiles:(NSArray<NSString *> *)filePaths;
- (void)stop;

- (NSString *)detectMimeType:(NSString *)filePath;
- (nullable ChiselArchiveNode *)inspectArchive:(NSString *)archivePath error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

#endif /* ChiselWrapper_h */
