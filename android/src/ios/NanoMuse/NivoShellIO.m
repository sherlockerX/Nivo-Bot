#import "NivoShellIO.h"
#include "NivoShellBytes.h"
#include <string.h>

/// 与来宾exec参数空间保持一致，足以容纳64KB脚本及其独立参数。
static const NSUInteger NIVO_SHELL_VECTOR_MAX_BYTES = 128 * 1024;

/// UTF-8转换必须无损，NUL会改变C参数边界，因此在创建任务前拒绝。
static NSData *NivoShellStringData(NSString *value) {
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
    if (!data || memchr(data.bytes, 0, data.length) != NULL) return nil;
    return data;
}

/// 生成双NUL结尾的字符串向量，溢出时整体失败，绝不静默丢弃末尾参数。
static NSData *NivoShellPack(NSArray<NSString *> *values) {
    NSMutableData *packed = [NSMutableData data];
    uint8_t terminator = 0;
    for (NSString *value in values) {
        NSData *data = NivoShellStringData(value);
        if (!data || data.length >= NIVO_SHELL_VECTOR_MAX_BYTES - packed.length - 1) return nil;
        [packed appendData:data];
        [packed appendBytes:&terminator length:1];
    }
    [packed appendBytes:&terminator length:1];
    return packed;
}

/// 默认固定偏移也保留秒，处理UTC以西不足一小时的偏移时不会丢失符号。
static NSString *NivoShellDefaultTimezone(void) {
    NSInteger offset = NSTimeZone.systemTimeZone.secondsFromGMT;
    NSInteger magnitude = labs(offset);
    return [NSString stringWithFormat:@"LCL%@%ld:%02ld:%02ld", offset < 0 ? @"+" : @"-",
            (long)(magnitude / 3600), (long)(magnitude / 60 % 60), (long)(magnitude % 60)];
}

/// 环境字典先合并再序列化，调用方覆盖HOME、TZ等值时不会产生重复键。
static NSDictionary<NSString *, NSString *> *NivoShellEnvironment(BOOL isNode,
        NSDictionary<NSString *, NSString *> *overrides) {
    NSMutableDictionary *values = [@{
        @"TERM": @"xterm-256color", @"HOME": @"/root",
        @"PATH": @"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/bin",
        @"LANG": @"C.UTF-8", @"CHARSET": @"UTF-8", @"ENV": @"/etc/profile",
        @"OPENSSL_armcap": @"0", @"BROWSER": @"/usr/local/bin/minis-open",
        @"TZ": NivoShellDefaultTimezone(), @"GODEBUG": @"asyncpreemptoff=1",
        @"GOMAXPROCS": @"2", @"NO_COLOR": @"1", @"PYTHONMALLOC": @"malloc",
        @"PYTHONDONTWRITEBYTECODE": @"1"
    } mutableCopy];
    if (isNode) values[@"LD_PRELOAD"] = @"/lib/zero_free.so";
    for (NSString *key in overrides) {
        if (key.length == 0 || [key containsString:@"="] || !NivoShellStringData(key)) return nil;
        if (!NivoShellStringData(overrides[key])) return nil;
        values[key] = overrides[key];
    }
    return values;
}

/// 完整的无效字节用替换字符显示并记录错误，仍保留其后可读内容。
static NSString *NivoShellDecode(NSData *data, BOOL isTruncated, bool *hasEncodingError) {
    NSMutableString *output = [NSMutableString string];
    const uint8_t *bytes = data.bytes;
    NSUInteger offset = 0;
    *hasEncodingError = false;
    while (offset < data.length) {
        bool isInvalid = false;
        NSUInteger length = nivo_shell_utf8_prefix(bytes + offset, data.length - offset, &isInvalid);
        NSString *prefix = [[NSString alloc] initWithBytes:bytes + offset length:length encoding:NSUTF8StringEncoding];
        if (prefix) [output appendString:prefix];
        offset += length;
        if (!isInvalid && (offset == data.length || isTruncated)) break;
        *hasEncodingError = true;
        [output appendString:@"\uFFFD"];
        if (!isInvalid) break;
        offset++;
    }
    return output;
}

@implementation NivoShellInvocation

- (instancetype)initWithExecutable:(NSString *)executable arguments:(NSArray<NSString *> *)arguments
                       environment:(NSDictionary<NSString *, NSString *> *)environment {
    self = [super init];
    if (!self || executable.length == 0 || !NivoShellStringData(executable)) return nil;
    BOOL isNode = [executable.lastPathComponent isEqualToString:@"node"];
    NSMutableArray *argv = [NSMutableArray arrayWithObject:executable];
    if (isNode) [argv addObjectsFromArray:@[@"--jitless", @"--no-lazy", @"--no-expose-wasm", @"--max-old-space-size=512"]];
    if (arguments) [argv addObjectsFromArray:arguments];
    NSDictionary *merged = NivoShellEnvironment(isNode, environment);
    if (!merged) return nil;
    NSMutableArray *entries = [NSMutableArray array];
    for (NSString *key in [[merged allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        [entries addObject:[NSString stringWithFormat:@"%@=%@", key, merged[key]]];
    }
    _argumentData = NivoShellPack(argv);
    _environmentData = NivoShellPack(entries);
    _argumentCount = argv.count;
    if (!_argumentData || !_environmentData) return nil;
    return self;
}
@end

@interface NivoShellCapture ()
@property (nonatomic) NSUInteger maximumBytes;
@property (nonatomic) NSMutableData *data;
@property (nonatomic, readwrite) uint64_t totalBytes;
@property (nonatomic, readwrite, copy) NSString *output;
@property (nonatomic, readwrite, copy, nullable) NSString *captureError;
@end

@implementation NivoShellCapture

- (instancetype)initWithMaximumBytes:(NSUInteger)maximumBytes {
    self = [super init];
    if (self) {
        _maximumBytes = maximumBytes;
        _data = [NSMutableData data];
        _output = @"";
    }
    return self;
}

- (NSData *)appendData:(NSData *)data {
    @synchronized(self) {
        _totalBytes = UINT64_MAX - _totalBytes < data.length ? UINT64_MAX : _totalBytes + data.length;
        NSUInteger length = MIN(data.length, _maximumBytes - _data.length);
        NSData *prefix = length == data.length ? data : [data subdataWithRange:NSMakeRange(0, length)];
        [_data appendData:prefix];
        return prefix;
    }
}

- (BOOL)isTruncated {
    @synchronized(self) { return _totalBytes > _data.length; }
}

- (void)finishReachedEOF:(BOOL)reachedEOF {
    @synchronized(self) {
        bool hasEncodingError = false;
        _output = NivoShellDecode(_data, self.isTruncated, &hasEncodingError);
        if (!reachedEOF) _captureError = @"SCRIPT_OUTPUT_DRAIN_INCOMPLETE";
        else if (hasEncodingError) _captureError = @"SCRIPT_OUTPUT_ENCODING_INVALID";
    }
}
@end
