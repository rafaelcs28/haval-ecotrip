package br.com.redesurftank.ecotrip.ui.screens

import android.app.Activity
import android.content.Intent
import android.speech.RecognizerIntent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import br.com.redesurftank.ecotrip.managers.AppLogger
import br.com.redesurftank.ecotrip.managers.MqttManager
import br.com.redesurftank.ecotrip.ui.theme.*
import org.json.JSONObject

/// Um destino, vindo da busca ou dos favoritos.
data class DestinoItem(
    val name: String,
    val address: String = "",
    val lat: Double,
    val lng: Double,
    val distKm: Double? = null,
    /// 'fav' = favorito salvo (dá pra apagar) · 'lugar' = geofence · "" = resultado de busca
    val origem: String = "",
)

/// Popup de destino pensado pra usar no carro: alvos grandes, poucos passos,
/// um toque manda. O acesso antigo era um IconButton no canto da tela de
/// Consumo — impossível de acertar saindo de casa ou parado no trânsito.
///
/// Toda a rede passa pelo MQTT que já está conectado e autenticado: o APK não
/// manda header Authorization, então abrir HTTP autenticado aqui seria peça
/// nova sem ganho. A chave do Google fica no bridge — o carro manda texto e
/// recebe candidatos com coordenada.
@Composable
fun DestinoRapidoDialog(onClose: () -> Unit) {
    val ctx = LocalContext.current
    val mqtt = remember { MqttManager.getInstance() }
    var busca by remember { mutableStateOf("") }
    var buscando by remember { mutableStateOf(false) }
    var erro by remember { mutableStateOf<String?>(null) }
    var resultados by remember { mutableStateOf<List<DestinoItem>>(emptyList()) }
    var favoritos by remember { mutableStateOf<List<DestinoItem>>(emptyList()) }
    var enviado by remember { mutableStateOf<String?>(null) }
    // Destino aguardando nome pra salvar como favorito.
    var favorPendente by remember { mutableStateOf<DestinoItem?>(null) }

    // Reconhecimento de voz só aparece se o head unit tiver: no Android 9 do
    // carro isso varia por modelo, e um botão que não faz nada é pior que
    // botão nenhum.
    val temVoz = remember {
        runCatching {
            ctx.packageManager.queryIntentActivities(
                Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH), 0).isNotEmpty()
        }.getOrDefault(false)
    }

    fun aplicar(json: String, alvo: (List<DestinoItem>) -> Unit) {
        runCatching {
            val o = JSONObject(json)
            if (!o.optBoolean("ok", false)) { erro = o.optString("error", "falhou"); return@runCatching }
            val arr = o.optJSONArray("items") ?: return@runCatching
            alvo((0 until arr.length()).mapNotNull { i ->
                arr.optJSONObject(i)?.let {
                    DestinoItem(
                        name = it.optString("name"), address = it.optString("address", ""),
                        lat = it.optDouble("lat"), lng = it.optDouble("lng"),
                        distKm = if (it.isNull("distKm")) null else it.optDouble("distKm"),
                        origem = it.optString("origem", ""),
                    )
                }?.takeIf { it.name.isNotBlank() && it.lat != 0.0 }
            })
        }.onFailure { AppLogger.w("DestinoDialog", "parse falhou: ${it.message}") }
    }

    DisposableEffect(Unit) {
        mqtt.onNavResult = { topico, payload ->
            when {
                topico.endsWith("/place_search/result") -> { buscando = false; aplicar(payload) { resultados = it } }
                topico.endsWith("/nav_favorites/result") -> aplicar(payload) { favoritos = it }
            }
        }
        mqtt.pedirFavoritos()
        onDispose { mqtt.onNavResult = null }
    }

    fun enviar(d: DestinoItem) {
        mqtt.publishNavTo(d.lat, d.lng, d.name, "waze")
        enviado = d.name
    }

    Dialog(onDismissRequest = onClose) {
        Surface(color = VoidBlack, shape = RoundedCornerShape(20.dp)) {
            Column(
                Modifier.fillMaxWidth().padding(18.dp).heightIn(max = 560.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Para onde vamos?", color = TextPrimary, fontSize = 22.sp, fontWeight = FontWeight.Bold,
                        modifier = Modifier.weight(1f))
                    TextButton(onClick = onClose) { Text("Fechar", color = TextSecondary, fontSize = 16.sp) }
                }

                if (enviado != null) {
                    // Confirmação grande e curta: no trânsito você olha de relance.
                    Column(
                        Modifier.fillMaxWidth().background(NeonLime.copy(alpha = 0.12f), RoundedCornerShape(14.dp))
                            .padding(16.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Text("✓ $enviado", color = NeonLime, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                        Text("No painel do carro e no Waze do celular.", color = TextSecondary, fontSize = 14.sp)
                        Button(onClick = onClose, modifier = Modifier.fillMaxWidth().height(52.dp),
                            colors = ButtonDefaults.buttonColors(containerColor = NeonLime)) {
                            Text("OK", fontSize = 17.sp, fontWeight = FontWeight.Bold, color = VoidBlack)
                        }
                    }
                    return@Column
                }

                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(
                        value = busca, onValueChange = { busca = it; erro = null },
                        modifier = Modifier.weight(1f), singleLine = true,
                        label = { Text("Buscar lugar ou endereço") },
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                        keyboardActions = KeyboardActions(onSearch = {
                            if (busca.trim().length >= 3) { buscando = true; erro = null; mqtt.buscarLugar(busca.trim()) }
                        }),
                    )
                    if (temVoz) {
                        Button(
                            onClick = {
                                runCatching {
                                    val i = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                                        .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                                        .putExtra(RecognizerIntent.EXTRA_LANGUAGE, "pt-BR")
                                        .putExtra(RecognizerIntent.EXTRA_PROMPT, "Diga o destino")
                                    (ctx as? Activity)?.startActivityForResult(i, REQ_VOZ_DESTINO)
                                }.onFailure { erro = "ditado indisponível" }
                            },
                            modifier = Modifier.height(56.dp),
                            colors = ButtonDefaults.buttonColors(containerColor = PlasmaBlue),
                        ) { Text("🎤", fontSize = 20.sp) }
                    }
                }

                if (buscando) LinearProgressIndicator(Modifier.fillMaxWidth(), color = AuroraTeal)
                erro?.let { Text("⚠ $it", color = MoltenOrange, fontSize = 14.sp) }

                val lista = if (resultados.isNotEmpty()) resultados else favoritos
                if (resultados.isNotEmpty()) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("RESULTADOS", color = TextSecondary, fontSize = 11.sp, fontWeight = FontWeight.Bold,
                            modifier = Modifier.weight(1f))
                        TextButton(onClick = { resultados = emptyList(); busca = "" }) {
                            Text("ver favoritos", color = AuroraTeal, fontSize = 14.sp)
                        }
                    }
                } else {
                    Text("FAVORITOS", color = TextSecondary, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                }

                LazyColumn(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    items(lista) { d ->
                        Row(
                            Modifier.fillMaxWidth().background(GlassCard, RoundedCornerShape(14.dp))
                                .clickable { enviar(d) }.padding(14.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(Modifier.weight(1f)) {
                                Text(d.name, color = TextPrimary, fontSize = 18.sp, fontWeight = FontWeight.Bold,
                                    maxLines = 1)
                                val sub = listOfNotNull(
                                    d.distKm?.let { "${"%.1f".format(it)} km" },
                                    d.address.takeIf { it.isNotBlank() },
                                ).joinToString(" · ")
                                if (sub.isNotBlank()) Text(sub, color = TextSecondary, fontSize = 13.sp, maxLines = 1)
                            }
                            // Estrela só em resultado de busca: favorito já salvo
                            // não precisa salvar de novo.
                            if (d.origem.isBlank()) {
                                TextButton(onClick = { favorPendente = d }) {
                                    Text("☆", color = NeonLime, fontSize = 26.sp)
                                }
                            }
                        }
                    }
                }
                if (lista.isEmpty() && !buscando) {
                    Text("Busque um lugar ou salve favoritos.", color = TextSecondary, fontSize = 14.sp)
                }
            }
        }
    }

    // Nome do favorito. Sugere o nome do lugar, mas você troca por algo curto
    // ("Academia") — é o que vai virar botão na lista.
    favorPendente?.let { d ->
        var nome by remember(d) { mutableStateOf(d.name.take(30)) }
        AlertDialog(
            onDismissRequest = { favorPendente = null },
            containerColor = VoidBlack,
            title = { Text("Salvar favorito", color = TextPrimary, fontWeight = FontWeight.Bold) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    OutlinedTextField(value = nome, onValueChange = { nome = it }, singleLine = true,
                        label = { Text("Nome") })
                    Text("Aparece também nos favoritos do iPhone.", color = TextSecondary, fontSize = 13.sp)
                }
            },
            confirmButton = {
                Button(onClick = {
                    if (nome.trim().isNotEmpty()) {
                        mqtt.salvarFavorito(nome.trim(), d.lat, d.lng)
                        favorPendente = null
                    }
                }, colors = ButtonDefaults.buttonColors(containerColor = NeonLime)) {
                    Text("Salvar", color = VoidBlack, fontWeight = FontWeight.Bold)
                }
            },
            dismissButton = {
                TextButton(onClick = { favorPendente = null }) { Text("Cancelar", color = TextSecondary) }
            },
        )
    }
}

const val REQ_VOZ_DESTINO = 7311
