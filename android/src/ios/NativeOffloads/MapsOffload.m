//
//  MapsOffload.m
//  MinisApp
//
//  Native offload handler for `apple-maps`.
//  Subcommands: search, route, eta
//

#import <Foundation/Foundation.h>
#import <MapKit/MapKit.h>
#import <CoreLocation/CoreLocation.h>
// nanoMuse:此桥接只依赖地图框架，允许macOS执行不联网的真实命令入口回归。
#import "NativeOffloadUtils.h"
#import "CoordinateUtils.h"
// nanoMuse:共享严格参数规则与一次性交付，离线回归用例验证同一实现。
#import "../NanoMuse/NivoMapsRequest.h"
#import "../NanoMuse/NivoMapsTransport.h"
#include "kernel/native_offload.h"
#include <math.h>
#include <unistd.h>

static NSString *const TOOL_NAME = @"apple-maps";

static NSString *const HELP_TEXT =
    @"apple-maps - Search places, get directions, and estimate travel times\n"
     "\n"
     "USAGE:\n"
     "  apple-maps <command> [options]\n"
     "\n"
     "COMMANDS:\n"
     "  search      Search for places and points of interest\n"
     "  route       Get directions between two points\n"
     "  eta         Get estimated travel time (lightweight)\n"
     "\n"
     "COMMON OPTIONS:\n"
     "  --help, -h           Show this help message\n"
     "  --compact            Minimize JSON output\n"
     "  -q, --quiet          Output only data field\n"
     "\n"
     "SEARCH OPTIONS:\n"
     "  --query <text>       Search query (required)\n"
     "  --lat <degrees>      Center latitude (required)\n"
     "  --lon <degrees>      Center longitude (required)\n"
     "  --radius <m>         Search radius (0,20000000] meters (default 1000)\n"
     "  --limit <N>          Maximum results 1..100 (default 10)\n"
     "\n"
     "ROUTE / ETA OPTIONS:\n"
     "  --from <addr|lat,lon>  Origin (required)\n"
     "  --to <addr|lat,lon>    Destination (required)\n"
     // nanoMuse:骑行使用真实MapKit骑行模式，错误或不支持不会改用驾车。
     "  --mode <mode>          Transport: driving, walking, transit, cycling (default driving)\n"
     "  Ambiguous addresses return candidates. Retry with the chosen lat,lon.\n"
     "\n"
     "EXAMPLES:\n"
     "  apple-maps search --query \"coffee shops\" --lat 37.7749 --lon -122.4194\n"
     "  apple-maps search --query \"gas station\" --lat 37.7749 --lon -122.4194 --radius 500 --limit 5\n"
     "  apple-maps route --from \"San Francisco\" --to \"Los Angeles\" --mode driving\n"
     "  apple-maps route --from 37.7749,-122.4194 --to 34.0522,-118.2437\n"
     "  apple-maps eta --from \"New York\" --to \"Boston\" --mode transit\n";

// ── Helpers ──

// nanoMuse:错误结构保留上游域、代码和执行阶段，帮助区分输入、地名解析与路径服务失败。
static int emit_maps_error(NSString *command, NSError *error, int stdout_fd, BOOL compact, BOOL quiet) {
    NSDictionary *details = NivoMapsErrorDetails(error);
    NSMutableDictionary *envelope = [noff_json_error(TOOL_NAME, command,
        details[@"code"], details[@"message"]) mutableCopy];
    envelope[@"error"] = details;
    noff_emit_json(stdout_fd, envelope, compact, quiet);
    return [error.domain isEqualToString:NivoMapsErrorDomain] && error.code == NivoMapsErrorInvalidArguments
        ? NOFF_EXIT_INVALID_ARGS : NOFF_EXIT_ERROR;
}

/// 在原生对象所在的主线程提取地址，返回的字典可跨线程读取。
static NSString *maps_address(CLPlacemark *place) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *part in @[place.subThoroughfare ?: @"", place.thoroughfare ?: @"", place.locality ?: @"",
                            place.administrativeArea ?: @"", place.postalCode ?: @"", place.country ?: @""]) {
        if (part.length > 0) [parts addObject:part];
    }
    return [parts componentsJoinedByString:@", "];
}

