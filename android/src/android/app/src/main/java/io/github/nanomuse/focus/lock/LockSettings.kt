package io.github.nanomuse.focus.lock

import android.content.Context
import io.github.nanomuse.account.AccountData
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.security.MessageDigest

/** 设置按账号分开，正在锁定时不能修改退出成本。 */
class LockSettings(private val context:Context, private val store:LockStore) {
    private val preferences=context.getSharedPreferences(fileName(store.ownerKey),Context.MODE_PRIVATE)
    /** 紧急等待默认开启，等待时长固定十分钟。 */
    fun emergencyEnabled():Boolean=preferences.getBoolean("emergency-enabled",true)
    /** 默认在用户亮屏后恢复锁页，不主动点亮屏幕。 */
    fun showOnWake():Boolean=preferences.getBoolean("show-on-wake",true)
    /** 设置提交与锁定开始共用账号事务边界。 */
    suspend fun update(emergencyEnabled:Boolean,showOnWake:Boolean)=withContext(Dispatchers.IO) {
        store.transaction {
            check(store.checkpointInTransaction()==null) { "focus_locked" }
            check(preferences.edit().putBoolean("emergency-enabled",emergencyEnabled)
                .putBoolean("show-on-wake",showOnWake).commit()) { "settings_write_failed" }
        }
    }
    companion object {
        /** 哈希避免账号标识进入文件名，空键是本地账号。 */
        internal fun fileName(owner:String):String="focus-lock-"+MessageDigest.getInstance("SHA-256")
            .digest(owner.toByteArray()).joinToString("") { "%02x".format(it) }
        /** 已持账号迁移边界时清除设置与紧急等待，不影响其他账号。 */
        internal fun deleteOwner(context:Context,owner:String) {
            check(context.getSharedPreferences(fileName(owner),Context.MODE_PRIVATE).edit().clear().commit()) {
                "settings_write_failed"
            }
        }
        /** 亮屏广播只读当前账号配置，不越过存储层结束判断。 */
        fun showOnWake(context:Context):Boolean=context.getSharedPreferences(fileName(AccountData.key(context)),Context.MODE_PRIVATE)
            .getBoolean("show-on-wake",true)
    }
}
