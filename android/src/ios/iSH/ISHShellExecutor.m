//
//  ISHShellExecutor.m
//  MinisApp
//
//  Shell execution implementation with line-by-line output and process completion
//

#import "ISHShellExecutor.h"
#import "ISHKernel.h"
// nanoMuse: UTF-8边界处理与字节捕获供普通命令和定时脚本共用。
#include "../NanoMuse/NivoShellBytes.h"

#include <poll.h>
#include <libkern/OSAtomic.h>
#include "ish/kernel/init.h"
#include "ish/kernel/calls.h"
#include "ish/kernel/task.h"
#include "ish/kernel/signal.h"
#include "ish/kernel/fs.h"
#include "ish/kernel/mm.h"
#include "ish/fs/devices.h"
#include "ish/fs/real.h"

#pragma mark - Leak Guard Tunables

/// Hard cap on how long a single reader thread may live.
///
/// Not a command timeout — callers set their own, and this is far above any of
/// them. It only bounds the damage from a reader that never observed the
/// signal to stop, so a stranded thread cannot hold a concurrent-queue slot
/// for the life of the process.
static const NSTimeInterval ISHShellExecutorReaderMaxLifetime = 3600.0; // 1h

/// How often the stale-context sweeper runs.
static const NSTimeInterval ISHShellExecutorSweepInterval = 60.0;

/// How long past its last sign of life a context may sit in _activeExecutions
/// before the sweeper reclaims it. Must comfortably exceed the longest command
/// anyone runs, because the sweeper cannot distinguish "still working" from
/// "stranded" — it only sees an entry that has been there a long time.
static const NSTimeInterval ISHShellExecutorStaleContextAge = 7200.0; // 2h

#pragma mark - Result Implementation

@interface ISHShellExecutionResult ()
@property (nonatomic, readwrite) int exitCode;
@property (nonatomic, readwrite) int pid;
@property (nonatomic, readwrite) ISHShellExecutorError error;
@property (nonatomic, readwrite, copy) NSString *output;
@property (nonatomic, readwrite, copy) NSString *errorOutput;
@property (nonatomic, readwrite) NSTimeInterval duration;
// nanoMuse: 读取计数和完整性信息随真实进程结果返回。
@property (nonatomic, readwrite) uint64_t stdoutBytes;
@property (nonatomic, readwrite) uint64_t errorOutputBytes;
@property (nonatomic, readwrite) BOOL outputTruncated;
@property (nonatomic, readwrite) BOOL errorOutputTruncated;
@property (nonatomic, readwrite, copy, nullable) NSString *captureError;
@end

@implementation ISHShellExecutionResult
// nanoMuse: 启动失败也提供非nil文本，Swift调用方无需猜测未初始化字段。
- (instancetype)init {
    self = [super init];
    if (self) { _output = @""; _errorOutput = @""; _exitCode = -1; }
    return self;
}
@end

#pragma mark - Execution Context

@interface ISHShellExecutionContext : NSObject {
    int _stdoutPipe[2];
    int _stderrPipe[2];
    /// Reader count. A plain int32 driven by OSAtomic rather than an `atomic`
    /// property: `self.liveReaders--` on an atomic property is still a
    /// read-modify-write with a gap between the load and the store, so two
    /// readers finishing at once can both read N and both store N-1. Losing a
    /// decrement leaves the count permanently above zero and the pipes never
    /// close; losing it the other way closes them while a reader still polls.
    int32_t _liveReaders;
}
@property (nonatomic) int guestPid;
@property (nonatomic) NSDate *startTime;
@property (nonatomic, copy) ISHShellLineCallback lineCallback;
@property (nonatomic, copy) ISHShellCompletionCallback completion;
// nanoMuse: 先保留原始字节再解码，不按换行数或UTF-16长度截断。
@property (nonatomic) NivoShellCapture *stdoutCapture;
@property (nonatomic) NivoShellCapture *stderrCapture;
@property (nonatomic) uint64_t managedFsContext;
@property (nonatomic) BOOL isFinishing;
@property (nonatomic) NSTimeInterval finishStartedAt;
@property (nonatomic) int pendingExitCode;
@property (nonatomic) ISHShellExecutorError pendingError;
@property (nonatomic) dispatch_semaphore_t waitSemaphore;
@property (nonatomic) ISHShellExecutionResult *result;
@property (atomic) BOOL isCompleted;
/// Readers still running for this context. Incremented before each reader is
/// dispatched and decremented as it returns, so `cleanup` can tell whether the
/// pipe fds are still being polled. Mutated only via retainReader/releaseReader.
@property (readonly) int32_t liveReaders;
- (void)retainReader;
/// Returns the count remaining after this reader leaves.
- (int32_t)releaseReader;
/// Set once the run has been finalised (by exit OR by timeout), so the two
/// paths cannot both finalise the same context. See +finalizeContext:.
@property (atomic) BOOL didFinalize;

- (int *)stdoutPipe;
- (int *)stderrPipe;
- (BOOL)closePipesIfNoReaders;

@end

@implementation ISHShellExecutionContext

- (int *)stdoutPipe {
    return _stdoutPipe;
}

- (int *)stderrPipe {
    return _stderrPipe;
}

