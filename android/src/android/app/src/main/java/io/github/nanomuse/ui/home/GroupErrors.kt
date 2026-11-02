package io.github.nanomuse.ui.home

import android.content.Context
import com.openminis.app.R
import io.github.nanomuse.chat.GroupNameException

/** 将服务层分组错误映射为统一的本地化提示。 */
fun groupError(context: Context, error: Exception): String = context.getString(when ((error as? GroupNameException)?.code) {
    "GROUP_NAME_EXISTS" -> R.string.nm_group_name_exists
    "GROUP_NAME_RESERVED" -> R.string.nm_group_name_reserved
    "GROUP_SYSTEM_PROTECTED" -> R.string.nm_group_protected
    else -> R.string.nm_group_name_invalid
})
