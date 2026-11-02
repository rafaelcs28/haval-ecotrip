# Relay de vídeo ao vivo

O bridge coordena uma sessão autenticada e encaminha mensagens HVC1 em memória.
Ele não transcodifica, grava, inspeciona o payload AVC nem mantém fila de vídeo.

## Fluxo

1. O proprietário chama `POST /api/video/live/session` com a autenticação normal.
2. O bridge cria tokens aleatórios separados para produtor e visualizador.
3. O token do produtor segue ao EcoTrip em `cmd/video_live_start` via MQTT.
4. Haval Camera conecta em `/ws/video/live/car`.
5. O visualizador conecta em `/ws/video/live/viewer` com a credencial retornada.
6. `DELETE /api/video/live/session/:id` encerra a sessão e publica `cmd/video_live_stop`.

Os dois tokens são de uso único e aceitos por 60 segundos. A sessão termina após
30 minutos, desconexão de qualquer ponta ou encerramento explícito. Existe somente
um produtor, um visualizador e uma sessão ativa por instância do bridge.
Cada WebSocket envia seu token separado no header `Authorization: Bearer`; tokens
não entram na URL.

## Limites

- Mensagem HVC1: cabeçalho de 24 bytes e payload de 1 a 4.194.304 bytes.
- Buffer do visualizador: máximo de 1 MiB antes de descartar frames novos.
- O bridge nunca bloqueia o produtor por causa do visualizador.
- Após descarte ou entrada do visualizador, o produtor recebe
  `{"type":"request_keyframe"}`.
- Payloads, tokens e URLs com tokens não entram em logs.

`BRIDGE_PUBLIC_URL` define a origem `wss://` entregue ao carro e ao visualizador.
O fallback preserva a origem pública já usada pelo pareamento do bridge.
Upgrade sem TLS direto, ou sem `X-Forwarded-Proto: https` do gateway, recebe `426`.

## Encerramento e códigos WebSocket

Os códigos `4000` a `4008` seguem `docs/VIDEO_PROTOCOL.md` do Haval Camera.
Rotas existentes `/ws`, `/ws/audio`, `/clockin` e OCPP continuam no mesmo roteador
manual de upgrade.
