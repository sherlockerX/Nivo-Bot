#import <Foundation/Foundation.h>
#import "NivoMapsRequest.h"
#import "NivoMapsTransport.h"
#import "../NativeOffloads/MapsOffload.m"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static NSDictionary *capturedOutput;
static BOOL capturedCompact;
static BOOL capturedQuiet;
NSString *const NOFF_ERR_INVALID_ARGS = @"invalid_args";

/// 替换沙盒输出设施，测试直接调用生产maps_handler且不创建沙盒或请求真实服务。
BOOL noff_has_flag(int argc, char **argv, const char *name) {
    for (int index = 1; index < argc; index++) {
        if (strcmp(argv[index], name) == 0) return YES;
    }
    return NO;
}
NSDictionary *noff_json_error(NSString *tool, NSString *action, NSString *code, NSString *message) {
    return @{@"ok": @NO, @"tool": tool, @"action": action, @"error": @{@"code": code, @"message": message}};
}
NSDictionary *noff_json_envelope(NSString *tool, NSString *action, id data) {
    return @{@"ok": @YES, @"tool": tool, @"action": action, @"data": data};
}
void noff_emit_json(int descriptor, NSDictionary *dictionary, BOOL compact, BOOL quiet) {
    (void)descriptor;
    capturedOutput = [dictionary copy];
    capturedCompact = compact;
    capturedQuiet = quiet;
}
void noff_emit_help(int descriptor, NSString *help) { (void)descriptor; (void)help; }
NSString *noff_format_date(NSDate *date) { return date.description; }
void noff_ensure_guest_stub(const char *path) { (void)path; }
int native_offload_add_handler(const char *name, native_handler_func handler) { (void)name; (void)handler; return 0; }

/// 不访问地图服务，验证入口实际使用的参数规则和超时交付边界。
static void maps_require(BOOL condition, NSString *message) {
    if (!condition) { NSLog(@"FAIL: %@", message); abort(); }
}

