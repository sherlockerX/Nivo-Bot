package io.github.nanomuse.ui.coach

import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.scale
import io.github.nanomuse.coach.CoachKind
import io.github.nanomuse.ui.home.MuseTones

/** 每种能力使用稳定场景，不随列表顺序改变，不下载图片或播放常驻动画。 */
@Composable
internal fun CoachSceneArt(kind: CoachKind, modifier: Modifier = Modifier) {
    val isDark = MuseTones.isDark
    Canvas(modifier) {
        val ink = if (isDark) Color(0xFFD4D7D5) else Color(0xFF35463F)
        val accent = when (kind) {
            CoachKind.JUDGMENT -> Color(0xFF729D83)
            CoachKind.PERSPECTIVES -> Color(0xFFAC8771)
            CoachKind.ENGLISH -> Color(0xFF7B9EB1)
            CoachKind.EXPRESSION -> Color(0xFFA38CAA)
            CoachKind.LEADERSHIP -> Color(0xFFB69B63)
            CoachKind.EXECUTION -> Color(0xFF829D8C)
            CoachKind.CUSTOM -> Color(0xFF8297AD)
        }
        // 使用统一画布比例，图形独立缩放，文字仍由Compose负责排版与无障碍。
        scale(size.width / 320f, size.height / 150f, pivot = Offset.Zero) {
            drawCircle(accent.copy(alpha = .10f), 65f, Offset(238f, 72f))
            drawOval(accent.copy(alpha = .10f), Offset(18f, 119f), Size(285f, 24f))
            when (kind) {
                CoachKind.JUDGMENT -> bamboo(ink, accent)
                CoachKind.PERSPECTIVES -> debate(ink, accent)
                CoachKind.ENGLISH -> exchange(ink, accent)
                CoachKind.EXPRESSION -> stage(ink, accent)
                CoachKind.LEADERSHIP -> workshop(ink, accent)
                CoachKind.EXECUTION -> trail(ink, accent)
                CoachKind.CUSTOM -> compass(ink, accent)
            }
        }
    }
}

/** 竹节与相互留白的竹竿表达原则、边界和持续生长。 */
private fun DrawScope.bamboo(ink: Color, accent: Color) {
    listOf(44f to 40f, 83f to 14f, 243f to 27f, 281f to 48f).forEachIndexed { index, (x, top) ->
        val color = if (index % 2 == 0) accent.copy(alpha = .6f) else accent
        drawLine(color, Offset(x, 130f), Offset(x + 8f, top), 7f, StrokeCap.Round)
        for (y in listOf(58f, 86f, 114f)) {
            drawLine(ink.copy(alpha = .35f), Offset(x - 3f, y), Offset(x + 10f, y - 1f), 1.5f)
            leaf(x + 5f, y - 3f, if (index % 2 == 0) 22f else -22f, color)
            leaf(x + 6f, y - 2f, if (index % 2 == 0) -16f else 17f, color)
        }
    }
    drawCircle(accent.copy(alpha = .13f), 23f, Offset(161f, 48f))
    drawLine(ink, Offset(121f, 121f), Offset(201f, 121f), 3f, StrokeCap.Round)
    drawLine(ink, Offset(132f, 122f), Offset(128f, 137f), 3f)
    drawLine(ink, Offset(190f, 122f), Offset(194f, 137f), 3f)
    val book = Path().apply { moveTo(139f, 105f); quadraticTo(151f, 100f, 161f, 108f); quadraticTo(172f, 100f, 184f, 105f); lineTo(183f, 119f); quadraticTo(169f, 114f, 161f, 120f); quadraticTo(150f, 114f, 139f, 118f); close() }
    drawPath(book, ink.copy(alpha = .7f))
}

private fun DrawScope.leaf(x: Float, y: Float, width: Float, color: Color) {
    drawPath(Path().apply { moveTo(x, y); quadraticTo(x + width * .3f, y - 18f, x + width, y - 21f); quadraticTo(x + width * .8f, y - 2f, x, y); close() }, color)
}

/** 两个人和相向气泡表达观点交锋，中间桌面是共同讨论的空间。 */
private fun DrawScope.debate(ink: Color, accent: Color) {
    person(73f, 59f, accent, ink)
    person(244f, 59f, accent.copy(alpha = .65f), ink)
    drawOval(accent.copy(alpha = .5f), Offset(94f, 97f), Size(134f, 29f))
    drawLine(ink, Offset(123f, 122f), Offset(117f, 142f), 3f)
    drawLine(ink, Offset(200f, 122f), Offset(206f, 142f), 3f)
    bubble(91f, 20f, 58f, accent, true)
    bubble(176f, 12f, 61f, ink.copy(alpha = .65f), false)
    drawLine(ink, Offset(111f, 88f), Offset(140f, 101f), 3f, StrokeCap.Round)
    drawLine(ink, Offset(209f, 88f), Offset(184f, 101f), 3f, StrokeCap.Round)
}

private fun DrawScope.person(x: Float, y: Float, color: Color, ink: Color) {
    drawCircle(ink, 11f, Offset(x, y))
    drawRoundRect(color, Offset(x - 18f, y + 17f), Size(36f, 45f), androidx.compose.ui.geometry.CornerRadius(14f))
    drawLine(ink, Offset(x - 10f, y + 60f), Offset(x - 14f, 140f), 3f)
    drawLine(ink, Offset(x + 10f, y + 60f), Offset(x + 14f, 140f), 3f)
}

