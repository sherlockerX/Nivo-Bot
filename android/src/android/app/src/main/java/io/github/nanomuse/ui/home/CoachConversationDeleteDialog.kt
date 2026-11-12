package io.github.nanomuse.ui.home

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import com.openminis.app.R
import com.openminis.app.data.repository.ChatRepository
import io.github.nanomuse.chat.SessionDeleteReport
import io.github.nanomuse.coach.CoachRuntime
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** 单删和批删共用明确范围，档案清除失败只重试清除，不重复删除会话。 */
@Composable
fun CoachConversationDeleteDialog(
    ids: Set<String>, repository: ChatRepository, onDismiss: () -> Unit,
    onDelete: ((SessionDeleteReport) -> Unit) -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val requestedIds = remember { ids.toSet() }
    val epoch = remember { CoachRuntime.epoch.value }
    // 档案读取放到IO；读取完成前和账号切换后都不能放行删除。
    val coachLookup by produceState<Result<Boolean>?>(null, context, requestedIds, epoch) {
        value = try {
            withContext(Dispatchers.IO) {
                check(epoch == CoachRuntime.epoch.value)
                val service = CoachRuntime.service(context)
                val hasLinkedCoach = requestedIds.any { service.topicForConversation(it) != null }
                check(epoch == CoachRuntime.epoch.value)
                Result.success(hasLinkedCoach)
            }
        } catch (cancelled: kotlinx.coroutines.CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            Result.failure(failure)
        }
    }
    val hasCoach = coachLookup?.getOrDefault(false) == true
    var shouldPurge by remember { mutableStateOf(false) }
    var isDeleting by remember { mutableStateOf(false) }
    var pendingPurge by remember { mutableStateOf<Set<String>>(emptySet()) }
    var failure by remember { mutableStateOf<String?>(null) }
    val failureText = stringResource(R.string.nm_coach_delete_failed)
    val accountChangedText = stringResource(R.string.nm_coach_delete_account_changed)

    fun finishDeletion(report: SessionDeleteReport) {
        scope.launch {
            try {
                check(epoch == CoachRuntime.epoch.value) { accountChangedText }
                withContext(Dispatchers.IO) { repository.cancelCoachDeletion(report.failed + report.protectedIds) }
                if (shouldPurge) {
                    pendingPurge = pendingPurge + report.deleted
                    withContext(Dispatchers.IO) { repository.purgeDeletedCoachConversations(pendingPurge) }
                    pendingPurge = emptySet()
                }
                if (report.failed.isEmpty()) onDismiss() else failure = failureText
            } catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
            catch (_: Exception) { failure = failureText }
            finally { isDeleting = false }
        }
    }

    AlertDialog(
        onDismissRequest = { if (!isDeleting) onDismiss() },
        title = { Text(stringResource(R.string.delete)) },
        text = {
            Column {
                Text(stringResource(R.string.nm_coach_delete_count, requestedIds.size))
                if (coachLookup == null) {
                    CircularProgressIndicator()
                    Text(stringResource(R.string.nm_coach_saving))
                }
                if (hasCoach) {
                    Text(stringResource(R.string.nm_coach_delete_retention))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        RadioButton(selected = !shouldPurge, enabled = !isDeleting && pendingPurge.isEmpty(),
                            onClick = { shouldPurge = false })
                        Text(stringResource(R.string.nm_coach_delete_keep))
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        RadioButton(selected = shouldPurge, enabled = !isDeleting && pendingPurge.isEmpty(),
                            onClick = { shouldPurge = true })
                        Text(stringResource(R.string.nm_coach_delete_purge))
                    }
                }
                if (coachLookup?.isFailure == true) Text(accountChangedText)
                failure?.let { Text(it) }
            }
        },
        confirmButton = {
            TextButton(enabled = !isDeleting && coachLookup?.isSuccess == true, onClick = {
                if (epoch != CoachRuntime.epoch.value) { failure = accountChangedText; return@TextButton }
                repository.attachCoachContext(context)
                isDeleting = true
                failure = null
                scope.launch {
                    try {
                        if (pendingPurge.isNotEmpty()) finishDeletion(SessionDeleteReport(emptySet(), emptySet(), emptySet()))
                        else {
                            withContext(Dispatchers.IO) { repository.prepareCoachDeletion(requestedIds, shouldPurge) }
                            check(epoch == CoachRuntime.epoch.value) { accountChangedText }
                            onDelete(::finishDeletion)
                        }
                    } catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
                    catch (_: Exception) { failure = failureText; isDeleting = false }
                }
            }) { Text(stringResource(if (pendingPurge.isEmpty()) R.string.delete else R.string.nm_coach_delete_retry)) }
        },
        dismissButton = { TextButton(enabled = !isDeleting, onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}
