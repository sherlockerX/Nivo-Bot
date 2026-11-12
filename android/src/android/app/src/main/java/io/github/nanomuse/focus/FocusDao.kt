package io.github.nanomuse.focus

import androidx.room.*
import kotlinx.coroutines.flow.Flow

/** 所有专注查询显式限制账号。 */
@Dao
interface FocusDao {
    @Query("SELECT * FROM focus_sessions WHERE ownerKey = :owner AND deletedAt IS NULL ORDER BY startedAt DESC, id")
    fun observe(owner: String): Flow<List<FocusSession>>
    @Query("SELECT * FROM focus_sessions WHERE ownerKey = :owner AND deletedAt IS NULL ORDER BY startedAt DESC, id")
    suspend fun sessions(owner: String): List<FocusSession>
    @Query("SELECT * FROM focus_sessions WHERE ownerKey = :owner AND id = :id")
    suspend fun session(owner: String, id: String): FocusSession?
    @Query("SELECT * FROM focus_sessions WHERE ownerKey = :owner AND deletedAt IS NULL AND status IN ('running','paused') LIMIT 1")
    suspend fun active(owner: String): FocusSession?
    @Upsert suspend fun putSession(session: FocusSession)
    @Insert suspend fun putSpan(span: FocusSpan)
    @Query("SELECT * FROM focus_spans WHERE ownerKey=:owner ORDER BY startedAt")
    suspend fun allSpans(owner: String): List<FocusSpan>
    @Query("SELECT p.* FROM focus_spans p INNER JOIN focus_sessions s ON p.ownerKey=s.ownerKey AND p.sessionId=s.id WHERE p.ownerKey=:owner AND s.deletedAt IS NULL AND s.status='finished' AND s.mode!='break' ORDER BY p.startedAt")
    suspend fun spans(owner: String): List<FocusSpan>
    @Query("SELECT * FROM focus_operations WHERE ownerKey=:owner AND id=:id")
    suspend fun operation(owner: String, id: String): FocusOperation?
    @Insert suspend fun putOperation(operation: FocusOperation)
    @Query("SELECT * FROM focus_entry_links WHERE ownerKey=:owner AND entryId=:entryId ORDER BY startedAt")
    suspend fun entryLinks(owner: String, entryId: String): List<FocusEntryLink>
    @Query("SELECT * FROM focus_entry_links WHERE ownerKey=:owner AND entryId=:entryId ORDER BY startedAt")
    fun observeEntryLinks(owner: String, entryId: String): Flow<List<FocusEntryLink>>
    @Query("SELECT * FROM focus_draft_links WHERE ownerKey=:owner AND draftId=:draftId")
    suspend fun draftLinks(owner: String, draftId: String): List<FocusDraftLink>
    @Query("DELETE FROM focus_entry_links WHERE ownerKey=:owner AND entryId=:entryId")
    suspend fun clearEntryLinks(owner: String, entryId: String)
    @Query("DELETE FROM focus_draft_links WHERE ownerKey=:owner AND draftId=:draftId")
    suspend fun clearDraftLinks(owner: String, draftId: String)
    @Upsert suspend fun putEntryLinks(links: List<FocusEntryLink>)
    @Upsert suspend fun putDraftLinks(links: List<FocusDraftLink>)
    @Query("DELETE FROM focus_draft_links WHERE draftId=:id") suspend fun discardDraft(id: String)
    @Query("UPDATE focus_draft_links SET draftId=:newId WHERE draftId=:oldId") suspend fun redateDraft(oldId: String, newId: String)
    @Query("DELETE FROM focus_entry_links WHERE entryId NOT IN (SELECT id FROM entries)") suspend fun purgeOrphans()
    @Query("DELETE FROM focus_sessions WHERE ownerKey=:owner") suspend fun deleteSessions(owner: String)
    @Query("DELETE FROM focus_spans WHERE ownerKey=:owner") suspend fun deleteSpans(owner: String)
    @Query("DELETE FROM focus_operations WHERE ownerKey=:owner") suspend fun deleteOperations(owner: String)
    @Query("DELETE FROM focus_entry_links WHERE ownerKey=:owner") suspend fun deleteLinks(owner: String)
    @Query("DELETE FROM focus_draft_links WHERE ownerKey=:owner") suspend fun deleteDrafts(owner: String)
}
