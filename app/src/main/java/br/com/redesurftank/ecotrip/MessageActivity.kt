package br.com.redesurftank.ecotrip

import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
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
import br.com.redesurftank.ecotrip.managers.MessageManager
import br.com.redesurftank.ecotrip.managers.MqttManager
import br.com.redesurftank.ecotrip.ui.theme.EcotripTheme
import kotlinx.coroutines.delay

/**
 * Recado em tela cheia no HU. Mesmo mecanismo da chamada recebida
 * (IncomingCallActivity): sobe por full-screen-intent, então o sistema a coloca
 * por cima do que estiver na tela — é o caminho nativo do Android, não overlay
 * de terceiro, e não depende de permissão especial.
 *
 * Fonte grande porque a tela é olhada de longe e de relance. Fecha no botão ou
 * sozinha depois de AUTO_CLOSE_MS, pra nunca ficar presa sobre a navegação.
 */
class MessageActivity : ComponentActivity() {
    companion object {
        /** Auto-dismiss: recado não pode virar obstáculo permanente na tela. */
        const val AUTO_CLOSE_MS = 90_000L
    }

    private var player: android.media.MediaPlayer? = null

    /**
     * Toca o áudio do recado direto da URL do bridge. STREAM_MUSIC pra sair nos
     * alto-falantes no volume de mídia (o de notificação é baixo demais pra
     * entender uma frase andando).
     */
    private fun playAudio(url: String, onDone: () -> Unit) {
        stopAudio()
        try {
            player = android.media.MediaPlayer().apply {
                setAudioStreamType(android.media.AudioManager.STREAM_MUSIC)
                setDataSource(url)
                setOnCompletionListener { onDone(); stopAudio() }
                setOnErrorListener { _, _, _ -> onDone(); stopAudio(); true }
                setOnPreparedListener { start() }
                prepareAsync()
            }
        } catch (e: Exception) {
            android.util.Log.w("MessageActivity", "playAudio falhou: ${e.message}")
            onDone()
        }
    }

    private fun stopAudio() {
        try { player?.let { if (it.isPlaying) it.stop(); it.release() } } catch (_: Exception) {}
        player = null
    }

    override fun onDestroy() { stopAudio(); super.onDestroy() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true); setTurnScreenOn(true)
        }
        val from = intent.getStringExtra("from").orEmpty().ifBlank { "Recado" }
        val text = intent.getStringExtra("text").orEmpty()
        val audioUrl = intent.getStringExtra("audioUrl")?.ifBlank { null }
        val durSec = intent.getIntExtra("durSec", 0)
        val msgId = intent.getStringExtra("msgId").orEmpty()

        setContent {
            EcotripTheme {
                LaunchedEffect(Unit) {
                    delay(AUTO_CLOSE_MS)
                    // Sumiu sozinho: quem mandou merece saber que NÃO foi lido.
                    MqttManager.getInstance().publishMessageEvent(msgId, "expired")
                    stopAudio()
                    MessageManager.clear(this@MessageActivity)
                    finish()
                }
                Surface(color = Color(0xFF07080A), modifier = Modifier.fillMaxSize()) {
                    Box(Modifier.fillMaxSize().padding(36.dp), contentAlignment = Alignment.Center) {
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.Center,
                        ) {
                            Text(
                                "RECADO",
                                color = Color(0xFF5EEAD4), fontSize = 20.sp,
                                fontWeight = FontWeight.Bold, letterSpacing = 4.sp,
                            )
                            Spacer(Modifier.height(10.dp))
                            Text(
                                from,
                                color = Color.White, fontSize = 40.sp,
                                fontWeight = FontWeight.Bold, textAlign = TextAlign.Center,
                            )
                            Spacer(Modifier.height(22.dp))
                            if (audioUrl != null) {
                                // Recado de voz: nada de texto pra ler dirigindo —
                                // só o aviso e um alvo grande pra tocar.
                                Text(
                                    if (durSec > 0) "Mensagem de áudio · ${durSec}s"
                                    else "Mensagem de áudio",
                                    color = Color(0xFFF1F5F9), fontSize = 42.sp,
                                    fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center,
                                )
                                Spacer(Modifier.height(26.dp))
                                var playing by remember { mutableStateOf(false) }
                                Button(
                                    onClick = {
                                        if (playing) { stopAudio(); playing = false }
                                        else {
                                            playing = true
                                            MqttManager.getInstance().publishMessageEvent(msgId, "played")
                                            playAudio(audioUrl) { playing = false }
                                        }
                                    },
                                    shape = RoundedCornerShape(18.dp),
                                    colors = ButtonDefaults.buttonColors(
                                        containerColor = Color(0xFF22D3EE)),
                                    modifier = Modifier.fillMaxWidth(0.62f).height(96.dp),
                                ) {
                                    Text(if (playing) "■  PARAR" else "▶  OUVIR",
                                         color = Color(0xFF04252B),
                                         fontSize = 34.sp, fontWeight = FontWeight.Bold)
                                }
                            } else {
                                // A mensagem é o elemento dominante — legível de relance.
                                Text(
                                    text,
                                    color = Color(0xFFF1F5F9), fontSize = 56.sp,
                                    fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center,
                                    lineHeight = 66.sp,
                                )
                            }
                            Spacer(Modifier.height(40.dp))
                            Button(
                                onClick = {
                                    MqttManager.getInstance().publishMessageEvent(msgId, "read")
                                    stopAudio()
                                    MessageManager.clear(this@MessageActivity)
                                    finish()
                                },
                                shape = RoundedCornerShape(18.dp),
                                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF22C55E)),
                                modifier = Modifier.fillMaxWidth(0.5f).height(84.dp),
                            ) {
                                Text("FECHAR", color = Color(0xFF04220F),
                                     fontSize = 28.sp, fontWeight = FontWeight.Bold)
                            }
                        }
                    }
                }
            }
        }
    }
}