/// 坐标、模式与全部数值先验证，非法目标不能启动起点地理编码。
static void testArguments(void) {
    NSError *error = nil;
    NivoMapsRequest *cycling = [NivoMapsRequest parse:@"route"
        arguments:@[@"--from", @"37.7,-122.4", @"--to", @"38,-123", @"--mode", @"cycling"] error:&error];
    maps_require(cycling != nil && error == nil, @"cycling必须被接受");
    maps_require(cycling.mode == NivoMapsModeCycling, @"cycling不能变成driving");
    maps_require([cycling.modeName isEqualToString:@"cycling"], @"输出模式保留原义");
    maps_require(NivoMapsTransportType(cycling.mode) == MKDirectionsTransportTypeCycling, @"实际MapKit请求必须使用骑行枚举");
    maps_require(NivoMapsTransportType(NivoMapsModeWalking) == MKDirectionsTransportTypeWalking, @"步行映射正确");
    maps_require(NivoMapsTransportType(NivoMapsModeTransit) == MKDirectionsTransportTypeTransit, @"公交映射正确");
    maps_require(NivoMapsTransportType(NivoMapsModeDriving) == MKDirectionsTransportTypeAutomobile, @"驾车映射正确");
    maps_require(NivoMapsTransportType((NivoMapsMode)999) == 0, @"非法枚举不能变驾车");
    NSArray *invalidCoordinates = @[@"NaN,1", @"1,Infinity", @"37x,-122", @"91,0", @"1,181", @"1,2,3",
        @"1,", @",", @",1", @"1e999,2", @"1 2,3", @"1.2.3,4"];
    for (NSString *coordinate in invalidCoordinates) {
        error = nil;
        maps_require([NivoMapsRequest parse:@"route" arguments:@[@"--from", @"Some address", @"--to", coordinate] error:&error] == nil,
            [@"必须拒绝非法坐标：" stringByAppendingString:coordinate]);
        maps_require(error.code == NivoMapsErrorInvalidArguments, @"必须在请求之前拒绝");
    }
    for (NSString *mode in @[@"biking", @"fly", @"", @"Driving"]) {
        maps_require([NivoMapsRequest parse:@"eta" arguments:@[@"--from", @"1,2", @"--to", @"3,4", @"--mode", mode] error:&error] == nil,
            @"未知模式不能回退成driving");
    }
    NSArray *badSearches = @[
        @[@"--lat", @"nan", @"--lon", @"1"], @[@"--lat", @"1foo", @"--lon", @"1"],
        @[@"--lat", @"1", @"--lon", @"-181"], @[@"--lat", @"1", @"--lon", @"1", @"--radius", @"10m"],
        @[@"--lat", @"1", @"--lon", @"1", @"--radius", @"0"],
        @[@"--lat", @"1", @"--lon", @"1", @"--limit", @"1.5"],
        @[@"--lat", @"1", @"--latitude", @"2", @"--lon", @"1"]];
    for (NSArray *arguments in badSearches) {
        maps_require([NivoMapsRequest parse:@"search" arguments:[@[@"--query", @"test"] arrayByAddingObjectsFromArray:arguments] error:&error] == nil,
            @"非法搜索参数必须拒绝");
    }
    NivoMapsRequest *address = [NivoMapsRequest parse:@"eta"
        arguments:@[@"--from", @"123 Example Street, Example City", @"--to", @"Boston, MA"] error:&error];
    maps_require(address != nil && address.fromEndpoint[@"lat"] == nil, @"普通含逗号地址不能当坐标");
    maps_require([NivoMapsRequest parse:@"eta" arguments:@[@"--from", @"Example City, 10001", @"--to", @"1,2"] error:&error] != nil,
        @"地名后含邮编不能误判为非法坐标");
    maps_require([NivoMapsRequest parse:@"route" arguments:@[@"--from", @"1,2", @"--to", @"3,4", @"--mode"] error:&error] == nil,
        @"缺失mode值不能采用默认值");
    NivoMapsRequest *defaults = [NivoMapsRequest parse:@"search"
        arguments:@[@"--query=test", @"--latitude", @"-90", @"--longitude", @"180", @"--compact"] error:&error];
    maps_require(defaults != nil && defaults.latitude == -90 && defaults.longitude == 180, @"合法边界和别名可用");
    maps_require(defaults.limit == 10 && defaults.radiusMeters == 1000, @"缺省查询半径与数量保持兼容");
    NivoMapsRequest *origin = [NivoMapsRequest parse:@"eta"
        arguments:@[@"--from", @" 0, 0 ", @"--to", @"1e1,-1e2"] error:&error];
    maps_require(origin != nil && [origin.fromEndpoint[@"lat"] doubleValue] == 0, @"零坐标不是缺失位置");
    maps_require([origin.modeName isEqualToString:@"driving"] && origin.fromEndpoint[@"accuracy_m"] == NSNull.null,
        @"缺省驾车与未知输入精度明确");
}

/// 多候选、原厂错误与超时有不同结构，不伪造距离或精度。
static void testResolutionAndErrors(void) {
    NSDictionary *first = @{@"lat": @1, @"lon": @2, @"name": @"First", @"accuracy_m": [NSNull null]};
    NSDictionary *second = @{@"lat": @3, @"lon": @4, @"name": @"Second", @"accuracy_m": @25};
    NSError *error = nil;
    maps_require(NivoMapsSelectEndpoint(@[first, second], @"from", &error) == nil, @"多候选不能选第一条");
    NSDictionary *details = NivoMapsErrorDetails(error);
    maps_require([details[@"code"] isEqualToString:@"ambiguous_location"], @"歧义必须有独立错误码");
    maps_require([details[@"candidates"] count] == 2, @"候选供用户选择");
    maps_require(NivoMapsSelectEndpoint(@[first], @"from", &error) == first, @"唯一候选可用");
    NSError *provider = [NSError errorWithDomain:@"MKErrorDomain" code:5 userInfo:@{NSLocalizedDescriptionKey: @"Directions unavailable"}];
    details = NivoMapsErrorDetails(provider);
    maps_require([details[@"domain"] isEqualToString:@"MKErrorDomain"] && [details[@"provider_code"] integerValue] == 5,
        @"保留MapKit错误域与数字码");
    maps_require(details[@"distance_km"] == nil, @"错误不能返回猜测距离");
    details = NivoMapsErrorDetails(NivoMapsErrorAtStage(provider, @"route"));
    maps_require([details[@"stage"] isEqualToString:@"route"] && [details[@"provider_code"] integerValue] == 5,
        @"添加阶段不能丢原厂错误码");
    maps_require([NSJSONSerialization isValidJSONObject:details], @"错误可被标准JSON编码");
    maps_require(NivoMapsSelectEndpoint(@[], @"to", &error) == nil && error.code == NivoMapsErrorNoLocation,
        @"无候选不能返回空成功");
}