- (instancetype)init {
    if (self = [super init]) {
        // nanoMuse: 旧调用保持完整保存，新的定时接口在启动前替换成指定上限。
        _stdoutCapture = [[NivoShellCapture alloc] initWithMaximumBytes:NSUIntegerMax];
        _stderrCapture = [[NivoShellCapture alloc] initWithMaximumBytes:NSUIntegerMax];
        _stdoutPipe[0] = -1;
        _stdoutPipe[1] = -1;
        _stderrPipe[0] = -1;
        _stderrPipe[1] = -1;
        _result = [[ISHShellExecutionResult alloc] init];
        _result.error = ISHShellExecutorErrorNone;
    }
    return self;
}

/// Close the pipe fds, but ONLY once no reader thread is still polling them.
/// Returns YES if the fds were closed (or were already closed).
///
/// Closing an fd that another thread is blocked in poll() on is a
/// use-after-free of the descriptor number: poll does not fail, the number is
/// immediately reusable, and the next pipe()/open() in the process hands the
/// same number to someone else — after which this reader is reading a
/// DIFFERENT command's pipe and appending that output to this command's
/// buffer. So the close is gated on the reader count reaching zero; readers
/// are told to stop by `isCompleted`, and whoever observes the last one leave
/// performs the close.
///
/// The fd array is guarded by @synchronized(self) because the closing thread
/// and the last reader can reach here at the same time; without it both can
/// see a non-negative fd and close it twice, and a double close is just as
/// dangerous as an early one (it can close an unrelated, freshly-recycled fd).
- (int32_t)liveReaders {
    return OSAtomicAdd32(0, &_liveReaders);   // atomic load
}

- (void)retainReader {
    OSAtomicIncrement32(&_liveReaders);
}

- (int32_t)releaseReader {
    return OSAtomicDecrement32(&_liveReaders);
}

- (BOOL)closePipesIfNoReaders {
    if (self.liveReaders > 0) return NO;
    @synchronized(self) {
        if (_stdoutPipe[0] >= 0) close(_stdoutPipe[0]);
        if (_stdoutPipe[1] >= 0) close(_stdoutPipe[1]);
        if (_stderrPipe[0] >= 0) close(_stderrPipe[0]);
        if (_stderrPipe[1] >= 0) close(_stderrPipe[1]);
        _stdoutPipe[0] = _stdoutPipe[1] = -1;
        _stderrPipe[0] = _stderrPipe[1] = -1;
    }
    return YES;
}

/// Ask readers to stop, then close if they already have.
///
/// Kept as `cleanup` because existing call sites use it, but note the two
/// distinct cases: on the failure paths in the launch routine no reader has
/// been started yet (liveReaders == 0), so this closes immediately, which is
/// what those paths need. Once readers are running the close is deferred to
/// whichever reader exits last.
- (void)cleanup {
    self.isCompleted = YES;
    [self closePipesIfNoReaders];
}

- (void)dealloc {
    // Last resort. If a reader were somehow still running, `self` could not be
    // deallocating — the reader block retains the context — so by definition
    // liveReaders is 0 here and closing is safe.
    [self closePipesIfNoReaders];
}

@end

#pragma mark - Executor Implementation

// nanoMuse: 显式声明新增原生私有入口，保留准确的指针返回类型。
@interface ISHShellExecutor ()
+ (int)launchExecutable:(NSString *)executable arguments:(NSArray<NSString *> *)arguments
            environment:(NSDictionary<NSString *, NSString *> *)environment stdinData:(NSData *)stdinData
              fsContext:(uint64_t)fsContext maximumCaptureBytes:(NSUInteger)maximumCaptureBytes
       managedExecution:(BOOL)managedExecution lineCallback:(ISHShellLineCallback)lineCallback
             completion:(ISHShellCompletionCallback)completion;
+ (struct fd *)guestDescriptor:(int)hostDescriptor flags:(unsigned)flags;
+ (void)discardUnstartedTask:(struct task *)task;
+ (BOOL)terminateManagedTasks:(uint64_t)context;
+ (void)drainAndFinalizeContext:(ISHShellExecutionContext *)ctx;
@end

@implementation ISHShellExecutor

static NSMutableDictionary<NSNumber *, ISHShellExecutionContext *> *_activeExecutions;
// nanoMuse: 根PID提前回收后仍以不可复用的运行上下文保持结算和取消身份。
static NSMutableDictionary<NSNumber *, ISHShellExecutionContext *> *_managedExecutions;
static dispatch_queue_t _readerQueue;
static dispatch_once_t _onceToken;
static dispatch_source_t _sweepTimer;

/// Live reader threads across all executions. The leak this file exists to
/// prevent shows up here as a number that only ever goes up: each stranded
/// command pins two readers on a DISPATCH_QUEUE_CONCURRENT queue, and once
/// GCD's worker pool is exhausted no new command can run at all.
static int32_t _globalLiveReaders = 0;
/// How many contexts the sweeper has had to reclaim. Non-zero means a run
/// finished without either the exit notification or the timeout path
/// finalising it — i.e. a bug upstream of the sweeper, worth seeing in logs.
static int32_t _sweptContexts = 0;

+ (void)initialize {
    if (self == [ISHShellExecutor class]) {
        _activeExecutions = [NSMutableDictionary dictionary];
        _managedExecutions = [NSMutableDictionary dictionary];
        dispatch_once(&_onceToken, ^{
            _readerQueue = dispatch_queue_create("com.ish.shellexecutor.reader",
                                                 DISPATCH_QUEUE_CONCURRENT);
        });

        // Register for process exit notifications
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(processDidExit:)
                                                     name:ISHProcessExitedNotification
                                                   object:nil];

        [self startStaleContextSweeper];
    }
}

