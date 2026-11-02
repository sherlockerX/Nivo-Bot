package io.github.nanomuse.avatar

import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import io.github.nanomuse.ui.avatar.AgentMood
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.io.File

/**
 * Mosaic: the pets the person has had. A face made in the studio or in the chat is put away
 * whole when another takes its place (its picture, its poses and its clips, under
 * `avatar/pets/<id>/`), so switching back costs no new pictures or clips. The face in use lives
 * in the avatar folder as before and nowhere else; putting it away and taking another out are
 * renames, so a switch, or picking a new face, never copies megabytes of clips on the way. The
 * built-in dragon is always there.
 */
object AvatarWardrobe {
    const val DRAGON = "dragon"

    /** A pet put away: its picture and the words it was made from. */
    data class Pet(val id: String, val face: ImageBitmap, val prompt: String)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val _pets = MutableStateFlow<List<Pet>>(emptyList())
    /** The pets put away, newest first; never the one in use. */
    val pets: StateFlow<List<Pet>> = _pets

    private fun dir(): File = File(AvatarStore.root(), "pets").apply { mkdirs() }

    /** The id of the face in use: the dragon, or the moment the custom face was made. */
    fun currentId(): String = idOf(AvatarStore.current.value)

    fun idOf(face: AvatarSet?): String = face?.let { "pet-${it.createdAt}" } ?: DRAGON

    fun init() = rescan()

    /** Reads the pets put away, off the main thread (each is a picture to decode). */
    fun rescan() {
        scope.launch {
            _pets.value = dir().listFiles().orEmpty()
                .filter { it.isDirectory }
                .mapNotNull { d -> AvatarStore.decodeBitmap(File(d, "base.png"))?.let { Pet(d.name, it.asImageBitmap(), promptOf(d)) } }
                .sortedByDescending { it.id }
        }
    }

    private fun promptOf(d: File): String =
        runCatching { JSONObject(File(d, "avatar.json").readText()).optString("prompt") }.getOrDefault("")

    /**
     * Puts the face in use away, when it is a custom one, so it can be worn again; the avatar
     * folder is left without it. Called right before a new face, the dragon or another pet
     * takes its place. Returns its id, or null for the dragon.
     */
    @Synchronized
    fun keepCurrent(): String? {
        val id = currentId().takeIf { it != DRAGON } ?: return null
        val target = File(dir(), id)
        // 重复归档时根目录可能已经为空，不得先删除唯一的存档。
        if (!AvatarStore.baseFile().exists()) return id
        target.mkdirs()
        AvatarStore.faceFiles().filter { it.exists() }.forEach { move(it, File(target, it.name)) }
        val motion = File(target, MOTION).apply { mkdirs() }
        AgentMood.entries.map(AvatarMotion::clipFile)
            .filter { it.exists() && it.length() > 0 }
            .forEach { move(it, File(motion, it.name)) }
        rescan()
        return id
    }

    /** Puts on [id]: the face in use is put away first, then the pet's files take its place. Run off the main thread. */
    @Synchronized
    fun wear(id: String) {
        if (id == currentId()) return
        if (id != DRAGON && !File(dir(), "$id/base.png").exists()) return
        keepCurrent()
        if (id == DRAGON) {
            AvatarStore.reset()
            return
        }
        val source = File(dir(), id)
        AvatarStore.faceFiles().forEach { it.delete() }
        AvatarMotion.clear()
        source.listFiles().orEmpty().filter { it.isFile }.forEach { move(it, File(AvatarStore.root(), it.name)) }
        val motion = File(source, MOTION)
        AgentMood.entries.forEach { mood ->
            val clip = AvatarMotion.clipFile(mood)
            File(motion, clip.name).takeIf { it.exists() }?.let { move(it, clip) }
        }
        source.deleteRecursively()
        AvatarStore.reload()
        AvatarMotion.rescan()
        rescan()
    }

    /** Forgets a pet that is put away. */
    @Synchronized
    fun remove(id: String) {
        if (id == DRAGON || id == currentId()) return
        File(dir(), id).deleteRecursively()
        rescan()
    }

    /** A rename inside the avatar folder; a copy only if the rename is refused. */
    private fun move(from: File, to: File) {
        to.delete()
        if (!from.renameTo(to)) {
            from.copyTo(to, overwrite = true)
            from.delete()
        }
    }

    private const val MOTION = "motion"
}
