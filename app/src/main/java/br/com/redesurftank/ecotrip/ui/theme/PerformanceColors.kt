package br.com.redesurftank.ecotrip.ui.theme

import androidx.compose.ui.graphics.Color

// ── Cores de performance por threshold ────────────────────────────────────────
// Regras definidas pelo usuário em 2026-05-15:
//   kWh/100km : ≤20 lime · ≤25 yellow · ≤30 orange · >30 red
//   km/L econ.   : ≤15 red  · ≤25 orange · ≤40 yellow · >40 lime
//   km/L      : ≤10 red  · ≤14 orange · ≤18 yellow · >18 lime
//   R$/km     : ≤0.30 eco lime · ≤0.45 warn yellow · >0.45 bad orange

/** Eficiência elétrica: menor é melhor (consumo). */
fun kwhPer100kmColor(v: Float): Color = when {
    v <= 0f  -> TextSecondary
    v <= 20f -> NeonLime
    v <= 25f -> WarnYellow
    v <= 30f -> MoltenOrange
    else     -> DangerRed
}

/** km/L equivalente energético: maior é melhor. */
fun kmPerLEqColor(v: Float): Color = when {
    v <= 0f  -> TextSecondary
    v <= 15f -> DangerRed
    v <= 25f -> MoltenOrange
    v <= 40f -> WarnYellow
    else     -> NeonLime
}

/** km/L combustível puro: maior é melhor. */
fun kmPerLColor(v: Float): Color = when {
    v <= 0f  -> TextSecondary
    v <= 10f -> DangerRed
    v <= 14f -> MoltenOrange
    v <= 18f -> WarnYellow
    else     -> NeonLime
}

data class CostStatus(val label: String, val color: Color)

/** Status do custo/km vs meta de R$ 0,30. */
fun costPerKmStatus(v: Float): CostStatus = when {
    v <= 0f    -> CostStatus("—",          TextSecondary)
    v <= 0.30f -> CostStatus("✓ ECO",      NeonLime)
    v <= 0.45f -> CostStatus("⚠ ATENÇÃO",  WarnYellow)
    else       -> CostStatus("▲ ALTO",     MoltenOrange)
}