/// 原始精度不存在时输出null，不把输入小数位或地名解析当作精确位置证据。
static NSDictionary *maps_candidate(CLPlacemark *place, NSString *input) {
    CLLocation *location = place.location;
    if (location == nil || !CLLocationCoordinate2DIsValid(location.coordinate)) return nil;
    double accuracy = location.horizontalAccuracy;
    return @{@"input": input, @"name": place.name ?: input, @"address": maps_address(place),
             @"lat": @(location.coordinate.latitude), @"lon": @(location.coordinate.longitude),
             @"source": @"geocoded", @"accuracy_m": isfinite(accuracy) && accuracy >= 0 ? @(accuracy) : NSNull.null};
}

// nanoMuse:地理编码的创建、启动和取消均在主线程；不再无声选取第一个候选。
static NSDictionary *resolve_endpoint(NSDictionary *endpoint, NSString *name, NSError **outError) {
    if (endpoint[@"lat"]) return endpoint;
    NivoMapsAsyncResult *result = [[NivoMapsAsyncResult alloc] init];
    NSString *stage = [@"geocode_" stringByAppendingString:name];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (result.isFinished) return;
        CLGeocoder *geocoder = [[CLGeocoder alloc] init];
        [result setCancellation:^{ [geocoder cancelGeocode]; }];
        [geocoder geocodeAddressString:endpoint[@"input"] completionHandler:^(NSArray<CLPlacemark *> *places, NSError *error) {
            if (result.isFinished) return;
            if (error) { [result finish:nil error:NivoMapsErrorAtStage(error, stage)]; return; }
            NSMutableArray *candidates = [NSMutableArray array];
            for (CLPlacemark *place in places) {
                NSDictionary *candidate = maps_candidate(place, endpoint[@"input"]);
                if (candidate) [candidates addObject:candidate];
            }
            NSError *resolutionError = nil;
            NSDictionary *selected = NivoMapsSelectEndpoint(candidates, name, &resolutionError);
            [result finish:selected error:resolutionError ? NivoMapsErrorAtStage(resolutionError, stage) : nil];
        }];
    });
    [result wait:15 stage:stage];
    if (outError) *outError = result.error;
    return result.data;
}

// ── Subcommands ──

// nanoMuse:只接收完整验证后的请求，超时后取消实际服务且封闭结果写入。
static int cmd_search(NivoMapsRequest *input, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *query = input.query;
    double radiusM = input.radiusMeters;
    NSInteger limit = input.limit;
    CLLocationCoordinate2D center = CLLocationCoordinate2DMake(input.latitude, input.longitude);
    NivoMapsAsyncResult *result = [[NivoMapsAsyncResult alloc] init];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (result.isFinished) return;
        MKLocalSearchRequest *request = [[MKLocalSearchRequest alloc] init];
        request.naturalLanguageQuery = query;

        MKCoordinateRegion region = MKCoordinateRegionMakeWithDistance(center,
                                                                       radiusM * 2,
                                                                       radiusM * 2);
        request.region = region;

        MKLocalSearch *search = [[MKLocalSearch alloc] initWithRequest:request];
        [result setCancellation:^{ [search cancel]; }];
        [search startWithCompletionHandler:^(MKLocalSearchResponse *response, NSError *error) {
            if (result.isFinished) return;
            if (error || !response) {
                [result finish:nil error:NivoMapsErrorAtStage(error ?: NivoMapsMakeError(
                    NivoMapsErrorNoData, @"Search returned no results.", @{}), @"search")];
                return;
            }

            NSArray<MKMapItem *> *items = response.mapItems;
            if ((NSInteger)items.count > limit) {
                items = [items subarrayWithRange:NSMakeRange(0, limit)];
            }

            CLLocation *centerLoc = [[CLLocation alloc] initWithLatitude:center.latitude
                                                                       longitude:center.longitude];

            NSMutableArray *results = [NSMutableArray array];
            for (MKMapItem *item in items) {
                NSMutableDictionary *d = [NSMutableDictionary dictionary];
                d[@"name"] = item.name ?: @"";

                // nanoMuse:共用地址字段提取，不对既有坐标体系作猜测性改写。
                d[@"address"] = maps_address(item.placemark);

                d[@"lat"] = @(item.placemark.coordinate.latitude);
                d[@"lon"] = @(item.placemark.coordinate.longitude);
                if (!gcj_isOutOfChina(center.latitude, center.longitude)) {
                    d[@"coordinate_system"] = @"GCJ-02";
                }
                d[@"phone"] = item.phoneNumber ?: [NSNull null];
                d[@"url"] = item.url.absoluteString ?: [NSNull null];

                if (@available(iOS 13.0, *)) {
                    d[@"category"] = item.pointOfInterestCategory ?: [NSNull null];
                } else {
                    d[@"category"] = [NSNull null];
                }

                CLLocation *itemLoc = [[CLLocation alloc]
                    initWithLatitude:item.placemark.coordinate.latitude
                           longitude:item.placemark.coordinate.longitude];
                double distM = [centerLoc distanceFromLocation:itemLoc];
                d[@"distance_m"] = @((int)round(distM));

                [results addObject:d];
            }

            [result finish:@{
                @"results": results,
                @"count": @(results.count),
                @"query": query,
            } error:nil];
        }];
    });
    [result wait:20 stage:@"search"];

    if (result.error) return emit_maps_error(@"search", result.error, stdout_fd, compact, quiet);
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"search", result.data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

