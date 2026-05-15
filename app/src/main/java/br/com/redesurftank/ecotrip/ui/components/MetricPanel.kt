package br.com.redesurftank.ecotrip.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import br.com.redesurftank.ecotrip.ui.theme.AuroraTeal
import br.com.redesurftank.ecotrip.ui.theme.MoltenOrange
import br.com.redesurftank.ecotrip.ui.theme.NeonLime
import br.com.redesurftank.ecotrip.ui.theme.TextPrimary
import br.com.redesurftank.ecotrip.ui.theme.TextSecondary
import br.com.redesurftank.ecotrip.ui.theme.WarnYellow
import kotlinx.coroutines.delay

// ── Bloco vertical (label tiny + valor grande, opcional aux à direita + content extra) ──

@Composable
fun MetricBlock(
    label: String,
    value: String,
    valueColor: Color = TextPrimary,
    auxRight: String? = null,
    auxColor: Color = TextSecondary,
    unitInline: String? = null,
    showBottomBorder: Boolean = true,
    modifier: Modifier = Modifier,
    content: @Composable (() -> Unit)? = null,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(top = 6.dp, bottom = 5.dp)
            .then(
                if (showBottomBorder) Modifier.drawBehind {
                    drawLine(
                        color = Color.White.copy(alpha = 0.025f),
                        start = Offset(0f, size.height),
                        end = Offset(size.width, size.height),
                        strokeWidth = 1f,
                    )
                } else Modifier,
            ),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.Bottom,
        ) {
            Text(
                text = label.uppercase(),
                fontSize = 9.5.sp,
                fontWeight = FontWeight.Bold,
                letterSpacing = 1.4.sp,
                color = TextSecondary.copy(alpha = 0.78f),
            )
            if (auxRight != null) {
                Text(
                    text = auxRight,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = auxColor,
                    letterSpacing = 0.3.sp,
                )
            }
        }
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(
                text = value,
                fontSize = 22.sp,
                fontWeight = FontWeight.ExtraBold,
                color = valueColor,
                maxLines = 1,
                letterSpacing = (-0.4).sp,
            )
            if (unitInline != null) {
                Text(
                    text = unitInline,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Medium,
                    color = TextSecondary,
                    modifier = Modifier.padding(bottom = 2.dp),
                    maxLines = 1,
                )
            }
        }
        if (content != null) content()
    }
}

/** Mini-bar (Regen %, Tanque %, etc.). */
@Composable
fun MiniBar(
    fraction: Float,
    fillBrush: Brush,
    modifier: Modifier = Modifier,
    height: Dp = 3.dp,
) {
    val f = fraction.coerceIn(0f, 1f)
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(height)
            .background(Color.White.copy(alpha = 0.05f), RoundedCornerShape(2.dp)),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth(f)
                .fillMaxHeight()
                .background(fillBrush, RoundedCornerShape(2.dp)),
        )
    }
}

// ── Status badge (ECO/ATENÇÃO/ALTO) ───────────────────────────────────────────
@Composable
fun StatusBadge(
    label: String,
    color: Color,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .background(color.copy(alpha = 0.10f), RoundedCornerShape(4.dp))
            .border(1.dp, color.copy(alpha = 0.35f), RoundedCornerShape(4.dp))
            .padding(horizontal = 7.dp, vertical = 2.dp),
    ) {
        Text(
            text = label,
            fontSize = 9.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = 0.6.sp,
            color = color,
        )
    }
}

// ── Bullet bar (Custo por km vs meta) ─────────────────────────────────────────
/**
 * Barra com 3 zonas coloridas pintadas no fundo + marcador vertical branco no valor.
 * - metaPosition: limite verde→amarelo
 * - yellowEnd: limite amarelo→laranja (default = 1.5× meta)
 */
