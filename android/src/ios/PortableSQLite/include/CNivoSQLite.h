#pragma once

/* 可移植回归使用系统SQLite，应用目标继续使用Apple SDK的SQLite3模块。 */
#ifdef _WIN32
#include <winsqlite/winsqlite3.h>
#else
#include <sqlite3.h>
#endif
