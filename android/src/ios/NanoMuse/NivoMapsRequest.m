#import "NivoMapsRequest.h"
#include <math.h>

NSString *const NivoMapsErrorDomain = @"NivoMapsErrorDomain";

NSError *NivoMapsMakeError(NivoMapsErrorCode code, NSString *message, NSDictionary *details) {
    NSMutableDictionary *information = [details mutableCopy];
    information[NSLocalizedDescriptionKey] = message;
    return [NSError errorWithDomain:NivoMapsErrorDomain code:code userInfo:information];
}

NSError *NivoMapsErrorAtStage(NSError *error, NSString *stage) {
    NSMutableDictionary *information = [error.userInfo mutableCopy];
    information[@"stage"] = stage;
    return [NSError errorWithDomain:error.domain code:error.code userInfo:information];
}

NSDictionary *NivoMapsErrorDetails(NSError *error) {
    NSString *code = @"provider_error";
    if ([error.domain isEqualToString:NivoMapsErrorDomain]) {
        switch (error.code) {
            case NivoMapsErrorInvalidArguments: code = @"invalid_args"; break;
            case NivoMapsErrorAmbiguousLocation: code = @"ambiguous_location"; break;
            case NivoMapsErrorNoLocation: code = @"location_not_found"; break;
            case NivoMapsErrorTimeout: code = @"timeout"; break;
            case NivoMapsErrorNoData: code = @"no_data"; break;
            case NivoMapsErrorWrongThread: code = @"wrong_thread"; break;
        }
    } else if ([error.domain isEqualToString:@"MKErrorDomain"]) {
        code = @"mapkit_error";
    } else if ([error.domain isEqualToString:@"kCLErrorDomain"]) {
        code = @"geocoding_error";
    }
    NSMutableDictionary *details = [@{@"code": code, @"message": error.localizedDescription} mutableCopy];
    if (![error.domain isEqualToString:NivoMapsErrorDomain]) {
        details[@"domain"] = error.domain;
        details[@"provider_code"] = @(error.code);
    }
    for (NSString *key in @[@"stage", @"endpoint", @"candidates", @"candidate_count"]) {
        if (error.userInfo[key]) details[key] = error.userInfo[key];
    }
    return details;
}

NSDictionary *NivoMapsSelectEndpoint(NSArray<NSDictionary *> *candidates, NSString *endpoint, NSError **error) {
    if (error) *error = nil;
    if (candidates.count == 1) return candidates.firstObject;
    BOOL ambiguous = candidates.count > 1;
    NSDictionary *details = @{
        @"endpoint": endpoint,
        @"candidates": [candidates subarrayWithRange:NSMakeRange(0, MIN(candidates.count, 10))],
        @"candidate_count": @(candidates.count),
    };
    if (error) *error = NivoMapsMakeError(ambiguous ? NivoMapsErrorAmbiguousLocation : NivoMapsErrorNoLocation,
        ambiguous ? @"Multiple locations match. Choose a candidate and retry with its coordinates."
                  : @"No location matched this endpoint.", details);
    return nil;
}

/// 禁止doubleValue把部分数字、NaN或无穷转换成可用坐标。
static BOOL nivo_maps_number(NSString *text, double *value) {
    if (text == nil) return NO;
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *pattern = @"\\A[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?\\z";
    if ([trimmed rangeOfString:pattern options:NSRegularExpressionSearch].location == NSNotFound) return NO;
    double parsed = trimmed.doubleValue;
    if (!isfinite(parsed)) return NO;
    *value = parsed;
    return YES;
}

/// 识别疑似坐标，避免错误坐标被悄悄当作地名发送给地理编码服务。
static BOOL nivo_maps_numeric_component(NSString *text) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *pattern = @"\\A(?:[+-]?(?:[0-9.]|(?i:nan|inf))[^\\s]*|[0-9.+eE\\s-]+)\\z";
    return [trimmed rangeOfString:pattern options:NSRegularExpressionSearch].location != NSNotFound;
}