@Composable
fun BulletBar(
    value: Float,
    maxScale: Float,
    metaPosition: Float,
    yellowEnd: Float = metaPosition * 1.5f,
    modifier: Modifier = Modifier,
) {
    val metaFrac   = (metaPosition / maxScale).coerceIn(0f, 1f)
    val yellowFrac = (yellowEnd / maxScale).coerceIn(0f, 1f)
    val markerFrac = (value / maxScale).coerceIn(0f, 1f)

    BoxWithConstraints(
        modifier = modifier
            .fillMaxWidth()
            .height(6.dp),
    ) {
        val totalW = maxWidth
        // Background com 3 zonas
        Box(
            modifier = Modifier
                .fillMaxSize()
                .border(0.5.dp, Color.Black.copy(alpha = 0.5f), RoundedCornerShape(3.dp))
                .drawBehind {
                    val w = size.width
                    drawRect(
                        color = NeonLime.copy(alpha = 0.30f),
                        topLeft = Offset(0f, 0f),
                        size = Size(w * metaFrac, size.height),
                    )
                    drawRect(
                        color = WarnYellow.copy(alpha = 0.30f),
                        topLeft = Offset(w * metaFrac, 0f),
                        size = Size(w * (yellowFrac - metaFrac), size.height),
                    )
                    drawRect(
                        color = MoltenOrange.copy(alpha = 0.30f),
                        topLeft = Offset(w * yellowFrac, 0f),
                        size = Size(w * (1f - yellowFrac), size.height),
                    )
                    drawLine(
                        color = Color.White.copy(alpha = 0.18f),
                        start = Offset(w * metaFrac, 0f),
                        end = Offset(w * metaFrac, size.height),
                        strokeWidth = 1f,
                    )
                    drawLine(
                        color = Color.White.copy(alpha = 0.12f),
                        start = Offset(w * yellowFrac, 0f),
                        end = Offset(w * yellowFrac, size.height),
                        strokeWidth = 1f,
                    )
                },
        )
        // Marcador vertical branco
        Box(
            modifier = Modifier
                .offset(x = totalW * markerFrac - 1.5.dp, y = (-3).dp)
                .width(3.dp)
                .height(12.dp)
                .background(TextPrimary),
        )
    }
}

// ── SOC bar do strip ──────────────────────────────────────────────────────────
/**
 * Barra horizontal mostrando:
 *  - fill bright (0% → currentSocPct): bateria atual
 *  - área "consumida" hachurada (currentSocPct → startSocPct): SOC gasto na viagem
 *  - marcador vertical amarelo no startSocPct
 *  - pulse de glow no fill bright (vida)
 *
 * Quando startSocPct ≤ currentSocPct (recarregou durante o trip), só mostra fill.
 */
@Composable
fun SocStripBar(
    startSocPct: Float,
    currentSocPct: Float,
    modifier: Modifier = Modifier,
) {
    val startFrac   = (startSocPct / 100f).coerceIn(0f, 1f)
    val currentFrac = (currentSocPct / 100f).coerceIn(0f, 1f)
    val showConsumed = startFrac > currentFrac + 0.001f

    var pulseAlpha by remember { mutableFloatStateOf(1f) }
    LaunchedEffect(Unit) {
        while (true) {
            pulseAlpha = 1f
            delay(1200)
            pulseAlpha = 0.78f
            delay(1200)
        }
    }

    BoxWithConstraints(
        modifier = modifier
            .fillMaxWidth()
            .height(8.dp)
            .background(Color.White.copy(alpha = 0.05f), RoundedCornerShape(4.dp))
            .border(0.5.dp, Color.Black.copy(alpha = 0.4f), RoundedCornerShape(4.dp)),
    ) {
        val totalW = maxWidth

        // 1) Fill bright 0..current — gradient teal→lime com pulse
        Box(
            modifier = Modifier
                .fillMaxWidth(currentFrac)
                .fillMaxHeight()
                .background(
                    brush = Brush.horizontalGradient(listOf(AuroraTeal, NeonLime)),
                    shape = RoundedCornerShape(4.dp),
                ),
        )

        // 2) Área "consumida" hachurada (current..start) — só se start > current
        if (showConsumed) {
            val consumedFrac = startFrac - currentFrac
            Box(
                modifier = Modifier
                    .offset(x = totalW * currentFrac)
                    .fillMaxHeight()
                    .width(totalW * consumedFrac)
                    .background(AuroraTeal.copy(alpha = 0.18f), RoundedCornerShape(2.dp)),
            )
        }

        // 3) Marcador vertical amarelo no startSocPct
        if (showConsumed) {
            Box(
                modifier = Modifier
                    .offset(x = totalW * startFrac - 1.dp, y = (-3).dp)
                    .width(2.dp)
                    .height(14.dp)
                    .background(WarnYellow),
            )
        }
    }
}
