# Logs do APK Haval EcoTrip — mapeamento

Levantado em 30/07/2026, APK v6.159. Total: **467 chamadas de log** em 26 arquivos.

## 1. AppLogger — logger próprio (`managers/AppLogger.kt`)

**331 chamadas.** É um `object` com `MutableStateFlow<List<LogEntry>>`:

| aspecto | valor |
|---|---|
| capacidade | `MAX_ENTRIES = 300` (ring buffer, descarta o mais antigo) |
| persistência | **nenhuma** — zero referências a File/filesDir/SharedPrefs |
| formato | `HH:mm:ss` + level + tag + msg (sem data) |
| espelha no logcat | sim, todo `AppLogger.x` chama `Log.x` também |
| consumo | `LogScreen.kt` (tela no app) e `cmd/dumplog` (últimas 80 linhas) |

Distribuição por nível: `i` 177 · `w` 126 · `e` 21 · `d` 7 · `v` 0

**Consequência:** reiniciar o app apaga tudo. Um crash loop (como o de v6.131, 23 restarts
em 60min) não deixa rastro local — só o que tiver ido pro logcat antes de morrer, e o
logcat do head unit também rotaciona.

## 2. Log.* direto do Android — 136 chamadas

Vão só pro logcat, sem passar pelo ring buffer, então **não aparecem no `dumplog`
nem na LogScreen**. Concentrados em:

| arquivo | chamadas | observação |
|---|---|---|
| `MqttManager.kt` | 30 | |
| `TelemetryRecorder.kt` | 22 | **único log da classe** — nada dela chega ao dumplog |
| `LocalApiServer.kt` | 14 | idem |
| `CarDataManager.kt` | 13 | |
| `TripManager.kt` | 13 | |
| `CarTelemetryService.kt` | 11 | idem |
| `UpdateManager.kt` | 7 | |
| resto | 26 | MediaControllerHelper, LocalServiceAdvertiser, BootReceiver, telas |

## 3. Log por arquivo (AppLogger d/i/w/e + Log.*)

| arquivo | TAG | d | i | w | e | Log.* |
|---|---|---|---|---|---|---|
| MqttManager.kt | MqttManager | 1 | 78 | 70 | 4 | 30 |
| TripManager.kt | TripManager | 6 | 37 | 11 | 3 | 13 |
| AutomationManager.kt | AutomationManager | 0 | 14 | 14 | 1 | 0 |
| CarAudioRelay.kt | CarAudioRelay | 0 | 12 | 7 | 0 | 0 |
| UpdateManager.kt | UpdateManager | 0 | 9 | 2 | 2 | 7 |
| VehicleControlManager.kt | VehicleControlManager | 0 | 5 | 2 | 10 | 0 |
| ParkGuard.kt | ParkGuard | 0 | 4 | 4 | 0 | 0 |
| CabinRecorder.kt | CabinRecorder | 0 | 4 | 5 | 0 | 0 |
| CallManager.kt | CallManager | 0 | 3 | 3 | 0 | 0 |
| ShizukuPerms.kt | ShizukuPerms | 0 | 1 | 3 | 0 | 0 |
| MessageManager.kt | MessageManager | 0 | 1 | 2 | 0 | 0 |
| CarDataManager.kt | CarDataManager | 0 | 2 | 1 | 1 | 13 |
| V8SoundEngine.kt | V8SoundEngine | 0 | 2 | 2 | 0 | 0 |
| TelemetryRecorder.kt | TelemetryRecorder | 0 | 0 | 0 | 0 | 22 |
| LocalApiServer.kt | LocalApiServer | 0 | 0 | 0 | 0 | 14 |
| CarTelemetryService.kt | — | 0 | 0 | 0 | 0 | 11 |
| LocalServiceAdvertiser.kt | LocalServiceAdvertiser | 0 | 0 | 0 | 0 | 5 |
| MediaControllerHelper.kt | — | 0 | 0 | 0 | 0 | 5 |
| BootReceiver.kt | BootReceiver | 0 | 0 | 0 | 0 | 3 |
| App.kt | — | 0 | 2 | 0 | 0 | 0 |
| telas (HomeTesla, Controles, Message, LogScreen) | — | 0 | 3 | 0 | 0 | 8 |

