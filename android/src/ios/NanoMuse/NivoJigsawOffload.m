#import <Foundation/Foundation.h>
#import "NativeOffloadUtils.h"
#import "Minis-Swift.h"
#include "kernel/native_offload.h"
#include "kernel/task.h"
#include <errno.h>
#include <string.h>
#include <unistd.h>

/// 原生命令只写标准输出，不把生活记录写进日志或客体文件。
static void nivo_jigsaw_write(int descriptor, NSString *text) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *bytes = data.bytes;
    NSUInteger remaining = data.length;
    while (remaining > 0) {
        ssize_t written = write(descriptor, bytes, remaining);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return;
        bytes += written;
        remaining -= written;
    }
}

/// 实际分发点核对权限，不能通过sh、env或绝对路径绕过调用入口。
static int nivo_jigsaw_handler(int argc, char **argv, int stdin_fd, int stdout_fd, int stderr_fd) {
    (void)stdin_fd;
    (void)stderr_fd;
    if (argc < 2 || noff_has_flag(argc, argv, "--help") || noff_has_flag(argc, argv, "-h") ||
        (argc == 2 && strcmp(argv[1], "help") == 0)) {
        nivo_jigsaw_write(stdout_fd, @"minis-jigsaw-cli: read-only life fragments\n"
            "  list|export [--start YYYY-MM-DD] [--end YYYY-MM-DD] [--days 7] [--limit 31] [--offset 0] [--format json|md]\n"
            "  get --date YYYY-MM-DD [--format json|md]\n"
            "  stats [--start YYYY-MM-DD] [--end YYYY-MM-DD] [--days 7] [--format json|md]\n"
            "Ranges are inclusive, at most 366 days. Default timezone: Asia/Shanghai.\n"
            "Follow next_offset until null. No photo contents, file paths, writes or network access.\n");
        return 0;
    }
    if ([NSThread isMainThread]) {
        nivo_jigsaw_write(stdout_fd, @"{\"error\":\"Run this command from a conversation shell.\"}\n");
        return 1;
    }
    NSMutableArray<NSString *> *arguments = [NSMutableArray array];
    for (int index = 1; index < argc; index++) {
        NSString *argument = [NSString stringWithUTF8String:argv[index]];
        if (argument == nil || arguments.count >= 32 || argument.length > 1024) {
            nivo_jigsaw_write(stdout_fd, @"{\"error\":\"Invalid or oversized arguments.\"}\n");
            return 2;
        }
        [arguments addObject:argument];
    }
    uint64_t context = current && current->group ? current->group->fs_context : 0;
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    __block NSString *output = nil;
    __block int32_t exitCode = 1;
    [NivoJigsawOffloadBridge executeWithArguments:arguments context:context completion:^(NSString *text, int32_t code) {
        output = text;
        exitCode = code;
        dispatch_semaphore_signal(completed);
    }];
    if (dispatch_semaphore_wait(completed, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)) != 0) {
        nivo_jigsaw_write(stdout_fd, @"{\"error\":\"The life log query timed out. Use a smaller range and retry.\"}\n");
        return 1;
    }
    nivo_jigsaw_write(stdout_fd, output);
    return exitCode;
}

/// 与其他原生命令一起注册，桩文件只帮助shell解析PATH。
void nivo_jigsaw_offload_register(void) {
    if (native_offload_add_handler("minis-jigsaw-cli", nivo_jigsaw_handler) == 0) {
        noff_ensure_guest_stub("/usr/local/bin/minis-jigsaw-cli");
    }
}
