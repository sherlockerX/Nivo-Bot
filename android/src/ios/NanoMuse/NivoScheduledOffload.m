#import <Foundation/Foundation.h>
#import "NativeOffloadUtils.h"
#import "Minis-Swift.h"
#include "kernel/native_offload.h"
#include "kernel/task.h"
#include <errno.h>
#include <unistd.h>

/// 标准输出保持JSON，不将任务内容写到全局日志。
static void nivo_scheduled_write(int descriptor, NSString *text) {
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

/// 权限等待有上限，超时后的Swift调用会在写入前检查同一截止时间。
static int nivo_scheduled_handler(int argc, char **argv, int stdin_fd, int stdout_fd, int stderr_fd) {
    (void)stdin_fd;
    (void)stderr_fd;
    if (noff_has_flag(argc, argv, "--help") || noff_has_flag(argc, argv, "-h")) {
        nivo_scheduled_write(stdout_fd, @"minis-scheduled list\n"
            "create --label NAME --time HH:MM [--time HH:MM] --prompt TEXT [--repeat once|daily|weekdays|custom] [--days mon,tue]\n"
            "  [--target new|follow-up|rerun] [--session ID] [--message ID] [--model ID|--model-group ID] [--start YYYY-MM-DD] [--end YYYY-MM-DD]\n"
            "  [--disabled] [--auto-disable-on-failure] [--failure-threshold 5]\n"
            "  [--notify always|on_change|on_failure|never] [--notify-title TITLE] [--silent=true|false]\n"
            "Script tasks replace --prompt with --script NAME.sh|NAME.py. Scripts live in /var/minis/home/bin.\n"
            "  [--script-arg VALUE] (repeatable, max 16) [--require-output] [--log-stdout] [--debug]\n"
            "Scripts use literal arguments and require approval of the frozen script content before execution.\n"
            "update|delete|enable|disable|run --id ID --expected-revision REVISION\n"
            "run also accepts --dry-notify, which records the result without sending a notification.\n"
            "logs --id ID [--last 20] [--since YYYY-MM-DD|ISO8601] [--format json|text]\n"
            "settings [--quiet-hours HH:MM-HH:MM|off]\n"
            "probe --id ID\n"
            "report [--status success|failure [--reason TEXT]] [--result TEXT]\n"
            "Report is only available inside the host's current task execution. Script reports print no receipt.\n"
            "Each task reuses a dedicated conversation. --session-output is accepted for compatibility and changes nothing.\n"
            "Debug runs send no result notification or failure count; a new script target creates no conversation.\n"
            "iOS starts tasks while the app is open. Run returns queued; query logs for the actual outcome, exit code and verified status.\n");
        return 0;
    }
    if ([NSThread isMainThread]) return 1;
    NSMutableArray<NSString *> *arguments = [NSMutableArray array];
    NSUInteger totalBytes = 0;
    for (int index = 1; index < argc; index++) {
        NSString *value = [NSString stringWithUTF8String:argv[index]];
        totalBytes += [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        if (value == nil || arguments.count >= 100 || totalBytes > 120000) return 2;
        [arguments addObject:value];
    }
    uint64_t context = current && current->group ? current->group->fs_context : 0;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSString *output = nil;
    __block int32_t exitCode = 1;
    [NivoScheduledOffloadBridge executeWithArguments:arguments context:context completion:^(NSString *text, int32_t code) {
        output = text;
        exitCode = code;
        dispatch_semaphore_signal(semaphore);
    }];
    if (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC)) != 0) {
        nivo_scheduled_write(stdout_fd, @"{\"success\":false,\"error\":\"Scheduled command timed out. Query the task before retrying.\"}\n");
        return 1;
    }
    nivo_scheduled_write(stdout_fd, output);
    return exitCode;
}

/// 通过内核原生分发注册，绝对路径与shell包装都不能跳过权限检查。
void nivo_scheduled_offload_register(void) {
    if (native_offload_add_handler("minis-scheduled", nivo_scheduled_handler) == 0) {
        noff_ensure_guest_stub("/usr/local/bin/minis-scheduled");
    }
}