/// 地址可含逗号和街道门牌；数值样式端点必须完整且在经纬度范围内。
static NSDictionary *nivo_maps_endpoint(NSString *text, NSString *name, NSError **error) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) {
        if (error) *error = NivoMapsMakeError(NivoMapsErrorInvalidArguments,
            [NSString stringWithFormat:@"Required: --%@", name], @{@"endpoint": name});
        return nil;
    }
    NSArray<NSString *> *parts = [trimmed componentsSeparatedByString:@","];
    NSString *firstPart = [parts.firstObject stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    // 城市名后面的数字可以是邮编；只有第一段呈数值样式或留空才按坐标校验。
    BOOL looksNumeric = parts.count > 1 && (nivo_maps_numeric_component(firstPart) || firstPart.length == 0);
    if (!looksNumeric) return @{@"input": trimmed, @"source": @"address"};
    double latitude = 0, longitude = 0;
    BOOL valid = parts.count == 2 && nivo_maps_number(parts[0], &latitude) &&
        nivo_maps_number(parts[1], &longitude) && fabs(latitude) <= 90 && fabs(longitude) <= 180;
    if (!valid) {
        if (error) *error = NivoMapsMakeError(NivoMapsErrorInvalidArguments,
            @"Coordinates must be finite latitude,longitude values within [-90,90] and [-180,180].",
            @{@"endpoint": name});
        return nil;
    }
    return @{@"input": trimmed, @"name": trimmed, @"lat": @(latitude), @"lon": @(longitude),
             @"source": @"coordinates", @"accuracy_m": NSNull.null};
}

/// 先统一别名再检查重复项，防止两个坐标选项覆盖彼此。
static NSDictionary *nivo_maps_options(NSString *command, NSArray<NSString *> *arguments, NSError **error) {
    NSArray *names = [command isEqualToString:@"search"]
        ? @[@"--query", @"--lat", @"--lon", @"--radius", @"--limit"] : @[@"--from", @"--to", @"--mode"];
    NSMutableDictionary *options = [NSMutableDictionary dictionary];
    for (NSUInteger index = 0; index < arguments.count; index++) {
        NSString *argument = arguments[index];
        if ([@[@"--compact", @"--quiet", @"-q"] containsObject:argument]) continue;
        NSRange equals = [argument rangeOfString:@"="];
        NSString *key = equals.location == NSNotFound ? argument : [argument substringToIndex:equals.location];
        if ([key isEqualToString:@"--latitude"]) key = @"--lat";
        if ([key isEqualToString:@"--longitude"]) key = @"--lon";
        if (![names containsObject:key] || options[key]) {
            if (error) *error = NivoMapsMakeError(NivoMapsErrorInvalidArguments,
                [NSString stringWithFormat:@"Unknown or duplicate option: %@", key], @{});
            return nil;
        }
        NSString *value = equals.location == NSNotFound ? nil : [argument substringFromIndex:equals.location + 1];
        if (value == nil && index + 1 < arguments.count) value = arguments[++index];
        if (value == nil || [value hasPrefix:@"--"] || [value isEqualToString:@"-q"]) {
            if (error) *error = NivoMapsMakeError(NivoMapsErrorInvalidArguments,
                [NSString stringWithFormat:@"Missing value for %@", key], @{});
            return nil;
        }
        options[key] = value;
    }
    return options;
}

@interface NivoMapsRequest ()
@property(nonatomic, copy, readwrite) NSString *command;
@property(nonatomic, readwrite) NivoMapsMode mode;
@property(nonatomic, copy, readwrite) NSString *modeName;
@property(nonatomic, copy, readwrite) NSString *query;
@property(nonatomic, readwrite) double latitude;
@property(nonatomic, readwrite) double longitude;
@property(nonatomic, readwrite) double radiusMeters;
@property(nonatomic, readwrite) NSInteger limit;
@property(nonatomic, copy, readwrite) NSDictionary *fromEndpoint;
@property(nonatomic, copy, readwrite) NSDictionary *toEndpoint;
@end

@implementation NivoMapsRequest