#pragma mark - Stale Context Sweeper

/// Periodically reclaim contexts that were never finalised.
///
/// The timeout path and the exit notification between them should finalise
/// every run, so in a correct build this never fires. It is here because the
/// failure it guards against is not proportionate: one missed teardown pins
/// two reader threads for the life of the process, and enough of them make the
/// app unable to run any command until the device is restarted. A periodic
/// check is cheap; that outcome is not.
///
/// Anything it reclaims is a bug upstream, so it logs at a level meant to be
/// noticed rather than cleaning up quietly.
+ (void)startStaleContextSweeper {
    _sweepTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                         dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(_sweepTimer,
                              dispatch_time(DISPATCH_TIME_NOW,
                                            (int64_t)(ISHShellExecutorSweepInterval * NSEC_PER_SEC)),
                              (uint64_t)(ISHShellExecutorSweepInterval * NSEC_PER_SEC),
                              (uint64_t)(5 * NSEC_PER_SEC));   // generous leeway: not time-critical
    dispatch_source_set_event_handler(_sweepTimer, ^{
        [self sweepStaleContexts];
    });
    dispatch_resume(_sweepTimer);
}

+ (void)sweepStaleContexts {
    NSMutableArray<ISHShellExecutionContext *> *stale = [NSMutableArray array];

    // Collect under the lock, finalise outside it. finalizeContext: invokes
    // the caller's completion block, and running arbitrary caller code while
    // holding the registry lock is how a deadlock gets introduced — that block
    // is free to start another command.
    @synchronized(_activeExecutions) {
        // nanoMuse: 根PID槽已被复用时，独立上下文仍需要被扫描和收尾。
        NSMutableSet *contexts = [NSMutableSet setWithArray:_activeExecutions.allValues];
        [contexts addObjectsFromArray:_managedExecutions.allValues];
        for (ISHShellExecutionContext *ctx in contexts) {
            NSTimeInterval age = -[ctx.startTime timeIntervalSinceNow];
            if (age > ISHShellExecutorStaleContextAge) {
                [stale addObject:ctx];
            }
        }
    }

    if (stale.count == 0) return;

    NSLog(@"ISHShellExecutor[sweep]: reclaiming %lu stale context(s) — these should "
          @"have been finalised by exit or timeout; liveReaders=%d",
          (unsigned long)stale.count, _globalLiveReaders);

    for (ISHShellExecutionContext *ctx in stale) {
        NSLog(@"ISHShellExecutor[sweep]: pid=%d age=%.0fs isCompleted=%d readers=%d",
              ctx.guestPid, -[ctx.startTime timeIntervalSinceNow],
              ctx.isCompleted, ctx.liveReaders);
        OSAtomicIncrement32(&_sweptContexts);
        [self finalizeContext:ctx exitCode:-1 error:ISHShellExecutorErrorTimeout];
    }
}

/// Reader/leak counters, for diagnosing this class of problem from a log.
+ (NSString *)leakGuardStatus {
    NSUInteger active;
    @synchronized(_activeExecutions) { active = _activeExecutions.count; }
    return [NSString stringWithFormat:
            @"activeExecutions=%lu liveReaders=%d sweptContexts=%d",
            (unsigned long)active, _globalLiveReaders, _sweptContexts];
}

#pragma mark - Public API

+ (int)executeCommand:(NSString *)command
         lineCallback:(ISHShellLineCallback)lineCallback
           completion:(ISHShellCompletionCallback)completion {
    // [T-heredoc-trailing-newline] busybox ash's heredoc parser needs a newline
    // after the terminator line to confirm the here-doc is closed. When the
    // command string ends exactly at the terminator with no trailing "\n"
    // (e.g. `python3 <<'EOF'\n…\nEOF`), ash keeps waiting for the terminator,
    // hits end-of-input, and fails with `unexpected end of file (expecting ")")`
    // — a 100% deterministic failure for any heredoc-terminated command.
    // Appending a newline is harmless for every other command (a trailing blank
    // line is a no-op in sh) and fixes the heredoc case. Applies to ALL
    // shell_execute commands since they all funnel through here.
    NSString *normalized = [command hasSuffix:@"\n"] ? command : [command stringByAppendingString:@"\n"];
    return [self executeExecutable:@"/bin/sh"
                         arguments:@[@"-c", normalized]
                       environment:nil
                      lineCallback:lineCallback
                        completion:completion];
}

+ (int)executeExecutable:(NSString *)executable
               arguments:(NSArray<NSString *> *)arguments
             environment:(NSDictionary<NSString *, NSString *> *)environment
            lineCallback:(ISHShellLineCallback)lineCallback
              completion:(ISHShellCompletionCallback)completion {
    return [self executeExecutable:executable
                         arguments:arguments
                       environment:environment
                         stdinData:nil
                      lineCallback:lineCallback
                        completion:completion];
}

+ (int)executeExecutable:(NSString *)executable
               arguments:(NSArray<NSString *> *)arguments
             environment:(NSDictionary<NSString *, NSString *> *)environment
               stdinData:(NSData *)stdinData
            lineCallback:(ISHShellLineCallback)lineCallback
              completion:(ISHShellCompletionCallback)completion {
    return [self executeExecutable:executable
                         arguments:arguments
                       environment:environment
                         stdinData:stdinData
                         fsContext:0
                      lineCallback:lineCallback
                        completion:completion];
}