private fun DrawScope.bubble(x: Float, y: Float, width: Float, color: Color, left: Boolean) {
    drawRoundRect(color.copy(alpha = .20f), Offset(x, y), Size(width, 29f), androidx.compose.ui.geometry.CornerRadius(10f))
    val tailX = if (left) x + 10f else x + width - 15f
    drawPath(Path().apply { moveTo(tailX, y + 24f); lineTo(tailX, y + 38f); lineTo(tailX + 12f, y + 27f); close() }, color.copy(alpha = .20f))
    repeat(3) { drawCircle(color, 2.2f, Offset(x + 17f + it * 12f, y + 14f)) }
}

/** 开放交流窗口与双语气泡，避免将语言能力误画成建筑物收藏。 */
private fun DrawScope.exchange(ink: Color, accent: Color) {
    drawRoundRect(accent.copy(alpha = .12f), Offset(45f, 20f), Size(230f, 102f), androidx.compose.ui.geometry.CornerRadius(28f))
    person(103f, 65f, accent, ink); person(215f, 65f, accent.copy(alpha = .5f), ink)
    bubble(125f, 23f, 57f, accent, true)
    drawCircle(ink.copy(alpha = .45f), 23f, Offset(257f, 54f), style = Stroke(1.8f))
    drawOval(ink.copy(alpha = .45f), Offset(247f, 31f), Size(20f, 46f), style = Stroke(1.4f))
    drawLine(ink.copy(alpha = .45f), Offset(234f, 54f), Offset(280f, 54f), 1.4f)
}

/** 发言舞台留出听众位置，强调说清楚而非背诵。 */
private fun DrawScope.stage(ink: Color, accent: Color) {
    drawOval(accent.copy(alpha = .35f), Offset(61f, 113f), Size(196f, 23f))
    person(154f, 47f, accent, ink)
    drawLine(ink, Offset(194f, 77f), Offset(194f, 119f), 2.5f)
    drawLine(ink, Offset(187f, 69f), Offset(201f, 75f), 5f, StrokeCap.Round)
    bubble(190f, 18f, 64f, accent, true)
    listOf(73f, 245f).forEach { x -> drawCircle(ink.copy(alpha = .5f), 10f, Offset(x, 117f)); drawOval(ink.copy(alpha = .25f), Offset(x - 20f, 129f), Size(40f, 18f)) }
}

/** 工作板、便签与多人协作表达共同目标和角色分工。 */
private fun DrawScope.workshop(ink: Color, accent: Color) {
    drawRoundRect(ink.copy(alpha = .12f), Offset(96f, 13f), Size(132f, 75f), androidx.compose.ui.geometry.CornerRadius(8f))
    repeat(3) { i -> drawRoundRect(accent.copy(alpha = .5f + i * .15f), Offset(111f + i * 36f, 28f), Size(26f, 22f), androidx.compose.ui.geometry.CornerRadius(3f)) }
    drawLine(ink.copy(alpha = .5f), Offset(117f, 67f), Offset(201f, 67f), 2f)
    person(68f, 70f, accent, ink); person(253f, 70f, accent.copy(alpha = .6f), ink)
    drawLine(ink, Offset(111f, 108f), Offset(218f, 108f), 5f, StrokeCap.Round)
    drawLine(ink, Offset(121f, 111f), Offset(117f, 139f), 3f)
    drawLine(ink, Offset(207f, 111f), Offset(211f, 139f), 3f)
}

/** 步道和阶段路标表示小步行动，不生成虚假的完成勋章。 */
private fun DrawScope.trail(ink: Color, accent: Color) {
    val path = Path().apply { moveTo(60f, 139f); cubicTo(67f, 97f, 221f, 107f, 196f, 68f); quadraticTo(174f, 38f, 246f, 25f) }
    drawPath(path, accent.copy(alpha = .25f), style = Stroke(20f, cap = StrokeCap.Round))
    drawPath(path, accent.copy(alpha = .6f), style = Stroke(2f, cap = StrokeCap.Round))
    listOf(92f to 111f, 171f to 91f, 211f to 42f).forEach { (x, y) -> drawCircle(ink, 4f, Offset(x,y)) }
    drawLine(ink, Offset(248f, 20f), Offset(248f, 52f), 2.5f)
    drawPath(Path().apply { moveTo(249f,20f); lineTo(275f,25f); lineTo(249f,35f); close() }, accent)
    leaf(53f,97f,22f,accent); leaf(279f,116f,-26f,accent)
}

/** 自定义课程使用罗盘与开放书页，不根据标题猜测敏感能力或心理状态。 */
private fun DrawScope.compass(ink: Color, accent: Color) {
    drawCircle(accent.copy(alpha = .18f), 49f, Offset(160f, 75f))
    drawCircle(ink.copy(alpha = .7f), 40f, Offset(160f,75f), style = Stroke(2f))
    drawPath(Path().apply { moveTo(180f,43f); lineTo(167f,81f); lineTo(140f,107f); lineTo(153f,69f); close() }, accent)
    drawCircle(ink, 4f, Offset(160f,75f))
    listOf(0f,90f,180f,270f).forEach { angle ->
        val radians = Math.toRadians(angle.toDouble())
        drawCircle(ink, 2f, Offset(160f + 49f * kotlin.math.cos(radians).toFloat(),75f + 49f * kotlin.math.sin(radians).toFloat()))
    }
}
