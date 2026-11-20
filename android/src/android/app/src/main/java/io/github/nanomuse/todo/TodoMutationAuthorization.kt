package io.github.nanomuse.todo

import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext

/** 将宿主授权携带到实际Room事务，等待锁之后和提交之前仍能撤销旧工具写入。 */
internal class TodoMutationAuthorization(val checkAccess: suspend () -> Unit) :
    AbstractCoroutineContextElement(Key) {
    companion object Key : CoroutineContext.Key<TodoMutationAuthorization>
}
