#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 在创建进程之前冻结argv与环境，拒绝截断、嵌入NUL和超限参数。
@interface NivoShellInvocation : NSObject
@property (nonatomic, readonly, copy) NSData *argumentData;
@property (nonatomic, readonly, copy) NSData *environmentData;
@property (nonatomic, readonly) NSUInteger argumentCount;
/// 同名环境变量覆盖默认值，每个键最终只有一个条目。
- (nullable instancetype)initWithExecutable:(NSString *)executable
                                 arguments:(nullable NSArray<NSString *> *)arguments
                               environment:(nullable NSDictionary<NSString *, NSString *> *)environment;
@end

/// 单流的有界字节档案；达到保存上限后仍统计读取总量。
@interface NivoShellCapture : NSObject
@property (nonatomic, readonly) uint64_t totalBytes;
@property (nonatomic, readonly) BOOL isTruncated;
@property (nonatomic, readonly, copy) NSString *output;
@property (nonatomic, readonly, copy, nullable) NSString *captureError;
/// 上限按字节计算，输出前再去掉末尾不完整的UTF-8字符。
- (instancetype)initWithMaximumBytes:(NSUInteger)maximumBytes;
/// 返回本次实际保存的前缀，供已有逐行回调复用。
- (NSData *)appendData:(NSData *)data NS_SWIFT_NAME(append(_:));
/// EOF、读取错误和强制停止必须由调用方明确区分。
- (void)finishReachedEOF:(BOOL)reachedEOF NS_SWIFT_NAME(finish(reachedEOF:));
@end

NS_ASSUME_NONNULL_END
