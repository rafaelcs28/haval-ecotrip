package br.com.redesurftank.ecotrip.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import br.com.redesurftank.ecotrip.ui.theme.*

// ════════════════════════════════════════════════════════════════════════════
//  Kit visual "By Claude" — fundo néon + header com glow + glass cards.
//  Compartilhado pelas telas secundárias (Recargas/Viagens/Config), mesmo
//  idioma da home. Respeita as margens reservadas do head unit (40dp/8dp).
// ════════════════════════════════════════════════════════════════════════════

@Composable
fun ClaudeScreen(
    title: String,
    onBack: () -> Unit,
    accent: Color = NeonLime,
    spacing: Dp = 8.dp,
    headerRight: @Composable RowScope.() -> Unit = {},
    content: @Composable ColumnScope.() -> Unit,
) {
    Box(
        Modifier
            .fillMaxSize()
            .background(
                Brush.radialGradient(
                    colors = listOf(Color(0xFF0D1320), VoidBlack),
                    center = Offset(820f, 260f), radius = 1500f,
                )
            )
    ) {
        Column(
            Modifier
                .fillMaxSize()
                .systemBarsPadding()
                .padding(horizontal = 40.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(spacing),
        ) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onBack) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Voltar", tint = TextSecondary)
                }
                Text(
                    title.uppercase(),
                    fontSize = 26.sp,
                    fontWeight = FontWeight.ExtraBold,
                    color = accent,
                    letterSpacing = 2.sp,
                    style = TextStyle(shadow = Shadow(accent.copy(alpha = 0.5f), Offset.Zero, 18f)),
                )
                Spacer(Modifier.weight(1f))
                headerRight()
            }
            // Linha de gradiente viva sob o header
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(1.dp)
                    .drawBehind {
                        drawLine(
                            brush = Brush.horizontalGradient(
                                listOf(
                                    Color.Transparent,
                                    accent.copy(alpha = 0.40f),
                                    AuroraTeal.copy(alpha = 0.30f),
                                    PlasmaBlue.copy(alpha = 0.20f),
                                    Color.Transparent,
                                )
                            ),
                            start = Offset(0f, 0f),
                            end = Offset(size.width, 0f),
                            strokeWidth = 1.dp.toPx(),
                        )
                    },
            )
            content()
        }
    }
}

// Card de vidro: cantos arredondados + fundo glass + borda fina do acento.
fun Modifier.claudeCard(accent: Color = AuroraTeal, radius: Dp = 18.dp): Modifier =
    this.clip(RoundedCornerShape(radius))
        .background(GlassCard)
        .border(1.5.dp, accent.copy(alpha = 0.22f), RoundedCornerShape(radius))
