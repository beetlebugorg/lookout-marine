package org.beetlebug.lookout.hud

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/**
 * The chrome's palette. Deliberately NOT the system light/dark setting: the
 * chrome follows the CHART's S-52 colour scheme, so night mode doesn't blast a
 * white settings sheet at a dark-adapted helm — the same reason the engine has
 * a night palette at all. Day chrome is light, dusk and night are dark.
 *
 * Marine blues rather than Material's default purple, so the chrome reads as
 * part of the chart instead of a stock Android app bolted on top.
 */
private val DarkColors = darkColorScheme(
    primary = Color(0xFF7FB6D9),
    onPrimary = Color(0xFF00344C),
    secondary = Color(0xFFB0C9D8),
    background = Color(0xFF0B1218),
    surface = Color(0xFF121C24),
    onSurface = Color(0xFFDDE4EA),
    onSurfaceVariant = Color(0xFF9FB0BD),
    error = Color(0xFFFFB4A6),
    // The overscale red-orange, per theme — the reference's Chrome.overscale.
    tertiary = Color(0xFFF46A34),
)

private val LightColors = lightColorScheme(
    primary = Color(0xFF1C5F87),
    onPrimary = Color(0xFFFFFFFF),
    secondary = Color(0xFF4E626F),
    background = Color(0xFFF6F9FB),
    surface = Color(0xFFFFFFFF),
    onSurface = Color(0xFF161D22),
    onSurfaceVariant = Color(0xFF48606E),
    error = Color(0xFFB3261E),
    // The overscale red-orange, per theme — the reference's Chrome.overscale.
    tertiary = Color(0xFFD83B01),
)

@Composable
fun LookoutTheme(
    dark: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    MaterialTheme(
        colorScheme = if (dark) DarkColors else LightColors,
        content = content,
    )
}