+ (int)executeExecutable:(NSString *)executable
               arguments:(NSArray<NSString *> *)arguments
             environment:(NSDictionary<NSString *, NSString *> *)environment
               stdinData:(NSData *)stdinData
               fsContext:(uint64_t)fsContext
            lineCallback:(ISHShellLineCallback)lineCallback
              completion:(ISHShellCompletionCallback)completion {
    // nanoMuse: 保留旧入口，普通聊天命令不取得定时脚本的进程组独占语义。
    return [self launchExecutable:executable arguments:arguments environment:environment stdinData:stdinData
                       fsContext:fsContext maximumCaptureBytes:NSUIntegerMax managedExecution:NO
                    lineCallback:lineCallback completion:completion];
}

// nanoMuse: 新入口限制保存量，并清理使用独立上下文的后台子进程。
+ (int)executeExecutable:(NSString *)executable
               arguments:(NSArray<NSString *> *)arguments
             environment:(NSDictionary<NSString *, NSString *> *)environment
               stdinData:(NSData *)stdinData
               fsContext:(uint64_t)fsContext
     maximumCaptureBytes:(NSUInteger)maximumCaptureBytes
            lineCallback:(ISHShellLineCallback)lineCallback
              completion:(ISHShellCompletionCallback)completion {
    if (fsContext == 0) return ISHShellExecutorErrorExecFailed;
    return [self launchExecutable:executable arguments:arguments environment:environment stdinData:stdinData
                       fsContext:fsContext maximumCaptureBytes:maximumCaptureBytes managedExecution:YES
                    lineCallback:lineCallback completion:completion];
}

