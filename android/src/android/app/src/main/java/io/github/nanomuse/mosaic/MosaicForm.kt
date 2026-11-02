package io.github.nanomuse.mosaic

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/** One cloud's place in a day's shape, in units of a cloud's width; y grows downwards. */
data class MosaicSlot(val x: Float, val y: Float)

/**
 * The shape a day's records make: clouds laid out as a heart, a diamond, a flower and so on. Each
 * shape has a [small] layout for an ordinary day and a [large] one for a full day. A day's records
 * and planned habits fill the places in order; the places left show as empty clouds, so a new day
 * opens as an outline waiting to be filled. [id] is what `days.form` stores.
 */
enum class MosaicForm(val id: String, val small: List<MosaicSlot>, val large: List<MosaicSlot>) {
    HEART(
        "heart",
        hexRows(xs(-1f, 1f), xs(-1.5f, -0.5f, 0.5f, 1.5f), xs(-1f, 0f, 1f), xs(-0.5f, 0.5f), xs(0f)),
        hexRows(
            xs(-2f, -1f, 1f, 2f), xs(-2.5f, -1.5f, -0.5f, 0.5f, 1.5f, 2.5f), xs(-2f, -1f, 0f, 1f, 2f),
            xs(-1.5f, -0.5f, 0.5f, 1.5f), xs(-1f, 0f, 1f), xs(-0.5f, 0.5f), xs(0f),
        ),
    ),
    DIAMOND(
        "diamond",
        hexRows(xs(0f), xs(-0.5f, 0.5f), xs(-1f, 0f, 1f), xs(-0.5f, 0.5f), xs(0f)),
        hexRows(xs(0f), xs(-0.5f, 0.5f), xs(-1f, 0f, 1f), xs(-1.5f, -0.5f, 0.5f, 1.5f), xs(-1f, 0f, 1f), xs(-0.5f, 0.5f), xs(0f)),
    ),
    FLOWER(
        "flower",
        listOf(MosaicSlot(0f, 0f)) + ring(6, 1.25f),
        listOf(MosaicSlot(0f, 0f)) + ring(6, 1.1f) + ring(12, 2.2f),
    ),
    TRIANGLE(
        "triangle",
        hexRows(xs(0f), xs(-0.5f, 0.5f), xs(-1f, 0f, 1f), xs(-1.5f, -0.5f, 0.5f, 1.5f)),
        hexRows(
            xs(0f), xs(-0.5f, 0.5f), xs(-1f, 0f, 1f), xs(-1.5f, -0.5f, 0.5f, 1.5f),
            xs(-2f, -1f, 0f, 1f, 2f), xs(-2.5f, -1.5f, -0.5f, 0.5f, 1.5f, 2.5f),
        ),
    ),
    RING("ring", ring(8, 1.41f), ring(16, 2.77f)),
    STAR(
        "star",
        listOf(MosaicSlot(0f, 0f)) + ring(5, 1f) + ring(5, 2f),
        listOf(MosaicSlot(0f, 0f)) + ring(5, 1f) + ring(5, 1.6f, offsetDegrees = 36.0) + ring(5, 2f) + ring(5, 3f),
    ),
    JIGSAW(
        "jigsaw",
        points(0f to -2f, -1f to -1f, 0f to -1f, 1f to -1f, -1f to 0f, 0f to 0f, 1f to 0f, 2f to 0f, -1f to 1f, 0f to 1f, 1f to 1f),
        points(
            0f to -2.5f, -1.5f to -1.5f, -0.5f to -1.5f, 0.5f to -1.5f, 1.5f to -1.5f,
            -1.5f to -0.5f, -0.5f to -0.5f, 0.5f to -0.5f, 1.5f to -0.5f, 2.5f to 0f,
            -1.5f to 0.5f, -0.5f to 0.5f, 0.5f to 0.5f, 1.5f to 0.5f,
            -1.5f to 1.5f, -0.5f to 1.5f, 0.5f to 1.5f, 1.5f to 1.5f,
        ),
    ),
    CROSS(
        "cross",
        points(0f to -2f, 0f to -1f, -2f to 0f, -1f to 0f, 0f to 0f, 1f to 0f, 2f to 0f, 0f to 1f, 0f to 2f),
        points(
            0f to -4f, 0f to -3f, 0f to -2f, 0f to -1f,
            -4f to 0f, -3f to 0f, -2f to 0f, -1f to 0f, 0f to 0f, 1f to 0f, 2f to 0f, 3f to 0f, 4f to 0f,
            0f to 1f, 0f to 2f, 0f to 3f, 0f to 4f,
        ),
    ),
    ;

