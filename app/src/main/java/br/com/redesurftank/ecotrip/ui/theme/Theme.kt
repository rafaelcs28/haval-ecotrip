package br.com.redesurftank.ecotrip.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

val Cyan         = Color(0xFF00D4FF)
val Green        = Color(0xFF30D158)
val Blue         = Color(0xFF0A84FF)
val AccentOrange = Color(0xFFFF9500)
val AccentBlue   = Color(0xFF4A9EFF)
val SurfaceCard  = Color(0xFF13151A)
val SurfaceDeep  = Color(0xFF0A0A0A)
val TextPrimary  = Color(0xFFFFFFFF)
val TextSecondary = Color(0xFFB0B8C4)
val BorderColor  = Color(0xFF1D2430)
val Separator    = Color(0xFF2C2C2E)

private val ColorScheme = darkColorScheme(
    primary = Green,
    onPrimary = Color.White,
    background = SurfaceDeep,
    surface = SurfaceCard,
    onBackground = TextPrimary,
    onSurface = TextPrimary,
)

@Composable
fun EcotripTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = ColorScheme, content = content)
}
