# Haval OBD Companion (iPad)

App iOS nativo que conecta no adaptador ELM327 via Bluetooth e publica os
dados lidos do CAN do Haval via MQTT pro bridge — alimentando o cluster do
iPad com telemetria em tempo real **sem depender do APK do head unit**.

## Stack

- SwiftUI · iOS 17+ · iPad (universal)
- CoreBluetooth pra ELM327 BLE
- CocoaMQTT pra publicar no broker existente
- Bundle ID: `br.com.consorciolimpagyn.havalobd`
- Team ID: `7Y6MPKR5CD` (mesma conta da MapKit / APNs)

## Estrutura

```
HavalOBD/
├── HavalOBDApp.swift            entry point + idle timer disabled
├── ContentView.swift             UI principal (status + leituras + settings)
├── Models/
│   ├── PIDDefinition.swift       schema de um PID (id, command, parser, priority)
│   └── OBDSample.swift           snapshot de leitura
└── Services/
    ├── BluetoothManager.swift    scan/connect BLE; envia AT commands; recebe respostas
    ├── ELM327.swift              init sequence + loop de polling round-robin
    ├── PIDRegistry.swift         catálogo de PIDs (Mode 01 padrão + customs Haval)
    └── BridgePublisher.swift     MQTT client → publica snapshot 1Hz
```

## Como buildar

```bash
cd ios-obd
xcodegen generate          # regenera HavalOBD.xcodeproj a partir do spec
open HavalOBD.xcodeproj
```

No Xcode:

1. Seleciona target **HavalOBD** + dispositivo **iPad** (conectado via cabo ou wireless)
2. Vai em **Signing & Capabilities** — confirma que o Team é `7Y6MPKR5CD`
3. ⌘R pra build + run no iPad

## MQTT — config inicial

No próprio app, abre a engrenagem no canto superior direito:

```
Host:         mqttrafael.duckdns.org
Porta:        8883        (TLS)
Usuário:      obd_companion  (criar no Mosquitto)
Senha:        (a que você definir)
Topic prefix: haval/ecotrip/obd
```

O bridge precisa de uma nova subscription no Mosquitto:

```bash
# adicionar user no broker
mosquitto_passwd /opt/homebrew/etc/mosquitto/passwd obd_companion

# bridge/server.js já vai subscrever em haval/ecotrip/obd/snapshot
# (adicionar quando integrarmos a fonte OBD ao state.source aggregator)
```

## Catálogo atual

Hoje o app sabe ler **15 PIDs Mode 01 universais** (RPM, speed, ECT, IAT, MAF,
TPS, fuel level, baro, ambient temp, control voltage, intake pressure, timing
advance, engine load, STFT, LTFT).

**TODO**: os ~200 PIDs Mode 22 customs do Haval (BMS, MCU, TPMS, ECM, etc.)
precisam dos comandos hex exatos. Próximos passos:

1. Rafael grava sessão completa no Car Scanner com TODOS os parâmetros
   ativados, exporta CSV #2, drop no iCloud.
2. Comparar headers do CSV com a base pública (github CarScanner/elm327-pids)
   pra mapear `nome → comando hex`.
3. Plugar no `PIDRegistry.swift` (atualmente tem placeholders comentados).

## Topics publicados

- `haval/ecotrip/obd/snapshot` — JSON consolidado a 1Hz com todos os últimos
  valores:
  ```json
  {
    "ts": "2026-05-29T15:23:01Z",
    "source": "obd_ble",
    "rpm": 1850,
    "speed_kmh": 60,
    "ect_c": 88,
    ...
  }
  ```

## Background

O `Info.plist` declara `UIBackgroundModes: bluetooth-central` — o app
mantém o BLE conectado em segundo plano. Mas pra publicar no MQTT em
background o iOS pode pausar o socket; pra MVP, assume foreground com tela
acesa (idle timer disabled).
