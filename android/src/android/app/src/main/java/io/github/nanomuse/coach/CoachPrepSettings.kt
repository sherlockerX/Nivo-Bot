package io.github.nanomuse.coach

import android.content.Context
import io.github.nanomuse.account.AccountData
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** 备课子智能体的账户级设置：开课前是否备课、用哪个模型、默认训练时长。 */
object CoachPrepSettings {
    const val DEFAULT_MINUTES = 15
    val MINUTE_CHOICES = listOf(5, 10, 15, 25, 40)

    /** 一次读取的设置值；模型为空表示跟随默认模型。 */
    data class Values(val isEnabled: Boolean, val modelEntryId: String, val defaultMinutes: Int)

    private val changes = MutableStateFlow(0L)

    /** 设置写入后递增，页面据此重读。 */
    val revision: StateFlow<Long> = changes

    /** 读取当前账户的设置，没有保存过时使用默认值。 */
    fun read(context: Context): Values {
        val prefs = prefs(context)
        val minutes = prefs.getInt(KEY_MINUTES, DEFAULT_MINUTES).takeIf { it in MINUTE_CHOICES } ?: DEFAULT_MINUTES
        return Values(prefs.getBoolean(KEY_ENABLED, true), prefs.getString(KEY_MODEL, "").orEmpty(), minutes)
    }

    /** 关闭后开课直接使用课程里的基础练习，不调用模型。 */
    fun setEnabled(context: Context, isEnabled: Boolean) = write(context) { putBoolean(KEY_ENABLED, isEnabled) }

    /** 空字符串表示跟随默认模型。 */
    fun setModel(context: Context, entryId: String) = write(context) { putString(KEY_MODEL, entryId) }

    fun setDefaultMinutes(context: Context, minutes: Int) {
        require(minutes in MINUTE_CHOICES) { "Unsupported lesson length" }
        write(context) { putInt(KEY_MINUTES, minutes) }
    }

    private fun write(context: Context, change: android.content.SharedPreferences.Editor.() -> Unit) {
        prefs(context).edit().apply(change).apply()
        changes.value += 1
    }

    private fun prefs(context: Context) = context.applicationContext.getSharedPreferences(
        "coach-prep-${AccountData.key(context.applicationContext).hashCode()}", 0)

    private const val KEY_ENABLED = "enabled"
    private const val KEY_MODEL = "model_entry"
    private const val KEY_MINUTES = "default_minutes"
}