/// 回调迟到、重复完成和超时后的取消注册都只能交付一次。
static void testAsyncBoundary(void) {
    NivoMapsAsyncResult *done = [[NivoMapsAsyncResult alloc] init];
    [done finish:@{@"distance_km": @2} error:nil];
    maps_require([done wait:0 stage:@"route"], @"已完成结果不能超时");
    [done finish:@{@"distance_km": @99} error:nil];
    maps_require([done.data[@"distance_km"] integerValue] == 2, @"重复回调不能改结果");
    NivoMapsAsyncResult *late = [[NivoMapsAsyncResult alloc] init];
    maps_require(![late wait:0 stage:@"geocode_from"], @"未完成结果必须超时");
    [late finish:@{@"distance_km": @99} error:nil];
    maps_require(late.data == nil && late.error.code == NivoMapsErrorTimeout, @"晚到成功不能替换超时");
    __block BOOL cancelledOnMain = NO;
    [late setCancellation:^{ cancelledOnMain = NSThread.isMainThread; }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1];
    while (!cancelledOnMain && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    maps_require(cancelledOnMain, @"超时后的取消仍在主线程执行");
    maps_require(![late wait:0 stage:@"route"], @"重复等待不能复活已超时结果");
    NivoMapsAsyncResult *registered = [[NivoMapsAsyncResult alloc] init];
    __block BOOL cancelledBeforeWait = NO;
    [registered setCancellation:^{ cancelledBeforeWait = NSThread.isMainThread; }];
    maps_require(![registered wait:0 stage:@"search"], @"注册取消之后仍可确定性超时");
    deadline = [NSDate dateWithTimeIntervalSinceNow:1];
    while (!cancelledBeforeWait && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    maps_require(cancelledBeforeWait, @"先注册的取消同样回到主线程");
}

/// 多个回调竞争时结果不可被覆盖，超时与成功互斥且无需真实服务。
static void testConcurrentCompletion(void) {
    for (NSInteger iteration = 0; iteration < 100; iteration++) {
        NivoMapsAsyncResult *result = [[NivoMapsAsyncResult alloc] init];
        dispatch_group_t callbacks = dispatch_group_create();
        for (NSInteger value = 0; value < 8; value++) {
            dispatch_group_async(callbacks, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                [result finish:@{@"value": @(value)} error:nil];
            });
        }
        [result wait:0 stage:@"route"];
        NSDictionary *delivered = result.data;
        NSError *deliveredError = result.error;
        maps_require(dispatch_group_wait(callbacks, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0,
            @"所有注入回调必须退出");
        maps_require(result.data == delivered && result.error == deliveredError, @"交付后并发写不能改变结果");
        maps_require((delivered != nil) != (deliveredError != nil), @"只能有成功或失败之一");
    }
}

/// 从真实argv入口验证先解析后网络、全局输出选项和主线程拒绝边界。
static void testCommandEntry(void) {
    char *invalidMode[] = {"apple-maps", "route", "--from", "Example address", "--to", "1,2", "--mode", "fly"};
    maps_require(maps_handler(8, invalidMode, -1, -1, -1) == NOFF_EXIT_INVALID_ARGS,
        @"未知模式在主线程门禁或网络之前拒绝");
    maps_require([capturedOutput[@"error"][@"code"] isEqualToString:@"invalid_args"], @"真实入口有结构化错误");
    char *invalidTarget[] = {"apple-maps", "--compact", "route", "--from", "Example address", "--to", "NaN,2", "--quiet"};
    maps_require(maps_handler(8, invalidTarget, -1, -1, -1) == NOFF_EXIT_INVALID_ARGS,
        @"非法终点不得触发地名起点的解析");
    maps_require(capturedCompact && capturedQuiet && [capturedOutput[@"error"][@"endpoint"] isEqualToString:@"to"],
        @"全局标志不吞掉子命令，终点错误保留归属");
    char *valid[] = {"apple-maps", "route", "--from", "1,2", "--to", "3,4", "--mode", "cycling"};
    maps_require(maps_handler(8, valid, -1, -1, -1) == NOFF_EXIT_ERROR &&
        [capturedOutput[@"error"][@"code"] isEqualToString:@"wrong_thread"], @"有效请求不能阻塞UI线程");
    maps_require([NSJSONSerialization isValidJSONObject:capturedOutput], @"真实入口错误可序列化");
}

/// 注入异常供应商坐标和距离，验证生产搜索输出规则在序列化前拒绝它们。
static void testSearchResultNumbers(void) {
    CLLocationCoordinate2D valid = CLLocationCoordinate2DMake(-30, -120);
    CLLocationCoordinate2D invalid[] = {
        {NAN, 1}, {1, NAN}, {INFINITY, 1}, {1, INFINITY}, {-INFINITY, 1}, {1, -INFINITY},
        {91, 1}, {-91, 1}, {1, 181}, {1, -181},
    };
    for (NSUInteger index = 0; index < sizeof(invalid) / sizeof(invalid[0]); index++) {
        maps_require(!maps_search_coordinate_is_valid(invalid[index]), @"异常坐标不能创建搜索结果位置对象");
        maps_require(maps_search_measurements(invalid[index], 10) == nil, @"异常坐标不能进入JSON");
    }
    double invalidDistances[] = {NAN, INFINITY, -INFINITY, -1};
    for (NSUInteger index = 0; index < sizeof(invalidDistances) / sizeof(invalidDistances[0]); index++) {
        maps_require(maps_search_measurements(valid, invalidDistances[index]) == nil, @"异常搜索距离不能补零或通过");
    }
    NSDictionary *zero = maps_search_measurements(valid, 0);
    maps_require([zero[@"lat"] doubleValue] == -30 && [zero[@"lon"] doubleValue] == -120 &&
        [zero[@"distance_m"] doubleValue] == 0, @"合法负经纬度和零距离保留原义");
    NSDictionary *rounded = maps_search_measurements(valid, 12.6);
    maps_require([rounded[@"distance_m"] doubleValue] == 13 && [NSJSONSerialization isValidJSONObject:rounded],
        @"正常搜索距离仍按整米输出且可序列化");
    maps_require(emit_maps_error(@"search", maps_invalid_search_result(), -1, NO, NO) == NOFF_EXIT_ERROR,
        @"供应商异常搜索结果必须返回失败退出码");
    maps_require([capturedOutput[@"error"][@"stage"] isEqualToString:@"search_result"] &&
        [NSJSONSerialization isValidJSONObject:capturedOutput], @"搜索异常有可序列化的具体阶段");
}

/// 每条步骤独立拒绝非有限和负距离，合法零距离与原有整米精度继续可用。
static void testRouteStepNumbers(void) {
    double invalidDistances[] = {NAN, INFINITY, -INFINITY, -1};
    for (NSUInteger index = 0; index < sizeof(invalidDistances) / sizeof(invalidDistances[0]); index++) {
        maps_require(maps_route_step(@"Turn", invalidDistances[index]) == nil, @"异常步骤距离不能被序列化或替换成零");
    }
    NSDictionary *zero = maps_route_step(@"Arrive", 0);
    NSDictionary *rounded = maps_route_step(@"Continue", 12.6);
    maps_require(zero != nil && [zero[@"distance_m"] doubleValue] == 0, @"合法零距离步骤保留");
    maps_require([rounded[@"distance_m"] doubleValue] == 13 && [NSJSONSerialization isValidJSONObject:rounded],
        @"正常步骤仍按整米输出且可序列化");
}

/// 保留Apple原始跨度探针，生产helper必须把全球尺度和极区规范成合法范围；不启动网络。
static void testSearchRegionBounds(void) {
    double latitudes[] = {0, 85, 89.99999, 90, -90};
    double radii[] = {1000, 20000000};
    NSUInteger failures = 0;
    for (NSUInteger latitudeIndex = 0; latitudeIndex < sizeof(latitudes) / sizeof(latitudes[0]); latitudeIndex++) {
        for (NSUInteger radiusIndex = 0; radiusIndex < sizeof(radii) / sizeof(radii[0]); radiusIndex++) {
            double latitude = latitudes[latitudeIndex];
            double radius = radii[radiusIndex];
            @try {
                CLLocationCoordinate2D center = CLLocationCoordinate2DMake(latitude, 0);
                MKCoordinateRegion raw = MKCoordinateRegionMakeWithDistance(center, radius * 2, radius * 2);
                printf("Maps raw region probe lat=%.5f radius=%.0f center=%.8f,%.8f span=%.8f,%.8f\n",
                    latitude, radius, raw.center.latitude, raw.center.longitude, raw.span.latitudeDelta, raw.span.longitudeDelta);
                MKCoordinateRegion region;
                NSError *error = nil;
                if (!maps_search_region(center, radius, &region, &error)) {
                    NSLog(@"Maps normalized region failed lat=%.5f radius=%.0f error=%@", latitude, radius, error);
                    failures++;
                    continue;
                }
                MKLocalSearchRequest *request = [[MKLocalSearchRequest alloc] init];
                request.region = region;
                MKCoordinateRegion assigned = request.region;
                double south = assigned.center.latitude - assigned.span.latitudeDelta / 2.0;
                double north = assigned.center.latitude + assigned.span.latitudeDelta / 2.0;
                BOOL valid = CLLocationCoordinate2DIsValid(assigned.center) &&
                    isfinite(assigned.span.latitudeDelta) && assigned.span.latitudeDelta > 0 && assigned.span.latitudeDelta <= 180 &&
                    isfinite(assigned.span.longitudeDelta) && assigned.span.longitudeDelta > 0 && assigned.span.longitudeDelta <= 360 &&
                    south >= -90.000000001 && north <= 90.000000001 && latitude >= south - 1e-9 && latitude <= north + 1e-9;
                printf("Maps normalized region probe lat=%.5f radius=%.0f center=%.8f,%.8f span=%.8f,%.8f valid=%s\n",
                    latitude, radius, assigned.center.latitude, assigned.center.longitude,
                    assigned.span.latitudeDelta, assigned.span.longitudeDelta, valid ? "yes" : "no");
                if (!valid) failures++;
                maps_require(assigned.span.latitudeDelta == MIN(raw.span.latitudeDelta, 180.0) &&
                    assigned.span.longitudeDelta == MIN(raw.span.longitudeDelta, 360.0), @"不能随意缩小合法跨度或另设半径上限");
                BOOL rawInBounds = raw.span.latitudeDelta <= 180 && raw.span.longitudeDelta <= 360 &&
                    raw.center.latitude - raw.span.latitudeDelta / 2.0 >= -90 &&
                    raw.center.latitude + raw.span.latitudeDelta / 2.0 <= 90;
                if (rawInBounds) {
                    maps_require(assigned.center.latitude == raw.center.latitude && assigned.center.longitude == raw.center.longitude,
                        @"原始合法区域中心必须原样保留");
                }
            } @catch (NSException *exception) {
                NSLog(@"Maps region probe lat=%.5f radius=%.0f exception=%@ reason=%@",
                    latitude, radius, exception.name, exception.reason);
                failures++;
            }
        }
    }
    maps_require(failures == 0, @"生产区域构造或赋值必须有限合法且覆盖原始查询中心");
}

/// macOS命令行入口仅执行注入数据，不触发定位权限或真实网络。
int main(void) {
    @autoreleasepool {
        testArguments();
        testResolutionAndErrors();
        testAsyncBoundary();
        testConcurrentCompletion();
        testCommandEntry();
        testSearchResultNumbers();
        testRouteStepNumbers();
        testSearchRegionBounds();
        puts("Nivo Maps protocol checks passed");
    }
    return 0;
}