/// 所有数值按同一规则验证，默认值仅在选项未提供时启用。
- (BOOL)readSearch:(NSDictionary *)options error:(NSError **)error {
    NSString *query = [options[@"--query"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    double latitude = 0, longitude = 0, radius = 0, limit = 0;
    BOOL valid = query.length > 0 && nivo_maps_number(options[@"--lat"], &latitude) &&
        nivo_maps_number(options[@"--lon"], &longitude) && fabs(latitude) <= 90 && fabs(longitude) <= 180;
    BOOL rangeValid = nivo_maps_number(options[@"--radius"] ?: @"1000", &radius) && radius > 0 && radius <= 20000000;
    BOOL limitValid = nivo_maps_number(options[@"--limit"] ?: @"10", &limit) && limit >= 1 && limit <= 100 && floor(limit) == limit;
    if (!valid || !rangeValid || !limitValid) {
        if (error) *error = NivoMapsMakeError(NivoMapsErrorInvalidArguments,
            @"Search requires --query, finite --lat [-90,90], --lon [-180,180], --radius (0,20000000], and integer --limit [1,100].", @{});
        return NO;
    }
    self.query = query;
    self.latitude = latitude;
    self.longitude = longitude;
    self.radiusMeters = radius;
    self.limit = (NSInteger)limit;
    return YES;
}

/// 验证完整两端和交通方式后才允许调用方启动网络请求。
- (BOOL)readDirections:(NSDictionary *)options error:(NSError **)error {
    NSString *mode = options[@"--mode"] ?: @"driving";
    NSDictionary *modes = @{@"driving": @(NivoMapsModeDriving), @"walking": @(NivoMapsModeWalking),
                           @"transit": @(NivoMapsModeTransit), @"cycling": @(NivoMapsModeCycling)};
    if (modes[mode] == nil) {
        if (error) *error = NivoMapsMakeError(NivoMapsErrorInvalidArguments,
            @"Mode must be driving, walking, transit, or cycling.", @{});
        return NO;
    }
    NSDictionary *from = nivo_maps_endpoint(options[@"--from"], @"from", error);
    if (from == nil) return NO;
    NSDictionary *to = nivo_maps_endpoint(options[@"--to"], @"to", error);
    if (to == nil) return NO;
    self.mode = [modes[mode] integerValue];
    self.modeName = mode;
    self.fromEndpoint = from;
    self.toEndpoint = to;
    return YES;
}

+ (instancetype)parse:(NSString *)command arguments:(NSArray<NSString *> *)arguments error:(NSError **)error {
    if (error) *error = nil;
    if (![@[@"search", @"route", @"eta"] containsObject:command] || arguments.count > 32) {
        if (error) *error = NivoMapsMakeError(NivoMapsErrorInvalidArguments, @"Unknown command or too many arguments.", @{});
        return nil;
    }
    for (NSString *argument in arguments) {
        if (argument.length > 4096) {
            if (error) *error = NivoMapsMakeError(NivoMapsErrorInvalidArguments, @"Argument exceeds 4096 characters.", @{});
            return nil;
        }
    }
    NSDictionary *options = nivo_maps_options(command, arguments, error);
    if (options == nil) return nil;
    NivoMapsRequest *request = [[self alloc] init];
    request.command = command;
    request.modeName = @"driving";
    request.query = @"";
    request.fromEndpoint = @{};
    request.toEndpoint = @{};
    BOOL valid = [command isEqualToString:@"search"] ? [request readSearch:options error:error]
                                                   : [request readDirections:options error:error];
    return valid ? request : nil;
}
@end

@implementation NivoMapsAsyncResult {
    NSLock *_lock;
    dispatch_semaphore_t _semaphore;
    NSDictionary *_resultData;
    NSError *_resultError;
    dispatch_block_t _cancellation;
    BOOL _finished;
    BOOL _timedOut;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
        _semaphore = dispatch_semaphore_create(0);
    }
    return self;
}

- (NSDictionary *)data {
    [_lock lock];
    NSDictionary *value = _resultData;
    [_lock unlock];
    return value;
}

- (NSError *)error {
    [_lock lock];
    NSError *value = _resultError;
    [_lock unlock];
    return value;
}

- (BOOL)isFinished {
    [_lock lock];
    BOOL value = _finished;
    [_lock unlock];
    return value;
}

- (void)finish:(NSDictionary *)data error:(NSError *)error {
    [_lock lock];
    if (_finished) { [_lock unlock]; return; }
    _finished = YES;
    _resultData = [data copy];
    _resultError = error;
    _cancellation = nil;
    [_lock unlock];
    dispatch_semaphore_signal(_semaphore);
}

- (BOOL)wait:(NSTimeInterval)seconds stage:(NSString *)stage {
    if (!self.isFinished) {
        dispatch_semaphore_wait(_semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)));
    }
    [_lock lock];
    dispatch_block_t cancellation = nil;
    if (!_finished) {
        _finished = YES;
        _timedOut = YES;
        _resultError = NivoMapsMakeError(NivoMapsErrorTimeout, @"The maps request timed out.", @{@"stage": stage});
        cancellation = _cancellation;
        _cancellation = nil;
    }
    BOOL completed = !_timedOut;
    [_lock unlock];
    if (cancellation) dispatch_async(dispatch_get_main_queue(), cancellation);
    return completed;
}

- (void)setCancellation:(dispatch_block_t)cancellation {
    [_lock lock];
    BOOL timedOut = _timedOut;
    if (!_finished) _cancellation = [cancellation copy];
    [_lock unlock];
    if (timedOut) dispatch_async(dispatch_get_main_queue(), cancellation);
}
@end
