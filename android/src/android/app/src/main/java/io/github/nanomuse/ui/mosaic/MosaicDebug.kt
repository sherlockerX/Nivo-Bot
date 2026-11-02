package io.github.nanomuse.ui.mosaic

import android.content.Context
import com.openminis.app.BuildConfig

/**
 * Debug builds only: open the home with no account and no key, so the Mosaic tab can be tried
 * before the first-run work (the local records not needing a model) is done. A release build
 * never skips the setup, whatever the preference holds.
 */
object MosaicDebug {
    fun setupSkipped(context: Context): Boolean = BuildConfig.DEBUG && prefs(context).getBoolean(KEY_SKIP_SETUP, false)

    fun skipSetup(context: Context) {
        if (BuildConfig.DEBUG) prefs(context).edit().putBoolean(KEY_SKIP_SETUP, true).apply()
    }

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private const val PREFS = "nm_mosaic"
    private const val KEY_SKIP_SETUP = "debug_skip_setup"
}