/// nanoMuse: 参数与环境验证在创建来宾任务前完成，失败不会遗留半启动任务。
+ (int)launchExecutable:(NSString *)executable
              arguments:(NSArray<NSString *> *)arguments
            environment:(NSDictionary<NSString *, NSString *> *)environment
              stdinData:(NSData *)stdinData
              fsContext:(uint64_t)fsContext
    maximumCaptureBytes:(NSUInteger)maximumCaptureBytes
       managedExecution:(BOOL)managedExecution
           lineCallback:(ISHShellLineCallback)lineCallback
             completion:(ISHShellCompletionCallback)completion {

    // Bail out if the iSH kernel hasn't booted yet. become_new_init_child()
    // calls pid_get_task(1) and then assert(init != NULL); on a non-booted
    // kernel that assert fires and the process crashes (seen as a SIGABRT
    // from __assert_rtn on a Caulk concurrent queue). Returning an error
    // lets the caller surface the condition instead of taking down the app.
    if (!ISHKernel.shared.isBooted) {
        NSLog(@"ISHShellExecutor: kernel not booted — refusing to execute %@", executable);
        return ISHShellExecutorErrorProcessCreationFailed;
    }

    NivoShellInvocation *invocation = [[NivoShellInvocation alloc] initWithExecutable:executable
        arguments:arguments environment:environment];
    if (!invocation) return ISHShellExecutorErrorExecFailed;

    ISHShellExecutionContext *ctx = [[ISHShellExecutionContext alloc] init];
    ctx.lineCallback = lineCallback;
    ctx.completion = completion;
    ctx.startTime = [NSDate date];
    ctx.stdoutCapture = [[NivoShellCapture alloc] initWithMaximumBytes:maximumCaptureBytes];
    ctx.stderrCapture = [[NivoShellCapture alloc] initWithMaximumBytes:maximumCaptureBytes];
    ctx.managedFsContext = managedExecution ? fsContext : 0;

    // Create pipes for stdout and stderr
    if (pipe([ctx stdoutPipe]) < 0 || pipe([ctx stderrPipe]) < 0) {
        NSLog(@"ISHShellExecutor: pipe() failed: %s", strerror(errno));
        [ctx cleanup];
        return ISHShellExecutorErrorProcessCreationFailed;
    }

    // nanoMuse: 全部管道和来宾fd预先准备，资源失败发生在创建来宾任务之前。
    if (fcntl([ctx stdoutPipe][0], F_SETFL, O_NONBLOCK) < 0 ||
        fcntl([ctx stderrPipe][0], F_SETFL, O_NONBLOCK) < 0) {
        [ctx cleanup];
        return ISHShellExecutorErrorProcessCreationFailed;
    }
    int stdinPipe[2] = {-1, -1};
    if (stdinData && pipe(stdinPipe) < 0) {
        [ctx cleanup];
        return ISHShellExecutorErrorProcessCreationFailed;
    }
    struct fd *descriptors[3] = {
        [self guestDescriptor:stdinData ? dup(stdinPipe[0]) : open("/dev/null", O_RDONLY) flags:O_RDONLY_],
        [self guestDescriptor:dup([ctx stdoutPipe][1]) flags:O_WRONLY_],
        [self guestDescriptor:dup([ctx stderrPipe][1]) flags:O_WRONLY_]
    };
    if (stdinPipe[0] >= 0) close(stdinPipe[0]);
    if (!descriptors[0] || !descriptors[1] || !descriptors[2]) {
        for (int index = 0; index < 3; index++) if (descriptors[index]) fd_close(descriptors[index]);
        if (stdinPipe[1] >= 0) close(stdinPipe[1]);
        [ctx cleanup];
        return ISHShellExecutorErrorProcessCreationFailed;
    }
    struct task *saved_current = current;
    int err = become_new_init_child();
    if (err < 0) {
        current = saved_current;
        for (int index = 0; index < 3; index++) fd_close(descriptors[index]);
        if (stdinPipe[1] >= 0) close(stdinPipe[1]);
        [ctx cleanup];
        return ISHShellExecutorErrorProcessCreationFailed;
    }
    struct task *task = current;
    task->group->fs_context = fsContext;
    for (int index = 0; index < 3; index++) task->files->files[index] = descriptors[index];

    // Close write ends in parent
    close([ctx stdoutPipe][1]);
    close([ctx stderrPipe][1]);
    [ctx stdoutPipe][1] = -1;
    [ctx stderrPipe][1] = -1;

    // nanoMuse: 动态字节向量已校验并冻结，不再使用16KB数组或静默截断环境。
    err = do_execve(executable.UTF8String, invocation.argumentCount,
        invocation.argumentData.bytes, invocation.environmentData.bytes);
    if (err < 0) {
        // nanoMuse: exec失败也销毁未启动任务及其fd，不能遗留没有读取者的写端。
        [self discardUnstartedTask:task];
        current = saved_current;
        if (stdinPipe[1] >= 0) close(stdinPipe[1]);
        [ctx cleanup];
        NSLog(@"ISHShellExecutor: do_execve failed: %d", err);
        return ISHShellExecutorErrorExecFailed;
    }

    // nanoMuse: 先登记和安装两个读取器，避免短命命令在登记之前退出。
    ctx.guestPid = task->pid;
    ctx.result.pid = ctx.guestPid;
    @synchronized(_activeExecutions) {
        _activeExecutions[@(ctx.guestPid)] = ctx;
        if (ctx.managedFsContext != 0) _managedExecutions[@(ctx.managedFsContext)] = ctx;
    }
    [self startReaderForPipe:[ctx stdoutPipe][0] context:ctx isStdErr:NO];
    [self startReaderForPipe:[ctx stderrPipe][0] context:ctx isStdErr:YES];
    task_start(task);
    current = saved_current;

    // Write stdinData to pipe in background, then close write end
    if (stdinData && stdinPipe[1] >= 0) {
        NSData *dataToWrite = [stdinData copy];
        int writeFd = stdinPipe[1];
        stdinPipe[1] = -1; // ownership transferred
        int guestPid = ctx.guestPid;
        NSLog(@"ISHShellExecutor[stdin]: scheduling stdinData write (%lu bytes) to fd=%d for pid=%d",
              (unsigned long)dataToWrite.length, writeFd, guestPid);
        dispatch_async(_readerQueue, ^{
            const uint8_t *bytes = dataToWrite.bytes;
            size_t remaining = dataToWrite.length;
            size_t totalWritten = 0;
            while (remaining > 0) {
                ssize_t written = write(writeFd, bytes, remaining);
                if (written <= 0) {
                    NSLog(@"ISHShellExecutor[stdin]: write returned %zd (errno=%d) for pid=%d, stopping", written, errno, guestPid);
                    break;
                }
                bytes += written;
                remaining -= written;
                totalWritten += written;
            }
            close(writeFd);
            NSLog(@"ISHShellExecutor[stdin]: pipe write complete and closed — wrote %zu/%lu bytes for pid=%d",
                  totalWritten, (unsigned long)dataToWrite.length, guestPid);
        });
    } else if (!stdinData) {
        NSLog(@"ISHShellExecutor[stdin]: stdin is /dev/null for pid=%d", ctx.guestPid);
    }

    return ctx.guestPid;
}

/// nanoMuse: 描述符构建失败时总是归还宿主fd，fstat保留管道的真实类型。
+ (struct fd *)guestDescriptor:(int)hostDescriptor flags:(unsigned)flags {
    if (hostDescriptor < 0) return NULL;
    struct fd *descriptor = adhoc_fd_create(&realfs_fdops);
    if (!descriptor) { close(hostDescriptor); return NULL; }
    descriptor->real_fd = hostDescriptor;
    descriptor->flags = flags;
    struct stat metadata;
    if (fstat(hostDescriptor, &metadata) == 0) {
        descriptor->stat.mode = metadata.st_mode;
        descriptor->stat.size = metadata.st_size;
        descriptor->stat.inode = metadata.st_ino;
    }
    return descriptor;
}

/// nanoMuse: 仅处理未task_start的任务，按内核退出顺序释放其独占资源。
+ (void)discardUnstartedTask:(struct task *)task {
    if (task->files) fdtable_release(task->files);
    if (task->fs) fs_info_release(task->fs);
    if (task->mm) mm_release(task->mm);
    lock(&pids_lock);
    if (task->sighand) sighand_release(task->sighand);
    struct sigqueue *entry, *next;
    list_for_each_entry_safe(&task->queue, entry, next, queue) {
        list_remove(&entry->queue);
        free(entry);
    }
    cond_destroy(&task->group->child_exit);
    cond_destroy(&task->group->stopped_cond);
    task_leave_session(task);
    list_remove(&task->group->pgroup);
    free(task->group);
    task_destroy(task);
    unlock(&pids_lock);
}

