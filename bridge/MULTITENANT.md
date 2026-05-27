# Hospedagem multi-tenant (até 3 pessoas) — porteiro Google-only

Hospedar outras pessoas no **mesmo servidor** e na **mesma URL**, com **dados 100%
isolados** e **login só por conta Google** (sem senha) + 2FA opcional. Cada pessoa
roda em casa o **APK do carro** + a **Home Assistant + GWM dela**; você hospeda o
**bridge** dela (instância isolada) atrás de um **porteiro** (`gateway.js`).

## Arquitetura

```
                              SEU SERVIDOR
  ┌──────────┐  Funnel 443  ┌───────────────────────────────────────────┐
  │ App/Web  │─────────────▶│  gateway.js  (porta 4000)                  │
  │ (login   │  Google login│   • tela de login: "Entrar com Google"     │
  │  Google) │◀────────────▶│   • roteia por EMAIL (tenants/registry.json)│
  └──────────┘   cookie      │   • cookie assinado → proxy HTTP + /ws     │
                             │        │email→porta                        │
                             │        ▼                                    │
                             │  ecotrip-rafael :3000  (DATA_DIR=bridge/)   │
                             │  ecotrip-joao   :3001  (tenants/joao/)      │
                             │  ecotrip-maria  :3002  (tenants/maria/)     │
                             └───────────────────────────────────────────┘
  Carro+APK ─ssl://broker:8883─▶ Broker TLS (haval/<nome>/# por ACL)
  Home Asst.─ssl://broker:8883─▶          (gwmbrasil_<chassi>/# por ACL)
  Home Asst.◀── REST (HA_URL/TOKEN) ── bridge do tenant (comandos)
```

**Isolamento:** dados (`tenants/<nome>/`), MQTT (prefixo + usuário/ACL), token de API
e tokens APNs — tudo separado por instância. O porteiro só roteia; a verificação do
login Google + whitelist de email acontece no backend de cada tenant.

**Por que Google-only é mais seguro:** nenhuma senha é guardada/gerenciada por nós;
a autenticação (senha forte, 2FA, detecção de fraude, recuperação) fica com o Google;
cada instância só aceita o email daquela pessoa (`GOOGLE_ALLOWED_EMAILS`) e verifica o
ID token assinado. 2FA (TOTP) opcional por cima, por instância.

## Setup único (uma vez)

1. **Broker com TLS público** — listener `:8883` com cert válido (Let's Encrypt) +
   `:1883 localhost` pro leg bridge↔broker. Ex. Mosquitto:
   ```
   listener 8883
   certfile /etc/letsencrypt/live/SEU.DOMINIO/fullchain.pem
   keyfile  /etc/letsencrypt/live/SEU.DOMINIO/privkey.pem
   listener 1883 localhost
   password_file /etc/mosquitto/passwd
   acl_file /etc/mosquitto/aclfile
   allow_anonymous false
   ```
   Abra a 8883 no roteador/firewall.

2. **Porteiro** + **Funnel apontando pra ele** (não mais pro bridge direto):
   ```bash
   cd bridge
   GATEWAY_PORT=4000 pm2 start gateway.js --name ecotrip-gateway --update-env
   pm2 save
   tailscale funnel --bg --https=443 localhost:4000   # repontar 443 → porteiro
   ```
   O porteiro lê `GOOGLE_OAUTH_CLIENT_ID` do `.env` principal e `tenants/registry.json`
   (você já está nele: `rafaelcs28@gmail.com → 3000`). Recarrega o registry sozinho.

   > A partir daqui, **você também** entra com Google (sua conta já está na whitelist
   > do bridge :3000). O `:8443`/`:10000` não são mais necessários — tudo na 443.

## Onboarding de uma pessoa

Colete: **email Google** dela, **chassi** do carro, e (depois) **HA_URL + token** da HA dela.

```bash
cd bridge
./new-tenant.sh <nome> <email> <chassi> <porta>
#   ex: ./new-tenant.sh joao joao@gmail.com 9xyz88 3001
```

Gera `tenants/<nome>/.env` (chmod 600, fora do git), registra `email→porta` em
`registry.json` e **imprime os passos**: broker (usuário+ACL), `pm2 start`, e o bloco
pra entregar à pessoa. Depois:

```bash
ECOTRIP_DATA_DIR="$PWD/tenants/<nome>" pm2 start server.js --name ecotrip-<nome> --update-env
pm2 save
```

### A pessoa (em casa)

1. **Acessa** `https://mac-mini.tailacc6e7.ts.net` → **Entrar com Google** (a conta dela).
   2FA opcional depois em Ajustes → Segurança.
2. **APK do carro** → Ajustes → MQTT: Host = seu broker público, Porta **8883**,
   **TLS = ON**, Usuário/Senha = os gerados, Prefixo = `haval/<nome>`.
3. **Home Assistant dela** → integração MQTT no **mesmo broker** (8883/TLS, mesmas
   credenciais) → estados `gwmbrasil_<chassi>` chegam ao seu broker. Te passa
   `HA_URL`+token → cola no `.env` + `pm2 restart ecotrip-<nome> --update-env`.

## Operação

- `pm2 save` mantém tudo no boot (cada processo com seu `ECOTRIP_DATA_DIR`).
- Atualizar código: `git pull` + `pm2 restart all` — **uma** vez vale pra todos (código
  compartilhado; só dados são por tenant).
- Remover tenant: `pm2 delete ecotrip-<nome>` + apagar `tenants/<nome>/` + tirar do
  `registry.json` + remover usuário/ACL no broker.

## Segurança

- `tenants/` no `.gitignore` (segredos + dados pessoais + `gateway_secret`).
- Backends só escutam em `localhost` — só o porteiro é exposto (Funnel).
- Sem senha em lugar nenhum: login delegado ao Google; o `BRIDGE_TOKEN_HASH` é só um
  token de API opaco (a pessoa nunca o vê, recebe via login).
- Cookie de roteamento é assinado (HMAC); ainda que forjado, cai num backend que exige
  o token de API certo.

## Atenção — login Google no app iOS (WKWebView)

O app iOS carrega a PWA num WKWebView, que **já** tem o botão Google. O Google às vezes
bloqueia OAuth em webview embutida ("disallowed_useragent"). **Testar antes de ir Google-only:**
abrir o app, sair, tocar em "Entrar com Google" e confirmar que conclui. Se não concluir,
manter um fallback de senha ou fazer Sign-In nativo no app iOS antes de flipar a 443.
