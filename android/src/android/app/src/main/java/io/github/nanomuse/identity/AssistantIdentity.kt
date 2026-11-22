package io.github.nanomuse.identity

/** 默认助手名称只在显示时本地化，用户设置的昵称原样保留。 */
object AssistantIdentity {
    const val DEFAULT_NAME = "Shiqi"

    /** 存储中的默认名称随界面语言显示，历史产品名不按字符串强行改名。 */
    fun displayName(storedName: String, localizedDefault: String): String {
        val name = storedName.trim()
        return if (name.isEmpty() || name == DEFAULT_NAME || name == "十七") {
            localizedDefault
        } else {
            storedName
        }
    }
}