// nanoMuse: 同步入口的超时结果也等待读取结束，未完成的捕获明确标记为不完整。
+ (ISHShellExecutionResult *)executeCommandSync:(NSString *)command
                                        timeout:(NSTimeInterval)timeout
                                   lineCallback:(ISHShellLineCallback)lineCallback {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    NSLock *resultLock = [[NSLock alloc] init];
    __block ISHShellExecutionResult *received = nil;
    int pid = [self executeCommand:command lineCallback:lineCallback completion:^(ISHShellExecutionResult *result) {
        [resultLock lock];
        received = result;
        [resultLock unlock];
        dispatch_semaphore_signal(semaphore);
    }];
    if (pid < 0) {
        ISHShellExecutionResult *failed = [[ISHShellExecutionResult alloc] init];
        failed.error = (ISHShellExecutorError)pid;
        return failed;
    }
    dispatch_time_t deadline = timeout > 0
        ? dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)) : DISPATCH_TIME_FOREVER;
    BOOL timedOut = dispatch_semaphore_wait(semaphore, deadline) != 0;
    if (timedOut) {
        [self killProcessGroup:pid];
        [self finalizeTimedOutPid:pid];
        dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC));
    }
    [resultLock lock];
    ISHShellExecutionResult *result = received;
    [resultLock unlock];
    if (!timedOut && result) return result;
    ISHShellExecutionResult *failure = [[ISHShellExecutionResult alloc] init];
    failure.pid = pid;
    failure.error = ISHShellExecutorErrorTimeout;
    failure.output = result.output ?: @"";
    failure.errorOutput = result.errorOutput ?: @"";
    failure.stdoutBytes = result.stdoutBytes;
    failure.errorOutputBytes = result.errorOutputBytes;
    failure.outputTruncated = result.outputTruncated;
    failure.errorOutputTruncated = result.errorOutputTruncated;
    failure.duration = result ? result.duration : MAX(timeout, 0);
    failure.captureError = result ? result.captureError : @"SCRIPT_OUTPUT_DRAIN_INCOMPLETE";
    return failure;
}

+ (BOOL)killProcess:(int)pid withSignal:(int)signal {
    struct siginfo_ info = SIGINFO_NIL;
    lock(&pids_lock);
    struct task *task = pid_get_task((dword_t)pid);
    if (task) {
        send_signal(task, signal, info);
    }
    unlock(&pids_lock);
    return task != NULL;
}

// Returns YES if `t` is `rootPid` or has `rootPid` somewhere in its parent
// chain. The caller must hold `pids_lock`. Bounded by MAX_PID to defend
// against a malformed parent cycle.
static BOOL ISHTaskIsDescendantOf(struct task *t, pid_t_ rootPid) {
    int hops = 0;
    while (t != NULL && hops < MAX_PID) {
        if (t->pid == rootPid) return YES;
        t = t->parent;
        hops++;
    }
    return NO;
}

+ (void)killProcessGroup:(int)pid {
    // nanoMuse: 定时脚本不能依赖根进程继续存在，孤儿及新进程组仍属于同一独立context。
    ISHShellExecutionContext *managed;
    @synchronized(_activeExecutions) { managed = _activeExecutions[@(pid)]; }
    if (managed.managedFsContext != 0) {
        [self terminateManagedTasks:managed.managedFsContext];
        return;
    }
    // Signal every task belonging to this shell_execute command — matched
    // either by pgid OR by being a descendant of the root pid. The ancestry
    // arm is needed because busybox ash sometimes puts subshells into a
    // fresh process group (setpgid(0,0) for job control), which would leave
    // `sleep` and similar grandchildren invisible to a pgid-only sweep —
    // that is why the Stop button failed to kill `sleep`.
    //
    // Safety rails:
    //   - Refuse pid <= 1: pid 1 is init; an ancestry sweep rooted at init
    //     would match every task in iSH and tear the whole kernel down.
    //   - Re-verify the task pointer on the deferred SIGKILL pass. If the
    //     root has already exited and its pid was recycled to an unrelated
    //     task, the pointer comparison fails and we abort the sweep —
    //     otherwise we would kill an innocent command and its descendants.
    if (pid <= 1) {
        NSLog(@"ISHShellExecutor: refusing killProcessGroup for pid=%d", pid);
        return;
    }
    struct siginfo_ info = SIGINFO_NIL;

    lock(&pids_lock);
    struct task *rootTask = pid_get_task((dword_t)pid);
    pid_t_ pgid = 0;
    if (rootTask) {
        pgid = rootTask->group->pgid;
        for (int i = 2; i < MAX_PID; i++) {
            struct task *t = pid_get_task(i);
            if (!t) continue;
            BOOL byPgid = (pgid != 0 && t->group->pgid == pgid);
            BOOL byAncestry = ISHTaskIsDescendantOf(t, (pid_t_)pid);
            if (byPgid || byAncestry) {
                send_signal(t, SIGTERM_, info);
            }
        }
    }
    unlock(&pids_lock);

    if (rootTask == NULL) {
        // Root already gone — don't schedule a delayed SIGKILL against a pid
        // that might already have been recycled.
        return;
    }

    // After a short delay, SIGKILL any survivors. SIGTERM may be caught
    // or, for tasks blocked inside host nanosleep, need the pthread_kill
    // wakeup that send_signal already issues — give the wakeup a chance
    // to land and the signal handler to run before escalating.
    int capturedPid = pid;
    struct task *capturedRoot = rootTask;
    pid_t_ capturedPgid = pgid;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(200 * NSEC_PER_MSEC)), dispatch_get_global_queue(0, 0), ^{
        lock(&pids_lock);
        // Verify the pid still maps to the same task struct we saw earlier.
        // pid_get_task returns NULL once task_destroy unlinks the task, and
        // a different pointer if the pid slot has been reused. Either way
        // the original command is already gone — skip the sweep.
        struct task *still = pid_get_task((dword_t)capturedPid);
        if (still != capturedRoot) {
            unlock(&pids_lock);
            return;
        }
        for (int i = 2; i < MAX_PID; i++) {
            struct task *t = pid_get_task(i);
            if (!t) continue;
            BOOL byPgid = (capturedPgid != 0 && t->group->pgid == capturedPgid);
            BOOL byAncestry = ISHTaskIsDescendantOf(t, (pid_t_)capturedPid);
            if (byPgid || byAncestry) {
                send_signal(t, SIGKILL_, info);
            }
        }
        unlock(&pids_lock);
    });
}

