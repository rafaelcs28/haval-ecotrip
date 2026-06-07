package br.com.consorciolimpagyn.navrelay

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

// Config + start do serviço. Celular dedicado: configure uma vez, toque em Iniciar.
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val prefs = getSharedPreferences("navrelay", Context.MODE_PRIVATE)
        setContent {
            MaterialTheme(colorScheme = darkColorScheme()) {
                Surface(Modifier.fillMaxSize()) { ConfigScreen(prefs, ::startRelay, ::testNav) }
            }
        }
    }

    private fun startRelay() {
        val i = Intent(this, NavRelayService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(i) else startService(i)
    }

    private fun testNav(app: String) {
        // Teste: navega pra um ponto fixo (centro de Goiânia) pra validar o intent + Android Auto.
        val lat = -16.6869; val lng = -49.2648
        val uri = if (app == "waze") Uri.parse("waze://?ll=$lat,$lng&navigate=yes")
                  else               Uri.parse("google.navigation:q=$lat,$lng&mode=d")
        val pkg = if (app == "waze") "com.waze" else "com.google.android.apps.maps"
        try { startActivity(Intent(Intent.ACTION_VIEW, uri).setPackage(pkg).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
        catch (_: Exception) { startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
    }
}

@Composable
private fun ConfigScreen(
    prefs: android.content.SharedPreferences,
    onStart: () -> Unit,
    onTest: (String) -> Unit,
) {
    var broker by remember { mutableStateOf(prefs.getString("broker", "ssl://mqttrafael.duckdns.org:8883") ?: "") }
    var user   by remember { mutableStateOf(prefs.getString("user", "") ?: "") }
    var pass   by remember { mutableStateOf(prefs.getString("pass", "") ?: "") }
    var topic  by remember { mutableStateOf(prefs.getString("topic", "haval/ecotrip/nav_to") ?: "") }
    var role   by remember { mutableStateOf(prefs.getString("role", "car") ?: "car") }
    var saved  by remember { mutableStateOf(false) }
    var status by remember { mutableStateOf(NavRelayService.status) }

    LaunchedEffect(Unit) { while (true) { status = NavRelayService.status; kotlinx.coroutines.delay(1000) } }

    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("Nav Relay", style = MaterialTheme.typography.headlineSmall)
        Text("Recebe o destino do Ecotrip (carro) e abre o Maps/Waze pra navegar no Android Auto.",
            style = MaterialTheme.typography.bodySmall)
        OutlinedTextField(broker, { broker = it }, label = { Text("Broker (ssl://host:porta)") }, singleLine = true, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(user, { user = it }, label = { Text("Usuário MQTT") }, singleLine = true, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(pass, { pass = it }, label = { Text("Senha MQTT") }, singleLine = true, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(topic, { topic = it }, label = { Text("Tópico") }, singleLine = true, modifier = Modifier.fillMaxWidth())
        Text("Este aparelho é:", style = MaterialTheme.typography.bodyMedium)
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            FilterChip(selected = role == "car",   onClick = { role = "car" },   label = { Text("Carro (dedicado)") })
            FilterChip(selected = role == "phone", onClick = { role = "phone" }, label = { Text("Celular") })
        }
        Text(if (role == "phone") "Recebe só os envios marcados pro celular (botão Waze/Maps do iPhone)."
             else "Recebe os envios do carro (e os sem destino definido).",
            style = MaterialTheme.typography.bodySmall)
        Button(onClick = {
            prefs.edit().putString("broker", broker.trim()).putString("user", user.trim())
                .putString("pass", pass).putString("topic", topic.trim()).putString("role", role).apply()
            saved = true; onStart()
        }, modifier = Modifier.fillMaxWidth()) { Text("Salvar e iniciar serviço") }
        if (saved) Text("✓ Serviço iniciado. Pode deixar o app aberto/em background.")
        Spacer(Modifier.height(8.dp))
        Text("Status: $status", style = MaterialTheme.typography.bodyMedium)
        Text("Último: ${NavRelayService.lastNav}", style = MaterialTheme.typography.bodySmall)
        Spacer(Modifier.height(8.dp))
        Text("Testar navegação:", style = MaterialTheme.typography.bodyMedium)
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedButton(onClick = { onTest("maps") }, modifier = Modifier.weight(1f)) { Text("Maps") }
            OutlinedButton(onClick = { onTest("waze") }, modifier = Modifier.weight(1f)) { Text("Waze") }
        }
    }
}
