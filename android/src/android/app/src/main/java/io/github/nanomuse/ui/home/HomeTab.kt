package io.github.nanomuse.ui.home

import androidx.annotation.StringRes
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Category
import androidx.compose.material.icons.filled.ChatBubble
import androidx.compose.material.icons.filled.CheckBox
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Lightbulb
import androidx.compose.material.icons.filled.School
import androidx.compose.material.icons.outlined.Category
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.CheckBox
import androidx.compose.material.icons.outlined.GridView
import androidx.compose.material.icons.outlined.Lightbulb
import androidx.compose.material.icons.outlined.School
import androidx.compose.ui.graphics.vector.ImageVector
import com.openminis.app.R

/**
 * The bottom bar: chat, Mosaic, coach (Muse's feed, turned into training), goals, library. Icons are outlined at rest and filled when
 * selected, no labels — the bar reads as glyphs, the way Muse draws it. Ideas is a page of the
 * home without a place in the bar ([inBar] false): the drawer opens it.
 */
enum class HomeTab(
    @StringRes val label: Int,
    val icon: ImageVector,
    val selectedIcon: ImageVector,
    val inBar: Boolean = true,
) {
    CHAT(R.string.nm_tab_chat, Icons.Outlined.ChatBubbleOutline, Icons.Filled.ChatBubble),
    MOSAIC(R.string.nm_tab_mosaic, Icons.Outlined.GridView, Icons.Filled.GridView),
    FEED(R.string.nm_tab_coach, Icons.Outlined.School, Icons.Filled.School), // Mosaic: the Coach tab
    GOALS(R.string.nm_tab_goals, Icons.Outlined.CheckBox, Icons.Filled.CheckBox),
    LIBRARY(R.string.nm_tab_library, Icons.Outlined.Category, Icons.Filled.Category),
    IDEAS(R.string.nm_tab_ideas, Icons.Outlined.Lightbulb, Icons.Filled.Lightbulb, inBar = false),
}