    /** The layout for [count] pieces: the small one while it holds them, else the large one. */
    fun slots(count: Int): List<MosaicSlot> = if (count <= small.size) small else large

    companion object {
        /** A stored id, or null for an unknown one (a newer version's shape) so the day falls back to [auto]. */
        fun of(id: String?): MosaicForm? = entries.firstOrNull { it.id == id }

        /**
         * The shape a day gets when the person has not picked one: every eight days go through all
         * eight shapes in an order shuffled from the date, and a day never repeats the day before.
         * Past days must keep their shape, so [ROTATION] and the shuffle never change; a new shape
         * joins the enum without joining the rotation.
         */
        fun auto(day: Long): MosaicForm {
            val block = Math.floorDiv(day, ROTATION.size.toLong())
            val order = blockOrder(block)
            if (order[0] == blockOrder(block - 1).last()) {
                val first = order[0]
                order[0] = order[1]
                order[1] = first
            }
            return ROTATION[order[Math.floorMod(day, ROTATION.size.toLong()).toInt()]]
        }

        private val ROTATION = listOf(HEART, DIAMOND, FLOWER, TRIANGLE, RING, STAR, JIGSAW, CROSS)

        /** A Fisher-Yates shuffle of the rotation for one block of days, driven by SplitMix64 from the block number. */
        private fun blockOrder(block: Long): IntArray {
            val order = IntArray(ROTATION.size) { it }
            var state = block
            for (i in order.lastIndex downTo 1) {
                state += GOLDEN
                var z = state
                z = (z xor (z ushr 30)) * MIX_1
                z = (z xor (z ushr 27)) * MIX_2
                z = z xor (z ushr 31)
                val j = ((z ushr 1) % (i + 1)).toInt()
                val swap = order[i]
                order[i] = order[j]
                order[j] = swap
            }
            return order
        }

        // SplitMix64's constants (0x9E3779B97F4A7C15, 0xBF58476D1CE4E5B9, 0x94D049BB133111EB) as signed longs.
        private const val GOLDEN = -7046029254386353131L
        private const val MIX_1 = -4658895280553007687L
        private const val MIX_2 = -7723592293110705685L
    }
}

/** Rows of a hexagonal packing, top row first; neighbours in a row are one cloud apart. */
private fun hexRows(vararg rows: FloatArray): List<MosaicSlot> =
    rows.flatMapIndexed { r, row -> row.map { MosaicSlot(it, r * HEX_ROW) } }

private fun xs(vararg values: Float): FloatArray = values

private fun points(vararg values: Pair<Float, Float>): List<MosaicSlot> = values.map { (x, y) -> MosaicSlot(x, y) }

/** [count] clouds on a circle of [radius], the first at the top (turned by [offsetDegrees]), going clockwise. */
private fun ring(count: Int, radius: Float, offsetDegrees: Double = 0.0): List<MosaicSlot> = List(count) { i ->
    val a = -PI / 2 + Math.toRadians(offsetDegrees) + 2 * PI * i / count
    MosaicSlot((radius * cos(a)).toFloat(), (radius * sin(a)).toFloat())
}

private const val HEX_ROW = 0.866f
