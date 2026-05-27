# Guia — Hospedar uma pessoa no Haval EcoTrip (Modelo B)

Como dar acesso a outra pessoa **sem você gerenciar os dados dela**. Cada pessoa usa
a **própria Home Assistant + broker MQTT**. O broker dela fica **exposto na internet
com TLS** (porque o carro é móvel e fala com o broker pela internet); o **carro dela**
e a **instância que você hospeda** se conectam **nesse mesmo broker**. Você só cadastra
o email — ela configura o resto sozinha.

```
  Carro dela ──TLS pública (8883)──►  Broker dela (Mosquitto na HA, DDNS público)  ◄──TLS (8883)── Instância dela (seu Mac)
  HA + GWM   ──────────────────────►              ▲ o mesmo broker recebe tudo
```

> **Por que público + TLS?** O carro não tem como entrar numa rede privada (anda por aí,
> 4G/Wi-Fi). Então ele alcança o broker pela internet. Pra não trafegar senha/dados em
> aberto, o broker precisa de **TLS**. É o mesmo esquema que o admin já usa.

## Pré-requisitos da pessoa
- Conta **Google** ou **Apple** (pra logar — sem senha).
- **Home Assistant** própria com **broker MQTT (Mosquitto)** e a integração **GWM Brasil**
  já funcionando (o carro dela já aparece no HA dela).
- O **app do carro (APK)** instalado no Haval dela.
- Um jeito de **expor o broker na internet**: IP fixo ou **DDNS** (ex. DuckDNS) +
  **redirecionamento de porta** no roteador pra porta do Mosquitto.

---

## Parte 1 — Admin (você): criar o acesso
1. App → **Ajustes → Conta & Segurança → 🛠️ Admin → Gerenciar pessoas**.
2. **Apelido** (ex: `joao`, só `a-z 0-9 _`) + **email** (Google/Apple dela) → **+ Criar acesso**.
3. Mande pra ela só a **URL**: `https://mac-mini.tailacc6e7.ts.net`.

Pronto do seu lado — você não gera senha, não toca no broker, não vê os dados dela.

---

## Parte 2 — Pessoa: expor o broker com TLS
1. Ter um **DDNS** (ex. add-on DuckDNS no Home Assistant) apontando pro IP de casa.
2. Ativar **TLS** no Mosquitto: com o add-on DuckDNS/Let's Encrypt, gerar o certificado e
   apontar o Mosquitto pra ele (listener **8883** com `certfile`/`keyfile`).
3. No **roteador**, redirecionar a **porta 8883** (externa) → IP local da HA : 8883.
4. Garantir um **usuário/senha** no Mosquitto (sem login anônimo).

> Resultado: o broker fica acessível em `meu-ddns.duckdns.org:8883` com TLS + senha.

---

## Parte 3 — Pessoa: configurar o app (auto-serviço)
1. Abrir a **URL** → **Entrar com Google** ou **Apple** (a conta cadastrada).
2. **Ajustes → Veículo → 📡 Conexão** e preencher:

| Campo | O que pôr |
|---|---|
| **Broker — host** | o **DDNS público dela** (ex. `meu-ddns.duckdns.org`) |
| **Broker — porta** | `8883` |
| **TLS** | **ligado** |
| **Broker — usuário / senha** | o usuário/senha do Mosquitto dela |
| **Prefixo MQTT** | ex. `haval/ecotrip` (anote — vai usar **igual** no carro) |
| **Chassi** | o chassi do carro dela (`lgw` + 14) |
| **Home Assistant — URL** | a URL da HA dela (acessível pelo Mac — DDNS ou rede) |
| **Home Assistant — token** | token de longa duração (HA → **Perfil → Tokens**) |

3. **Salvar e conectar** → status vira **🟢 conectado** (a instância reinicia uns segundos).

---

## Parte 4 — Pessoa: apontar o app do carro (APK)
No carro, abra o app → **Ajustes → MQTT**:
- **Host**: o **mesmo DDNS** do broker dela.
- **Porta**: `8883` · **TLS: LIGADO** · **Usuário/Senha**: do Mosquitto dela ·
  **Prefixo**: o **mesmo** da Parte 3.
- Salvar.

> A **regra de ouro**: o **prefixo** tem que ser **idêntico** no carro e na tela Conexão —
> é o "canal" que o carro publica e o Mac escuta.

---

## Como o link funciona
O **broker é o ponto de encontro** — o carro e o Mac **nunca falam direto**:
- O **carro publica** a telemetria no broker (pela internet, TLS).
- O **Mac (instância dela) assina** o mesmo broker e **lê** tudo → alimenta o app dela.
- A **HA + GWM dela** também publicam no mesmo broker (estados e comandos).

Comandos remotos (motor, pré-clima, tranca) funcionam com a **HA URL + token** preenchidos.

**2FA (opcional):** Ajustes → Conta & Segurança. **Sair:** 🚪 Sair desta conta.
