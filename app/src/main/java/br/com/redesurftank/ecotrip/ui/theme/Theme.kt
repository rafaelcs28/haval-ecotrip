package br.com.redesurftank.ecotrip.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

val NeonLime      = Color(0xFF39FF88)   // néon principal
val Green         = NeonLime            // alias de compatibilidade
val AuroraTeal    = Color(0xFF00E5CC)
val Cyan          = AuroraTeal          // alias de compatibilidade
val MoltenOrange  = Color(0xFFFF5F1F)
val AccentOrange  = MoltenOrange        // alias
val PlasmaBlue    = Color(0xFF4DBBFF)
val AccentBlue    = PlasmaBlue          // alias
val Blue          = PlasmaBlue          // alias
val VoidBlack     = Color(0xFF06080C)
val SurfaceDeep   = VoidBlack           // alias
val GlassCard     = Color(0xFF0C1019)
val SurfaceCard   = GlassCard          // alias
val TextPrimary   = Color(0xFFEEF4FF)   // branco frio levemente azulado
val TextSecondary = Color(0xFF5B7394)   // mais discreto
val BorderColor   = Color(0xFF0F1520)
val Separator     = Color(0xFF0F1520)
val WarnYellow    = Color(0xFFFFD60A)
val DangerRed     = Color(0xFFFF4444)   // zona vermelha em gauges de performance

private val ColorScheme = darkColorScheme(
    primary      = NeonLime,
    onPrimary    = Color.White,
    background   = VoidBlack,
    surface      = GlassCard,
    onBackground = TextPrimary,
    onSurface    = TextPrimary,
)

@Composable
fun EcotripTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = ColorScheme, content = content)
}
