#!/usr/bin/env node
// Diagnóstico do canal MQTT do app do carro (EcoTrip).
// Roda de dentro de bridge/ (usa ./.env: MQTT_USER/MQTT_PASS).
//   node rxcheck.js
// Sai 0 se o RX do app está VIVO, 2 se MORTO.
//
// Avalia 3 coisas em ~16s:
//   1) heartbeat fresco  -> só o app publica (a cada 5s). Presente = cliente MQTT do app conectado.
//   2) status online      -> o app publicou birth "online" (retain). offline preso = sessão caída.
//   3) RX vivo            -> manda cmd/refresh_charge_limit e espera ha/charge_limit/state com retain=false.
require("dotenv").config({ path: "./.env" });
const mqtt = require("mqtt");

const PREFIX = "haval/ecotrip";
const c = mqtt.connect("mqtts://mqttrafael.duckdns.org:8883", {
  username: process.env.MQTT_USER,
  password: process.env.MQTT_PASS,
  clean: true,
  rejectUnauthorized: false,
});

const t0 = Date.now();
const fresh = {};
let drained = false, onlineFresh = false, rxFresh = false;

c.on("connect", () => {
  c.subscribe([`${PREFIX}/#`], () => {
    setTimeout(() => {
      drained = true;
      c.publish(`${PREFIX}/cmd/refresh_charge_limit`, "{}", { qos: 1 });
      console.log(`[${sec()}] refresh_charge_limit enviado (testando RX)`);
    }, 1500);
  });
});

c.on("message", (tp, pl, pk) => {
  const k = tp.replace(`${PREFIX}/`, "");
  if (tp === `${PREFIX}/status`) {
    const v = pl.toString();
    if (v.includes("online") && !pk.retain) onlineFresh = true;
    console.log(`[${sec()}] status=${v} retain=${pk.retain}`);
    return;
  }
  if (pk.retain) return;
  fresh[k] = (fresh[k] || 0) + 1;
  if (drained && tp === `${PREFIX}/ha/charge_limit/state`) {
    rxFresh = true;
    console.log(`[${sec()}] RX FRESCO ha/charge_limit/state=${pl.toString()}`);
  }
});

setTimeout(() => {
  console.log("\n--- tópicos frescos (retain=false) em 16s ---");
  Object.keys(fresh).sort().forEach((k) => console.log(`  ${k} x${fresh[k]}`));
  const hb = !!fresh["heartbeat"];
  console.log("\nheartbeat:", hb ? "SIM (cliente MQTT do app conectado)" : "NÃO (app NÃO conectado ao broker)");
  console.log("online fresco:", onlineFresh ? "SIM" : "NÃO");
  console.log("RX (cmd/#):", rxFresh ? "VIVO" : "MORTO");
  console.log(rxFresh ? "\n=> OK: comando volta. App saudável." : "\n=> FALHA: comando não volta. Ver runbook.");
  process.exit(rxFresh ? 0 : 2);
}, 16000);

function sec() { return ((Date.now() - t0) / 1000).toFixed(1) + "s"; }
