package io.github.nanomuse.growth

import android.content.Context
import com.openminis.app.MinisApp
import io.github.nanomuse.goals.GoalStatus
import io.github.nanomuse.goals.GoalStore
import io.github.nanomuse.mosaic.MosaicDatabase
import io.github.nanomuse.sysfiles.SystemFiles
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import java.io.File
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale

/**
 * What the training draws on, counted for the settings sheet: the skill behind each ability, and
 * the knowledge the cards are made from (memory, diary, goals, habits, the folders the person
 * mounted, the growth record). Only reads; nothing here changes a file.
 */
object GrowthSources {
    /** [books] and [framework]: the course's book cards, and the length of the person's framework. */
    data class SkillRow(val track: GrowthTrack, val skillId: String, val name: String?, val description: String?, val books: Int = 0, val framework: Int = 0)
    data class Folder(val name: String, val source: String, val linuxPath: String, val available: Boolean)
    data class Snapshot(
        val skills: List<SkillRow>,
        val allSkills: Int,
        val userChars: Int,
        val globalChars: Int,
        /** Days of the last seven with the agent's daily memory file. */
        val diaryDays: Int,
        /** The person's Mosaic diary over the last seven days: entries, and the days they fall on. */
        val mosaicEntries: Int,
        val mosaicDays: Int,
        val activeGoals: Int,
        val habits: List<String>,
        val folders: List<Folder>,
        val answers: Int,
        val graded: Int,
        val recall: Int,
        val recallDue: Int,
        val principles: Int,
        val observations: Int,
    )

    suspend fun snapshot(context: Context): Snapshot = withContext(Dispatchers.IO) {
        val app = context.applicationContext as MinisApp
        val installed = runCatching { app.skillRepository.skills.value }.getOrDefault(emptyList())
        val memory = File(context.filesDir, "minis-global/memory")
        val days = SimpleDateFormat("yyyy-MM-dd", Locale.US)
        val cal = Calendar.getInstance()
        var diary = 0
        repeat(7) {
            if (File(memory, days.format(cal.time) + ".md").exists()) diary++
            cal.add(Calendar.DAY_OF_YEAR, -1)
        }
        val responses = GrowthStore.responses.value.values
        val today = java.time.LocalDate.now().toEpochDay()
        val mosaic = runCatching { MosaicDatabase.get(context).dao().observeRecordCounts(today - 6, today + 1).first() }.getOrDefault(emptyList())
        Snapshot(
            skills = GrowthStore.state.value.tracks.map { t ->
                val skill = installed.firstOrNull { it.id == t.skill }
                SkillRow(t, t.skill, skill?.name, skill?.description, GrowthStore.bookCards(t.skill).size, GrowthStore.framework(t.skill).length)
            },
            allSkills = installed.size,
            userChars = chars(SystemFiles.USER.file(context)),
            globalChars = chars(File(memory, "GLOBAL.md")),
            diaryDays = diary,
            mosaicEntries = mosaic.sumOf { it.entryCount },
            mosaicDays = mosaic.size,
            activeGoals = runCatching { GoalStore.get(context).all().count { it.status == GoalStatus.ACTIVE } }.getOrDefault(0),
            habits = runCatching { MosaicDatabase.get(context).dao().allHabits().filter { it.archivedDay == null }.map { it.title } }.getOrDefault(emptyList()),
            folders = folders(context),
            answers = responses.size,
            graded = responses.count { it.score != null },
            recall = GrowthStore.recall.value.size,
            recallDue = GrowthStore.dueRecall().size,
            principles = GrowthStore.read(GrowthStore.principlesFile()).lines().count { it.trimStart().startsWith("- ") },
            observations = GrowthStore.observationCount(),
        )
    }

    /** Folders mounted under Settings, as the sandbox sees them; one whose path did not resolve is not available. */
    fun folders(context: Context): List<Folder> = runCatching {
        (context.applicationContext as MinisApp).mountedFoldersStore.entries.value
    }.getOrDefault(emptyList()).map { Folder(it.name, it.sourceDisplayName, "/var/minis/mounts/${it.name}", it.resolvedHostPath != null) }

    private fun chars(file: File): Int = runCatching { if (file.exists()) file.readText().trim().length else 0 }.getOrDefault(0)
}
