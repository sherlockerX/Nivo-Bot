import Foundation

/// 脚本stdout与stderr分开保存，截断和读取故障不能变成无条件成功。
struct NivoScheduledProcessResult: Sendable {
    var stdout: String
    var stderr: String
    var exitCode: Int
    var stdoutBytes: Int64
    var truncated: Bool
    var captureError: String?
    var timedOut = false
}

/// 原生回调来自多个队列，使用锁保护continuation与进程生命周期。
final class NivoScheduledProcessWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private let terminateProcess: @Sendable (Int32) -> Void

    /// 实际宿主注入进程终止动作，便于验证取消与PID交接的真实状态规则。
    init(terminateProcess: @escaping @Sendable (Int32) -> Void) {
        self.terminateProcess = terminateProcess
    }
    private var continuation: CheckedContinuation<NivoScheduledProcessResult, Error>?
    private var pid: Int32 = 0
    private var isFinished = false
    private var isLaunching = false
    private var hasRequestedTermination = false
    private var pendingStop: Bool?
    private var timeout: DispatchWorkItem?

    /// 取消若发生在原生创建期间，先等PID交接并终止，再解除账户/运行锁。
    func beginLaunch() -> Bool {
        lock.withLock {
            guard !isFinished, !isLaunching, pid == 0, pendingStop == nil else { return false }
            isLaunching = true
            return true
        }
    }

    /// 安装唯一返回通道和截止计时，早到的取消会在这里立即完成。
    func start(_ continuation: CheckedContinuation<NivoScheduledProcessResult, Error>, timeout seconds: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in self?.timeoutReached() }
        let cancelled = lock.withLock {
            guard !isFinished else { return true }
            self.continuation = continuation
            timeout = work
            return false
        }
        if cancelled { continuation.resume(throwing: CancellationError()); return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// 原生启动返回PID后再处理挂起的取消，避免无人持有的新进程遗留。
    func didLaunch(_ process: Int32) {
        let interruption = lock.withLock { () -> Bool? in
            pid = process
            isLaunching = false
            return pendingStop
        }
        if process <= 1 {
            complete(NivoScheduledProcessResult(stdout: "", stderr: "", exitCode: Int(process), stdoutBytes: 0,
                truncated: false, captureError: "SCRIPT_PROCESS_START_FAILED"))
            return
        }
        if let interruption { stop(isTimeout: interruption) }
    }

    /// 正常与迟到回调共享同一个完成门，已经停止的执行不能被改回成功。
    func complete(_ result: NivoScheduledProcessResult) {
        let delivery = lock.withLock { () -> (CheckedContinuation<NivoScheduledProcessResult, Error>?, Bool?) in
            guard !isFinished else { return (nil, nil) }
            isFinished = true
            timeout?.cancel()
            defer { continuation = nil }
            return (continuation, pendingStop)
        }
        if delivery.1 == false { delivery.0?.resume(throwing: CancellationError()); return }
        var delivered = result
        if delivery.1 == true { delivered.timedOut = true; delivered.exitCode = 124 }
        delivery.0?.resume(returning: delivered)
    }

    /// 用户取消只请求停止，等待原生读取和子进程清理回调后才释放运行占位。
    func cancel() { stop(isTimeout: false) }

    /// 系统计时器与确定性测试进入同一超时路径，不依赖测试线程的sleep顺序。
    func timeoutReached() { stop(isTimeout: true) }

    private func stop(isTimeout: Bool) {
        let captured = lock.withLock { () -> (CheckedContinuation<NivoScheduledProcessResult, Error>?, Int32, Bool) in
            guard !isFinished else { return (nil, 0, isTimeout) }
            // 第一个停止原因决定结果，后到的超时不能将用户取消改成另一种结束。
            if pendingStop == nil { pendingStop = isTimeout }
            let wasTimeout = pendingStop ?? isTimeout
            if isLaunching { return (nil, 0, wasTimeout) }
            if pid > 1 {
                guard !hasRequestedTermination else { return (nil, 0, wasTimeout) }
                hasRequestedTermination = true
                timeout?.cancel()
                return (nil, pid, wasTimeout)
            }
            isFinished = true
            timeout?.cancel()
            defer { continuation = nil }
            return (continuation, pid, wasTimeout)
        }
        terminate(captured.1)
        // 存在原生进程时，只能由complete交付结果，保留已读输出和真实停止边界。
        if captured.1 > 1 { return }
        if captured.2 {
            captured.0?.resume(returning: NivoScheduledProcessResult(stdout: "", stderr: "", exitCode: 124,
                stdoutBytes: 0, truncated: true, captureError: nil, timedOut: true))
        } else { captured.0?.resume(throwing: CancellationError()) }
    }

    private func terminate(_ process: Int32) {
        guard process > 1 else { return }
        terminateProcess(process)
    }
}