`VehicleControlManager` é o único com mais `e` (10) que `i` (5) — comandos ao veículo
falham com frequência e isso é registrado.

## 4. Telemetria publicada como debug via MQTT

Tópicos sob `haval/ecotrip/debug/` — todos `pubD` (retained + dedupe por valor),
exceto `lock_vote` que é `pub` (sem retain, sem dedupe):

| tópico | conteúdo |
|---|---|
| `debug/lock_status_raw` | valor da trava **pós**-voting-filter |
| `debug/lock_vote` | cru + confirmado + total de leituras (v6.157) |
| `debug/door_status_raw` | array bruto `{0,0,0,0,0,0}` |
| `debug/door_parsed` | resultado do parsing `0,0,0,0,0` |
| `debug/window_status_raw` | array bruto `{1,1,1,1}` |
| `debug/window_parsed` | idem parseado |
| `debug/sunroof_raw` | posição 0-3 |
| `debug/front_light_raw` | farol |
| `debug/turn_left` / `debug/turn_right` | setas |
| `debug/tsr` | reconhecimento de placas |
| `debug/batt12v` | 3 leituras de bateria (v6.158) |

Cuidado com `pubD`: dedupe por valor significa que **valor repetido não republica**.
Foi o que fez `lock_state` parecer congelado — o retained era do último valor
diferente, não uma leitura atual.

## 5. Arquivos persistidos (não são log, mas são dado gravado)

| caminho | conteúdo |
|---|---|
| `filesDir/autotrip_samples/` | amostras GPS/telemetria por viagem |
| `filesDir/charge_samples/` | amostras de sessão de recarga |
| `filesDir/recordings/` | áudio de cabine (CabinRecorder) |
| `filesDir/mqtt-persist/`, `mqtt-owner/` | fila do Paho |
| `automations.json`, `automation_geo_state.json`, `automation_trig_state.json` | regras e estado |
| `_inprogress.json`, `index.json` | viagem em andamento e índice |
| `cacheDir/apk/` | APK baixado pelo auto-update |
| `ecotrip-backup.json` | backup |

## 6. Diagnóstico remoto — 57 comandos MQTT

Relevantes pra log/debug:

| comando | efeito |
|---|---|
| `cmd/dumplog` | últimas **80** entradas do AppLogger → `cmd/dumplog/result` (retained, QoS 1) |
| `cmd/diag` | diagnóstico geral |
| `cmd/read` | lê uma chave arbitrária do SDK por nome de constante |
| `cmd/check_update` | força check de versão e devolve diagnóstico |
| `cmd/audio_diag`, `cmd/mic_test` | áudio |
| `cmd/windows_status`, `cmd/refresh_*` | reconsulta estado |

`cmd/read` é o mais útil pra investigação: aceita o nome da constante e devolve o valor
cru — foi assim que daria pra medir `car.basic.battery_power_level` sem subir APK novo.

## 7. Lacunas

1. **AppLogger não persiste.** Crash/restart apaga. Um arquivo com rotação
   (ex: 2 × 256KB em `filesDir`) tornaria crash loop e falha noturna investigáveis.
2. **136 `Log.*` invisíveis remotamente.** `TelemetryRecorder`, `LocalApiServer` e
   `CarTelemetryService` não têm *nenhuma* linha no dumplog — justamente as classes de
   gravação de dados e do servidor LAN.
3. **`dumplog` corta em 80 linhas** de um buffer de 300, e o buffer cobre pouco tempo
   com o MqttManager gerando 148 linhas de `i`+`w`.
4. **Sem nível/filtro remoto.** Não há como pedir "só warnings" ou subir pra debug em
   runtime; `AppLogger.d` só tem 7 usos, então o nível DEBUG é praticamente inexistente.
5. **Sem timestamp de data.** O formato é `HH:mm:ss`, então log de dias diferentes é
   indistinguível.