#pragma mark - Finalisation

/// nanoMuse: 取消的寻址不依赖根进程还活着，也不会误杀复用了相同PID的新运行。
+ (void)cancelExecutionContext:(uint64_t)fsContext {
    ISHShellExecutionContext *ctx;
    @synchronized(_activeExecutions) { ctx = _managedExecutions[@(fsContext)]; }
    if (!ctx) return;
    [self terminateManagedTasks:fsContext];
    [self finalizeContext:ctx exitCode:-1 error:ISHShellExecutorErrorCancelled];
}

/// nanoMuse: 先记录唯一终态请求，再等待子进程停止和两个管道读取完成。
+ (void)finalizeContext:(ISHShellExecutionContext *)ctx
               exitCode:(int)exitCode
                  error:(ISHShellExecutorError)error {
    if (!ctx) return;
    @synchronized(ctx) {
        if (ctx.didFinalize) return;
        if (ctx.isFinishing) {
            if (error != ISHShellExecutorErrorNone && ctx.pendingError == ISHShellExecutorErrorNone) {
                ctx.pendingError = error;
                ctx.pendingExitCode = exitCode;
            }
            return;
        }
        ctx.isFinishing = YES;
        ctx.pendingExitCode = exitCode;
        ctx.pendingError = error;
        ctx.finishStartedAt = NSProcessInfo.processInfo.systemUptime;
        ctx.result.duration = -[ctx.startTime timeIntervalSinceNow];
    }
    [self drainAndFinalizeContext:ctx];
}

/// nanoMuse: 独立上下文可跨fork、setsid和孤儿收养识别进程，不依赖已退出的根PID。
+ (BOOL)terminateManagedTasks:(uint64_t)context {
    if (context == 0) return NO;
    BOOL hasLiveTasks = NO;
    lock(&pids_lock);
    for (int identifier = 2; identifier < MAX_PID; identifier++) {
        struct task *task = pid_get_task(identifier);
        if (!task || !task->group || task->group->fs_context != context) continue;
        if (task->exiting || task->zombie) continue;
        hasLiveTasks = YES;
        send_signal(task, SIGKILL_, SIGINFO_NIL);
    }
    unlock(&pids_lock);
    return hasLiveTasks;
}

/// nanoMuse: 超限输出继续排空；读取等待有界，仍活着的子进程保持占位直至实际退出。
+ (void)drainAndFinalizeContext:(ISHShellExecutionContext *)ctx {
    BOOL hasLiveTasks = [self terminateManagedTasks:ctx.managedFsContext];
    if (NSProcessInfo.processInfo.systemUptime - ctx.finishStartedAt > 3.0) {
        // reader在下一轮poll醒来时记录缺少EOF；不可把强制停止当成完整输出。
        ctx.isCompleted = YES;
    }
    if (hasLiveTasks || ctx.liveReaders > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [self drainAndFinalizeContext:ctx];
        });
        return;
    }
    @synchronized(ctx) {
        if (ctx.didFinalize) return;
        ctx.didFinalize = YES;
        ctx.isCompleted = YES;
        ctx.result.exitCode = ctx.pendingExitCode;
        ctx.result.error = ctx.pendingError;
        ctx.result.output = ctx.stdoutCapture.output;
        ctx.result.errorOutput = ctx.stderrCapture.output;
        ctx.result.stdoutBytes = ctx.stdoutCapture.totalBytes;
        ctx.result.errorOutputBytes = ctx.stderrCapture.totalBytes;
        ctx.result.outputTruncated = ctx.stdoutCapture.isTruncated;
        ctx.result.errorOutputTruncated = ctx.stderrCapture.isTruncated;
        ctx.result.captureError = ctx.stdoutCapture.captureError ?: ctx.stderrCapture.captureError;
    }
    @synchronized(_activeExecutions) {
        // 迟到的完成事件不能删除PID槽中后来登记的命令。
        if (_activeExecutions[@(ctx.guestPid)] == ctx) [_activeExecutions removeObjectForKey:@(ctx.guestPid)];
        if (ctx.managedFsContext != 0 && _managedExecutions[@(ctx.managedFsContext)] == ctx) {
            [_managedExecutions removeObjectForKey:@(ctx.managedFsContext)];
        }
    }
    [ctx closePipesIfNoReaders];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (ctx.completion) ctx.completion(ctx.result);
        if (ctx.waitSemaphore) dispatch_semaphore_signal(ctx.waitSemaphore);
    });
}

