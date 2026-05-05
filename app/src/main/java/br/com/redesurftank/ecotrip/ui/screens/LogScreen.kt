package br.com.redesurftank.ecotrip.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import br.com.redesurftank.ecotrip.managers.AppLogger
import br.com.redesurftank.ecotrip.managers.LogLevel
import br.com.redesurftank.ecotrip.ui.theme.*

@Composable
fun LogScreen(onBack: () -> Unit) {
    val entries by AppLogger.entries.collectAsState()
    val listState = rememberLazyListState()

    LaunchedEffect(entries.size) {
        if (entries.isNotEmpty()) listState.animateScrollToItem(entries.size - 1)
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(SurfaceDeep)
            .systemBarsPadding()
            .padding(horizontal = 10.dp, vertical = 4.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                IconButton(onClick = onBack) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Voltar", tint = TextSecondary)
                }
                Text("Log do App", fontSize = 18.sp, fontWeight = FontWeight.Bold, color = Green)
            }
            TextButton(onClick = { AppLogger.clear() }) {
                Text("Limpar", fontSize = 13.sp, color = TextSecondary)
            }
        }

        HorizontalDivider(color = Separator, thickness = 0.5.dp)
        Spacer(Modifier.height(4.dp))

        if (entries.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("Nenhum log ainda.", fontSize = 13.sp, color = TextSecondary)
            }
        } else {
            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize(),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                items(entries) { entry ->
                    val (levelColor, levelLabel) = when (entry.level) {
                        LogLevel.ERROR -> Color(0xFFFF4444) to "E"
                        LogLevel.WARN  -> Color(0xFFFFD60A) to "W"
                        LogLevel.INFO  -> TextPrimary        to "I"
                        LogLevel.DEBUG -> TextSecondary      to "D"
                    }
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Text(
                            entry.time,
                            fontSize = 10.sp,
                            fontFamily = FontFamily.Monospace,
                            color = TextSecondary,
                            modifier = Modifier.width(54.dp),
                        )
                        Text(
                            levelLabel,
                            fontSize = 10.sp,
                            fontFamily = FontFamily.Monospace,
                            fontWeight = FontWeight.Bold,
                            color = levelColor,
                            modifier = Modifier.width(10.dp),
                        )
                        Text(
                            "[${entry.tag}] ${entry.msg}",
                            fontSize = 10.sp,
                            fontFamily = FontFamily.Monospace,
                            color = levelColor,
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
            }
        }
    }
}
