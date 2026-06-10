package br.com.consorciolimpagyn.navrelay

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
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
                Surface(Modifier.fillMaxSize()) { ConfigScreen(prefs, ::startRelay, ::testNav, ::isBatteryOptIgnored, ::requestBatteryOptIgnore, ::isOverlayGranted, ::requestOverlay) }
            }
        }
    }

    private fun startRelay() {
        val i = Intent(this, NavRelayService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(i) else startService(i)
    }

    private fun isBatteryOptIgnored(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    @Suppress("BatteryLife")
    private fun requestBatteryOptIgnore() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        // Abre o prompt do sistema "Ignorar otimização de bateria" pra esse app.
        // Único modo de o MQTT sobreviver Doze mode em background longo.
        val i = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                       Uri.parse("package:$packageName"))
        try { startActivity(i) } catch (_: Exception) {
            // Alguns OEMs bloqueiam o intent direto — cai pra tela genérica.
            try { startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)) } catch (_: Exception) {}
        }
    }

    private fun isOverlayGranted(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return Settings.canDrawOverlays(this)
    }

    private fun requestOverlay() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        // "Sobrepor outros apps" — com isso concedido o serviço consegue abrir o
        // Maps/Waze mesmo com o app em background (sem ele o Android bloqueia).
        val i = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName"))
        try { startActivity(i) } catch (_: Exception) {
            try { startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION)) } catch (_: Exception) {}
        }
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
    isBatteryOptIgnored: () -> Boolean,
    requestBatteryOptIgnore: () -> Unit,
    isOverlayGranted: () -> Boolean,
    requestOverlay: () -> Unit,
) {
    var broker by remember { mutableStateOf(prefs.getString("broker", "ssl://mqttrafael.duckdns.org:8883") ?: "") }
    var user   by remember { mutableStateOf(prefs.getString("user", "") ?: "") }
    var pass   by remember { mutableStateOf(prefs.getString("pass", "") ?: "") }
    var topic  by remember { mutableStateOf(prefs.getString("topic", "haval/ecotrip/nav_to") ?: "") }
    var role   by remember { mutableStateOf(prefs.getString("role", "car") ?: "car") }
    var devName by remember { mutableStateOf(prefs.getString("device_name", "") ?: "") }
    var alwaysOn by remember { mutableStateOf(prefs.getBoolean("always_on", false)) }
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
        OutlinedTextField(topic, { topic = it }, label = { Text("Tópico base") }, singleLine = true, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(devName, { devName = it },
            label = { Text("Nome do dispositivo (ex: Carro do Rafael)") },
            placeholder = { Text("aparece no iOS pra escolher destino") },
            singleLine = true, modifier = Modifier.fillMaxWidth())
        Text("Este aparelho é:", style = MaterialTheme.typography.bodyMedium)
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            FilterChip(selected = role == "car",   onClick = { role = "car" },   label = { Text("Carro (dedicado)") })
            FilterChip(selected = role == "phone", onClick = { role = "phone" }, label = { Text("Celular") })
        }
        Text(if (role == "phone") "Padrão pros envios marcados como 'celular' (compat com versão antiga do iOS)."
             else "Padrão pros envios marcados como 'carro' (compat com versão antiga do iOS).",
            style = MaterialTheme.typography.bodySmall)
        Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.weight(1f)) {
                Text("Sempre online", style = MaterialTheme.typography.bodyLarge)
                Text("Mantém CPU acordada + pede whitelist de bateria. Ative SÓ se o aparelho fica plugado (carro).",
                    style = MaterialTheme.typography.bodySmall)
            }
            Switch(checked = alwaysOn, onCheckedChange = { alwaysOn = it })
        }
        Button(onClick = {
            prefs.edit().putString("broker", broker.trim()).putString("user", user.trim())
                .putString("pass", pass).putString("topic", topic.trim()).putString("role", role)
                .putString("device_name", devName.trim()).putBoolean("always_on", alwaysOn).apply()
            saved = true; onStart()
        }, modifier = Modifier.fillMaxWidth()) { Text("Salvar e iniciar serviço") }
        if (saved) Text("✓ Serviço iniciado. Pode deixar o app aberto/em background.")

        // Overlay ("sobrepor outros apps") é OBRIGATÓRIO pra abrir o Maps/Waze quando o
        // app está em background — sem ele o Android 10+ bloqueia o launch silenciosamente.
        var overlayOk by remember { mutableStateOf(isOverlayGranted()) }
        LaunchedEffect(Unit) { while (true) { overlayOk = isOverlayGranted(); kotlinx.coroutines.delay(2000) } }
        if (!overlayOk) {
            Spacer(Modifier.height(4.dp))
            Card(modifier = Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("⚠ Permissão de sobreposição DESATIVADA", style = MaterialTheme.typography.bodyMedium)
                    Text("Sem ela, o destino chega mas o Waze/Maps NÃO abre sozinho com o app em background.",
                        style = MaterialTheme.typography.bodySmall)
                    Button(onClick = requestOverlay, modifier = Modifier.fillMaxWidth()) {
                        Text("Permitir sobrepor outros apps")
                    }
                }
            }
        } else {
            Text("✓ Sobreposição permitida — abre o Waze/Maps mesmo em background.",
                style = MaterialTheme.typography.bodySmall)
        }

        // Whitelist de bateria só importa quando "Sempre online" está ligado — nesse
        // modo a conexão precisa sobreviver Doze. Caso contrário, não pede nada.
        if (alwaysOn) {
            var battOk by remember { mutableStateOf(isBatteryOptIgnored()) }
            LaunchedEffect(Unit) { while (true) { battOk = isBatteryOptIgnored(); kotlinx.coroutines.delay(2000) } }
            if (!battOk) {
                Spacer(Modifier.height(4.dp))
                Card(modifier = Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("⚠ Otimização de bateria está ATIVA",
                            style = MaterialTheme.typography.bodyMedium)
                        Text("Sem dispensar, o Android mata a conexão MQTT em background após alguns minutos.",
                            style = MaterialTheme.typography.bodySmall)
                        Button(onClick = requestBatteryOptIgnore, modifier = Modifier.fillMaxWidth()) {
                            Text("Dispensar otimização de bateria")
                        }
                    }
                }
            } else {
                Text("✓ Otimização de bateria dispensada — conexão sobrevive em background.",
                    style = MaterialTheme.typography.bodySmall)
            }
        }

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
