package com.openminis.app.ui.chat

import android.net.Uri
import java.util.UUID

data class InputAttachment(
    val id: String = UUID.randomUUID().toString(),
    val fileName: String,
    val uri: Uri,
    val mimeType: String,
    val kind: Kind,
    // nanoMuse: 待完成的粘贴随附件转移，发送时等待后台写入，删除不会重新插入卡片。
    val pendingPaste: io.github.nanomuse.chat.PendingPasteFile? = null,
) {
    enum class Kind { IMAGE, DOCUMENT }

    val isImage: Boolean get() = kind == Kind.IMAGE
}