// nanoMuse:路线和ETA共用两端解析、真实交通方式、主线程启动与超时状态。
static MKDirections *maps_directions(NivoMapsRequest *input, NSDictionary *from, NSDictionary *to) {
    MKDirectionsRequest *request = [[MKDirectionsRequest alloc] init];
    CLLocationCoordinate2D origin = CLLocationCoordinate2DMake([from[@"lat"] doubleValue], [from[@"lon"] doubleValue]);
    CLLocationCoordinate2D destination = CLLocationCoordinate2DMake([to[@"lat"] doubleValue], [to[@"lon"] doubleValue]);
    request.source = [[MKMapItem alloc] initWithPlacemark:[[MKPlacemark alloc] initWithCoordinate:origin]];
    request.destination = [[MKMapItem alloc] initWithPlacemark:[[MKPlacemark alloc] initWithCoordinate:destination]];
    request.transportType = NivoMapsTransportType(input.mode);
    request.requestsAlternateRoutes = NO;
    return [[MKDirections alloc] initWithRequest:request];
}

/// 供应商没有有效距离和时间时返回失败，不补直线距离或固定默认距离。
static NSDictionary *maps_measurements(double distance, double duration) {
    if (!isfinite(distance) || distance < 0 || !isfinite(duration) || duration < 0) return nil;
    return @{@"distance_km": @(round(distance / 10.0) / 100.0),
             @"duration_minutes": @(round(duration / 6.0) / 10.0)};
}

/// 只提取供应商提供的路线信息，所有原生对象留在主线程回调内。
static void maps_route_result(MKDirections *directions, NivoMapsAsyncResult *result) {
    [directions calculateDirectionsWithCompletionHandler:^(MKDirectionsResponse *response, NSError *error) {
        if (result.isFinished) return;
        MKRoute *route = response.routes.firstObject;
        NSDictionary *measurements = route ? maps_measurements(route.distance, route.expectedTravelTime) : nil;
        if (error || measurements == nil) {
            [result finish:nil error:NivoMapsErrorAtStage(error ?: NivoMapsMakeError(
                NivoMapsErrorNoData, @"No valid route found.", @{}), @"route")];
            return;
        }
        NSMutableArray *steps = [NSMutableArray array];
        for (MKRouteStep *step in route.steps) {
            if (step.instructions.length == 0) continue;
            [steps addObject:@{@"instruction": step.instructions, @"distance_m": @(round(step.distance))}];
        }
        NSMutableDictionary *data = [measurements mutableCopy];
        data[@"steps"] = steps;
        data[@"polyline_point_count"] = @(route.polyline.pointCount);
        [result finish:data error:nil];
    }];
}

/// ETA采用MapKit原生估计，无法提供骑行或其他方式时保留服务错误。
static void maps_eta_result(MKDirections *directions, NivoMapsAsyncResult *result) {
    [directions calculateETAWithCompletionHandler:^(MKETAResponse *response, NSError *error) {
        if (result.isFinished) return;
        NSDictionary *measurements = response ? maps_measurements(response.distance, response.expectedTravelTime) : nil;
        if (error || measurements == nil || response.expectedArrivalDate == nil) {
            [result finish:nil error:NivoMapsErrorAtStage(error ?: NivoMapsMakeError(
                NivoMapsErrorNoData, @"No valid ETA found.", @{}), @"eta")];
            return;
        }
        NSMutableDictionary *data = [measurements mutableCopy];
        data[@"expected_arrival"] = noff_format_date(response.expectedArrivalDate);
        [result finish:data error:nil];
    }];
}

