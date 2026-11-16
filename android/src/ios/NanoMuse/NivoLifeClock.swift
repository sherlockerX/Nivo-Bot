import Foundation
import Darwin

/// 使用包含休眠的单调时钟和系统开机标识，校时不影响专注时长。
enum NivoLifeClock {
    private static let fallbackBootID = UUID().uuidString

    /// 系统开机时间稳定标识一次启动；无法读取时保守地限制为本次进程。
    static func sample() -> NivoFocusClockSample {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = mach_continuous_time()
        let milliseconds = Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        let result = sysctlbyname("kern.boottime", &boot, &size, nil, 0)
        let bootID = result == 0 ? "\(boot.tv_sec):\(boot.tv_usec)" : fallbackBootID
        return NivoFocusClockSample(
            wallMs: Int64(Date().timeIntervalSince1970 * 1_000),
            elapsedMs: Int64(milliseconds), bootID: bootID
        )
    }
}
