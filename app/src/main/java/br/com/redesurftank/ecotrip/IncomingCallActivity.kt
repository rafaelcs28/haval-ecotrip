package br.com.redesurftank.ecotrip

import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import br.com.redesurftank.ecotrip.managers.CallManager
import br.com.redesurftank.ecotrip.ui.theme.EcotripTheme
import kotlinx.coroutines.delay

// Tela cheia de chamada recebida no HU. Sobe via full-screen-intent (ou launch
// direto). Mostra a mensagem personalizada + Aceitar/Recusar. Atende → áudio
// full-duplex roda no serviço; a tela fecha. Auto-dismiss se a chamada cair.
class IncomingCallActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true); setTurnScreenOn(true)
        }
        val caller = intent.getStringExtra("caller").orEmpty()
        val message = intent.getStringExtra("message").orEmpty()

        setContent {
            EcotripTheme {
                var st by remember { mutableStateOf(CallManager.state) }
                var remaining by remember { mutableStateOf(10) }
                val deadline = remember { System.currentTimeMillis() + CallManager.AUTO_ACCEPT_MS }
                // Espelha o estado do CallManager e a contagem; fecha quando IDLE.
                LaunchedEffect(Unit) {
                    while (true) {
                        st = CallManager.state
                        remaining = ((deadline - System.currentTimeMillis()) / 1000L).coerceAtLeast(0).toInt()
                        if (st == CallManager.CallState.IDLE) { finish(); break }
                        delay(250)
                    }
                }
                val inCall = st == CallManager.CallState.IN_CALL
                Surface(modifier = Modifier.fillMaxSize(), color = Color(0xFF0E1116)) {
                    Box(Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text(if (inCall) "Em chamada" else "Chamada recebida",
                                color = Color(0xFF8A93A2), fontSize = 18.sp)
                            Spacer(Modifier.height(12.dp))
                            Text(
                                if (caller.isNotBlank()) caller else "Desconhecido",
                                color = Color.White, fontSize = 34.sp, fontWeight = FontWeight.Bold,
                                textAlign = TextAlign.Center)
                            if (message.isNotBlank()) {
                                Spacer(Modifier.height(20.dp))
                                Text(message, color = Color(0xFFD6DBE3), fontSize = 24.sp,
                                    textAlign = TextAlign.Center, lineHeight = 30.sp)
                            }
                            if (!inCall) {
                                Spacer(Modifier.height(16.dp))
                                Text("Atendendo automaticamente em ${remaining}s",
                                    color = Color(0xFF2EB872), fontSize = 18.sp)
                            }
                            Spacer(Modifier.height(48.dp))
                            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
                                if (inCall) {
                                    Button(
                                        onClick = { CallManager.end(this@IncomingCallActivity); finish() },
                                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFD9342B)),
                                        shape = RoundedCornerShape(32.dp),
                                        modifier = Modifier.height(64.dp)
                                    ) { Text("Encerrar", fontSize = 22.sp, color = Color.White) }
                                } else {
                                    Button(
                                        onClick = { CallManager.accept(this@IncomingCallActivity) },
                                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF2EB872)),
                                        shape = RoundedCornerShape(32.dp),
                                        modifier = Modifier.height(64.dp)
                                    ) { Text("Atender agora", fontSize = 22.sp, color = Color.White) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
