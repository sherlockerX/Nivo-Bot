package io.github.nanomuse.todo

/** 原生工具复用同一TodoStore，账号锁和Room事务始终由Store负责。 */
class TodoStoreToolStorage(private val store: TodoStore) : TodoToolStorage {
    override val ownerKey: String get() = store.ownerKey
    override suspend fun categories(): List<TodoCategory> = store.categories()
    override suspend fun categoryCommand(action:String,kind:String,name:String,expectedCreatedAt:Long?,operationId:String):String =
        store.categoryCommand(action,kind,name,expectedCreatedAt,operationId)
    override suspend fun tasks(): List<TodoTask> = store.tasks()
    override suspend fun task(id: String): TodoTask? = store.task(id)

    /** 重试读取首次保存输入，防止后续状态、时间戳导致相同更新误判为冲突。 */
    override suspend fun taskForUpdate(id: String, expectedRevision: Long, operationId: String): TodoTask? =
        store.withOwner {
            val previous = store.dao.operation(ownerKey, operationId)
            if (previous != null) TodoToolReplay.updateInput(previous.requestJson, id, expectedRevision)
            else store.dao.task(ownerKey, id)?.takeIf { it.deletedAt == null }
        }

    override suspend fun saveTask(task: TodoTask, operationId: String): TodoTask = store.saveTask(task, operationId)
    override suspend fun changeStatus(id: String, status: String, expectedRevision: Long,
        operationId: String, completedDay: Long?): TodoTask =
        store.changeStatus(id, status, expectedRevision, operationId, completedDay)
    override suspend fun deleteTask(id: String, expectedRevision: Long, operationId: String) =
        store.deleteTask(id, expectedRevision, operationId)
}
