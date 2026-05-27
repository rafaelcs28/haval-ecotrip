# Guia — Hospedar uma pessoa no Haval EcoTrip (Modelo B)

Como dar acesso a outra pessoa **sem você gerenciar os dados dela**. Cada pessoa usa
a **própria Home Assistant + broker MQTT**; a instância que você hospeda no seu Mac
**conecta no broker dela via Tailscale**. Você só cadastra o email — ela configura o
resto sozinha.

```
  CASA DA PESSOA                                  SEU MAC (admin)
  Carro (APK) ─┐                                  ┌───────────────────────────┐
               ├─► Broker (Mosquitto na HA dela) ◄┤ instância dela (isolada)  │
  HA + GWM ────┘            ▲  Tailscale (100.x)  └───────────────────────────┘
                            └──────────── conexão privada ───────────┘
```

## Pré-requisitos da pessoa
- Conta **Google** ou **Apple** (pra logar — sem senha).
- **Home Assistant** própria com **broker MQTT (Mosquitto)** e a integração **GWM Brasil**
  já funcionando (o carro dela já aparece no HA dela).
- O **app do carro (APK)** instalado no Haval dela.

---

## Parte 1 — Admin (você): criar o acesso
1. App → **Ajustes → Conta & Segurança → 🛠️ Admin → Gerenciar pessoas**.
2. Preencha **apelido** (ex: `joao`, só `a-z 0-9 _`) + **email** (Google/Apple dela) → **+ Criar acesso**.
3. Mande pra ela só a **URL**: `https://mac-mini.tailacc6e7.ts.net`
   (ela entra com Google/Apple e faz todo o resto).

Pronto do seu lado. Você não gera senha, não toca no broker, não vê os dados dela.

---

## Parte 2 — Pessoa: ligar a Home Assistant no Tailscale
O seu Mac precisa **alcançar** o broker da HA dela. Isso é feito pelo **Tailscale**
(uma rede privada virtual — cada aparelho ganha um IP fixo `100.x.y.z` e se enxergam
como se estivessem na mesma rede, mesmo em casas diferentes).

1. Na Home Assistant: **Configurações → Add-ons → Loja de Add-ons → Tailscale → Instalar**.
2. **Iniciar** o add-on → abrir os **Logs / Web UI** → **autenticar** com a conta Tailscale **dela**
   (ela cria uma conta grátis se não tiver).
3. Anotar o **IP `100.x.y.z`** que a HA recebeu (aparece no add-on ou em
   [login.tailscale.com](https://login.tailscale.com) → Machines).
4. **Compartilhar a HA com o admin** (mantendo a conta dela):
   - Em [login.tailscale.com](https://login.tailscale.com) → **Machines** → a máquina da HA → menu **⋯ → Share** →
     gerar o **link de compartilhamento** e enviar pro admin.
   - O **admin aceita** o link → o seu Mac passa a alcançar **só esse nó** (a HA), nada mais.
   - *(Alternativa: o admin convida a pessoa pra tailnet dele.)*

> Privacidade: com o **Share**, você (admin) só alcança a HA compartilhada. Não vê o
> resto da rede dela, e ela não vê a sua.

---

## Parte 3 — Pessoa: configurar no app (auto-serviço)
1. Abrir a **URL** → **Entrar com Google** ou **Apple** (a conta cadastrada).
2. Ir em **Ajustes → Veículo → 📡 Conexão** e preencher:

| Campo | O que pôr |
|---|---|
| **Broker — host** | o **IP `100.x.y.z` da HA dela** (Tailscale) — *não* o `192.168` |
| **Broker — porta** | `1883` (padrão do Mosquitto) |
| **Broker — usuário / senha** | o usuário/senha do **MQTT da HA dela** |
| **Prefixo MQTT** | ex. `haval/ecotrip` (anote — vai usar **igual** no carro) |
| **Chassi** | o chassi do carro dela (`lgw` + 14) |
| **Home Assistant — URL** | `http://100.x.y.z:8123` (a HA dela via Tailscale) |
| **Home Assistant — token** | token de longa duração (HA → **Perfil → Tokens de Acesso de Longa Duração**) |

3. **Salvar e conectar** → o status deve virar **🟢 conectado** (a instância reinicia uns segundos).

---

## Parte 4 — Pessoa: apontar o app do carro (APK)
No carro, abra o app → **Ajustes → MQTT**:
- **Host**: o broker da HA dela — pode ser o **IP local** dela (`192.168.x`, já que o carro
  está na mesma casa) **ou** o `100.x` do Tailscale.
- **Porta**: `1883` · **Usuário/Senha**: do Mosquitto dela · **Prefixo**: o **mesmo** da Parte 3.
- Salvar.

---

## Pronto ✅
O carro publica no broker da HA dela → o bridge hospedado no seu Mac lê via Tailscale →
o **app dela** mostra tudo (telemetria, recarga, viagens, Live Activities). Comandos
remotos (motor, pré-clima, tranca) funcionam com a **HA URL + token** preenchidos.

**2FA (opcional):** a pessoa pode ativar em Conta & Segurança.

**Sair:** Ajustes → Conta & Segurança → 🚪 Sair desta conta.