/// 返回解析后的两端和请求模式，允许调用方核对是否选中了预期地点。
static int cmd_directions(NivoMapsRequest *input, int stdout_fd, BOOL compact, BOOL quiet) {
    NSError *error = nil;
    NSDictionary *from = resolve_endpoint(input.fromEndpoint, @"from", &error);
    if (error) return emit_maps_error(input.command, error, stdout_fd, compact, quiet);
    NSDictionary *to = resolve_endpoint(input.toEndpoint, @"to", &error);
    if (error) return emit_maps_error(input.command, error, stdout_fd, compact, quiet);
    NivoMapsAsyncResult *result = [[NivoMapsAsyncResult alloc] init];
    BOOL isRoute = [input.command isEqualToString:@"route"];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (result.isFinished) return;
        MKDirections *directions = maps_directions(input, from, to);
        [result setCancellation:^{ [directions cancel]; }];
        if (isRoute) maps_route_result(directions, result);
        else maps_eta_result(directions, result);
    });
    [result wait:isRoute ? 35 : 20 stage:input.command];
    if (result.error) return emit_maps_error(input.command, result.error, stdout_fd, compact, quiet);
    NSMutableDictionary *data = [result.data mutableCopy];
    data[@"mode"] = input.modeName;
    data[@"from"] = from;
    data[@"to"] = to;
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, input.command, data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

// ── Main handler ──

static int maps_handler(int argc, char **argv,
                         int stdin_fd, int stdout_fd, int stderr_fd) {
    (void)stdin_fd;
    if (noff_has_flag(argc, argv, "--help") || noff_has_flag(argc, argv, "-h")) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        return NOFF_EXIT_SUCCESS;
    }

    BOOL compact = noff_has_flag(argc, argv, "--compact");
    BOOL quiet = noff_has_flag(argc, argv, "-q") || noff_has_flag(argc, argv, "--quiet");

    // nanoMuse:先收集全部选项再校验，避免未验证的终点或模式先触发起点网络解析。
    NSString *subcmd = nil;
    NSMutableArray *arguments = [NSMutableArray array];
    for (int index = 1; index < argc; index++) {
        NSString *argument = [NSString stringWithUTF8String:argv[index]];
        if (argument == nil) {
            return emit_maps_error(subcmd ?: @"unknown", NivoMapsMakeError(NivoMapsErrorInvalidArguments,
                @"Arguments must be UTF-8 text.", @{}), stdout_fd, compact, quiet);
        }
        BOOL isOutputFlag = [@[@"--compact", @"--quiet", @"-q"] containsObject:argument];
        if (subcmd == nil && !isOutputFlag) subcmd = argument;
        else [arguments addObject:argument];
    }
    if (!subcmd) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, @"unknown",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"No command specified. Use --help for usage.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    NSError *error = nil;
    NivoMapsRequest *input = [NivoMapsRequest parse:subcmd arguments:arguments error:&error];
    if (input == nil) return emit_maps_error(subcmd, error, stdout_fd, compact, quiet);
    // nanoMuse:同步CLI入口不能占用主线程等待主队列，否则造成自锁。
    if (NSThread.isMainThread) {
        return emit_maps_error(subcmd, NivoMapsMakeError(NivoMapsErrorWrongThread,
            @"Run maps commands from the conversation shell.", @{}), stdout_fd, compact, quiet);
    }
    if ([subcmd isEqualToString:@"search"]) return cmd_search(input, stdout_fd, compact, quiet);
    return cmd_directions(input, stdout_fd, compact, quiet);
}

// ── Registration ──

void maps_offload_register(void) {
    int err = native_offload_add_handler("apple-maps", maps_handler);
    if (err == 0) {
        noff_ensure_guest_stub("/usr/local/bin/apple-maps");
        NSLog(@"NativeOffloads: apple-maps handler registered");
    } else {
        NSLog(@"NativeOffloads: failed to register apple-maps handler (err=%d)", err);
    }
}