+ (void)finalizeTimedOutPid:(int)pid {
    ISHShellExecutionContext *ctx;
    @synchronized(_activeExecutions) { ctx = _activeExecutions[@(pid)]; }
    [self finalizeContext:ctx exitCode:-1 error:ISHShellExecutorErrorTimeout];
}

#pragma mark - Process Exit Handling

+ (void)processDidExit:(NSNotification *)notification {
    int pid = [notification.userInfo[@"pid"] intValue];
    int status = [notification.userInfo[@"code"] intValue];
    uint64_t context = [notification.userInfo[@"fsContext"] unsignedLongLongValue];
    ISHShellExecutionContext *ctx;
    @synchronized(_activeExecutions) { ctx = _managedExecutions[@(context)] ?: _activeExecutions[@(pid)]; }
    if (!ctx) return;
    // nanoMuse: 脚本的内核context每次唯一，拒绝迟到通知结算已经复用的PID。
    if (ctx.guestPid != pid || (ctx.managedFsContext != 0 && ctx.managedFsContext != context)) return;
    int exitCode = nivo_shell_exit_code(status);
    [self finalizeContext:ctx exitCode:exitCode error:ISHShellExecutorErrorNone];
}

#pragma mark - Pipe Reading

+ (void)startReaderForPipe:(int)fd context:(ISHShellExecutionContext *)ctx isStdErr:(BOOL)isStdErr {
    [ctx retainReader];
    OSAtomicIncrement32(&_globalLiveReaders);
    dispatch_async(_readerQueue, ^{
        @try {
            [self readPipe:fd context:ctx isStdErr:isStdErr];
        } @finally {
            OSAtomicDecrement32(&_globalLiveReaders);
            int32_t remaining = [ctx releaseReader];
            if (remaining == 0 && ctx.isCompleted) [ctx closePipesIfNoReaders];
        }
    });
}

/// nanoMuse: 回调仅消费完整UTF-8；单字节分包也不回退成乱码。
+ (void)emitAvailableLines:(NSMutableData *)pending lineBuffer:(NSMutableString *)lineBuffer
                  context:(ISHShellExecutionContext *)ctx isStdErr:(BOOL)isStdErr {
    while (pending.length > 0) {
        bool isInvalid = false;
        NSUInteger length = nivo_shell_utf8_prefix(pending.bytes, pending.length, &isInvalid);
        if (length > 0) {
            NSString *chunk = [[NSString alloc] initWithBytes:pending.bytes length:length encoding:NSUTF8StringEncoding];
            if (chunk) [lineBuffer appendString:chunk];
            [pending replaceBytesInRange:NSMakeRange(0, length) withBytes:NULL length:0];
        }
        if (!isInvalid) break;
        [lineBuffer appendString:@"\uFFFD"];
        [pending replaceBytesInRange:NSMakeRange(0, 1) withBytes:NULL length:0];
    }
    while (YES) {
        NSRange newline = [lineBuffer rangeOfString:@"\n"];
        if (newline.location == NSNotFound) break;
        NSString *line = [lineBuffer substringToIndex:newline.location];
        [lineBuffer deleteCharactersInRange:NSMakeRange(0, newline.location + 1)];
        dispatch_async(dispatch_get_main_queue(), ^{ ctx.lineCallback(line, isStdErr); });
    }
}

/// nanoMuse: poll错误、read错误、强制停止与真正EOF分别处理，读取全程按字节计数。
+ (void)readPipe:(int)fd context:(ISHShellExecutionContext *)ctx isStdErr:(BOOL)isStdErr {
    uint8_t buffer[4096];
    NivoShellCapture *capture = isStdErr ? ctx.stderrCapture : ctx.stdoutCapture;
    NSMutableData *pending = [NSMutableData data];
    NSMutableString *lineBuffer = [NSMutableString string];
    struct pollfd descriptor = { .fd = fd, .events = POLLIN };
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + ISHShellExecutorReaderMaxLifetime;
    BOOL reachedEOF = NO;
    while (!ctx.isCompleted && NSProcessInfo.processInfo.systemUptime < deadline) {
        int ready = poll(&descriptor, 1, 100);
        if (ready < 0 && errno == EINTR) continue;
        if (ready < 0 || (descriptor.revents & (POLLERR | POLLNVAL))) break;
        if (ready == 0) continue;
        // POLLHUP仍必须read，缓冲区可能还有最后一批数据。
        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count == 0) { reachedEOF = YES; break; }
        if (count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (count < 0) break;
        @autoreleasepool {
            NSData *kept = [capture appendData:[NSData dataWithBytes:buffer length:(NSUInteger)count]];
            if (ctx.lineCallback) {
                [pending appendData:kept];
                [self emitAvailableLines:pending lineBuffer:lineBuffer context:ctx isStdErr:isStdErr];
            }
        }
    }
    [capture finishReachedEOF:reachedEOF];
    if (ctx.lineCallback && lineBuffer.length > 0) {
        NSString *remaining = [lineBuffer copy];
        dispatch_async(dispatch_get_main_queue(), ^{ ctx.lineCallback(remaining, isStdErr); });
    }
}

@end
