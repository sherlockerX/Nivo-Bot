#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

NS_ASSUME_NONNULL_BEGIN

/// 严格交通方式枚举，调用方不能把未知方式隐式降级成驾车。
typedef NS_ENUM(NSInteger, NivoMapsMode) {
    NivoMapsModeDriving,
    NivoMapsModeWalking,
    NivoMapsModeTransit,
    NivoMapsModeCycling,
};

/// 地图协议自身的失败类型，供应商错误保留原始NSError。
typedef NS_ENUM(NSInteger, NivoMapsErrorCode) {
    NivoMapsErrorInvalidArguments = 1,
    NivoMapsErrorAmbiguousLocation,
    NivoMapsErrorNoLocation,
    NivoMapsErrorTimeout,
    NivoMapsErrorNoData,
    NivoMapsErrorWrongThread,
};

FOUNDATION_EXPORT NSString *const NivoMapsErrorDomain;

/// 创建可序列化的协议错误；附加字段只应包含公开请求及解析信息。
FOUNDATION_EXPORT NSError *NivoMapsMakeError(NivoMapsErrorCode code, NSString *message, NSDictionary *details);
/// 增加执行阶段，但保留供应商错误域和原始错误码。
FOUNDATION_EXPORT NSError *NivoMapsErrorAtStage(NSError *error, NSString *stage);
/// 输出稳定错误码，以及可用于诊断的供应商错误域、错误码和阶段。
FOUNDATION_EXPORT NSDictionary *NivoMapsErrorDetails(NSError *error);
/// 只有唯一解析结果可继续，多结果必须由用户消歧。
FOUNDATION_EXPORT NSDictionary *_Nullable NivoMapsSelectEndpoint(
    NSArray<NSDictionary *> *candidates, NSString *endpoint, NSError *_Nullable *_Nullable error);

/// 不访问网络的完整请求解析结果，先验证全部端点和选项再交给MapKit。
@interface NivoMapsRequest : NSObject
@property(nonatomic, copy, readonly) NSString *command;
@property(nonatomic, readonly) NivoMapsMode mode;
@property(nonatomic, copy, readonly) NSString *modeName;
@property(nonatomic, copy, readonly) NSString *query;
@property(nonatomic, readonly) double latitude;
@property(nonatomic, readonly) double longitude;
@property(nonatomic, readonly) double radiusMeters;
@property(nonatomic, readonly) NSInteger limit;
@property(nonatomic, copy, readonly) NSDictionary *fromEndpoint;
@property(nonatomic, copy, readonly) NSDictionary *toEndpoint;

/// arguments只包含选项，不包含程序名和子命令；失败时不产生部分请求。
+ (nullable instancetype)parse:(NSString *)command
                    arguments:(NSArray<NSString *> *)arguments
                        error:(NSError *_Nullable *_Nullable)error;
@end

/// 线程安全的一次性交付，超时终止后任何迟到回调都不能改写结果。
@interface NivoMapsAsyncResult : NSObject
@property(nonatomic, copy, readonly, nullable) NSDictionary *data;
@property(nonatomic, strong, readonly, nullable) NSError *error;
@property(nonatomic, readonly, getter=isFinished) BOOL finished;

/// 只接收第一次完成；该方法可由任意线程调用。
- (void)finish:(nullable NSDictionary *)data error:(nullable NSError *)error;
/// 等待结果或写入阶段超时；仅供非UI线程使用，零秒可用于确定性测试。
- (BOOL)wait:(NSTimeInterval)seconds stage:(NSString *)stage;
/// 超时时在主线程取消服务；允许取消句柄晚于超时注册。
- (void)setCancellation:(dispatch_block_t)cancellation;
@end

NS_ASSUME_NONNULL_END
