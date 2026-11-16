#include <assert.h>
#include <stdio.h>
#include "../../android/src/ios/NanoMuse/NivoShellBytes.h"

/// 对生产UTF-8边界函数使用真实字节，覆盖分包、截断和无效序列。
static void should_preserve_complete_scalars(void) {
    const uint8_t text[] = { 'A', 0xE4, 0xBD, 0xA0, 0xF0, 0x9F, 0x98, 0x80, '\n' };
    const size_t expected[] = { 0, 1, 1, 1, 4, 4, 4, 4, 8, 9 };
    for (size_t length = 0; length <= sizeof(text); length++) {
        bool invalid = true;
        assert(nivo_shell_utf8_prefix(text, length, &invalid) == expected[length]);
        assert(!invalid);
    }
}

/// Unicode代理区、过长编码、超过U+10FFFF和单独的续字节均不能进入有效前缀。
static void should_reject_invalid_sequences(void) {
    const uint8_t invalid_sequences[][4] = {
        { 0xC0, 0x80, 0, 0 }, { 0xED, 0xA0, 0x80, 0 },
        { 0xE0, 0x80, 0x80, 0 }, { 0xF4, 0x90, 0x80, 0x80 },
        { 0x80, 0, 0, 0 }, { 0xF0, 0x80, 0x80, 0x80 },
        { 0xE4, 'x', 0xA0, 0 }
    };
    for (size_t index = 0; index < sizeof(invalid_sequences) / sizeof(invalid_sequences[0]); index++) {
        bool invalid = false;
        assert(nivo_shell_utf8_prefix(invalid_sequences[index], 4, &invalid) == 0);
        assert(invalid);
    }
}

/// 独立入口只验证可移植C函数，不代替Objective-C或iSH的应用集成测试。
int main(void) {
    should_preserve_complete_scalars();
    should_reject_invalid_sequences();
    assert(nivo_shell_exit_code(0) == 0);
    assert(nivo_shell_exit_code(1 << 8) == 1);
    assert(nivo_shell_exit_code(126 << 8) == 126);
    assert(nivo_shell_exit_code(127 << 8) == 127);
    assert(nivo_shell_exit_code(9) == 137);
    assert(nivo_shell_exit_code(11 | 0x80) == 139);
    puts("NivoShellBytes: 23 UTF-8 boundary and exit-status cases passed.");
    return 0;
}
