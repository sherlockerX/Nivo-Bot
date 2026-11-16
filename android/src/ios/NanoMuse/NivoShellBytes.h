#ifndef NIVO_SHELL_BYTES_H
#define NIVO_SHELL_BYTES_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/// Linux等待状态转换为可见退出码，信号结束沿用shell的128加信号编号约定。
static inline int nivo_shell_exit_code(int status) {
    int signal = status & 0x7F;
    return signal == 0 ? ((status >> 8) & 0xFF) : 128 + signal;
}

/// 严格校验一个完整UTF-8标量，拒绝过长编码、代理区和超出Unicode范围的值。
static inline bool nivo_shell_valid_scalar(const uint8_t *bytes, size_t count) {
    for (size_t offset = 1; offset < count; offset++) {
        if ((bytes[offset] & 0xC0) != 0x80) return false;
    }
    if (count == 3 && bytes[0] == 0xE0 && bytes[1] < 0xA0) return false;
    if (count == 3 && bytes[0] == 0xED && bytes[1] >= 0xA0) return false;
    if (count == 4 && bytes[0] == 0xF0 && bytes[1] < 0x90) return false;
    if (count == 4 && bytes[0] == 0xF4 && bytes[1] > 0x8F) return false;
    return true;
}

/// 返回已完整且有效的前缀；末尾缺字节不算无效，留给下一批输入继续拼接。
static inline size_t nivo_shell_utf8_prefix(const uint8_t *bytes, size_t length, bool *is_invalid) {
    size_t offset = 0;
    *is_invalid = false;
    while (offset < length) {
        uint8_t lead = bytes[offset];
        size_t count = 0;
        if (lead <= 0x7F) count = 1;
        else if (lead >= 0xC2 && lead <= 0xDF) count = 2;
        else if (lead >= 0xE0 && lead <= 0xEF) count = 3;
        else if (lead >= 0xF0 && lead <= 0xF4) count = 4;
        if (count == 0) { *is_invalid = true; break; }
        if (length - offset < count) break;
        if (!nivo_shell_valid_scalar(bytes + offset, count)) { *is_invalid = true; break; }
        offset += count;
    }
    return offset;
}

#endif
