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
Ela deve usar `https://`; qualquer outro esquema falha fechado. O fallback preserva
a origem HTTPS pública já usada pelo pareamento do bridge.

TLS nativo é aceito diretamente. `X-Forwarded-Proto: https` só é aceito quando o
IP imediato consta em `VIDEO_TRUSTED_PROXY_IPS`, lista explícita separada por
vírgulas. Upgrade sem TLS confiável recebe `426`; tentativas inválidas recebem
limite por IP antes do handshake WebSocket.

Criar ou encerrar uma sessão só retorna sucesso depois do resultado MQTT
correlacionado por `requestId`, emitido pelo EcoTrip após `APPLIED` ou `NO_OP` da
Camera. Callback de publicação MQTT não confirma execução.

## Encerramento e códigos WebSocket

Os códigos `4000` a `4008` seguem `docs/VIDEO_PROTOCOL.md` do Haval Camera.
Rotas existentes `/ws`, `/ws/audio`, `/clockin` e OCPP continuam no mesmo roteador
manual de upgrade.

## Catálogo e configurações remotos

Todas as rotas `/api/video/*` usam o mesmo `requireAuth` das rotas existentes.
Cada instância atende um carro/tenant; os limites de sessão valem por instância.
`GET /api/video/catalog` retorna `{ok, catalogRevision, updatedAt, trips, stale}`.
Sem catálogo, retorna lista vazia, revisão/data zero e `stale: true`.
`stale` fica verdadeiro após cinco minutos sem snapshot recente. O bridge não
substitui `updatedAt` do carro pela hora de chegada de uma mensagem MQTT retida.

O tópico já publicado pelo EcoTrip é `<prefix>/video/catalog`; o alias aditivo
`<prefix>/video_catalog` também é aceito. O payload é um snapshot completo:

```json
{"ok":true,"catalogRevision":1,"updatedAt":1700000000000,"trips":[{"tripId":"42","source":"automatic","startMs":1000,"endMs":2000,"byteSize":3,"completed":true,"segments":[{"segmentId":1,"byteSize":3,"sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}]}]}
```

O exemplo contém apenas metadados sintéticos. IDs de viagem são strings decimais
positivas; ordinais são inteiros consecutivos a partir de 1. Tamanhos JSON exigem
inteiros seguros, positivos por segmento; a soma deve coincidir com `byteSize`.
Viagens ativas (`completed: false` ou `endMs: null`) não aparecem. Revisões antigas,
`updatedAt` regressivo e conteúdo diferente na mesma revisão são rejeitados.
Uma mesma revisão com conteúdo idêntico pode atualizar a data. Todo snapshot é
validado antes de substituir o anterior; exclusões por retenção chegam na próxima
revisão e invalidam transferências que perderam a identidade/tamanho/hash.

Compatibilidade: o EcoTrip atual publica `segments` como contagem e não inclui
`completed`; a consulta ao provider já contém somente viagens concluídas. Esses
resumos continuam disponíveis. Transferência exige o array aditivo de segmentos
com tamanho e SHA-256; resumo antigo retorna `409 video_segment_metadata_unavailable`.
Metadados completos do Camera podem incluir `fileName: "000001.mp4"`, tempos e
codec AVC validado; esses campos locais são descartados. Caminhos, campos extras,
bytes/chunks/miniaturas e snapshots maiores que 1 MiB são recusados.

`GET /api/video/settings` retorna `{revision, settings, updatedAt, stale}`, último
snapshot completo confirmado no tópico `<prefix>/video/settings`. Sem confirmação,
retorna `503 video_settings_unavailable`. `PATCH /api/video/settings` recebe:

```json
{"expectedRevision":1,"patch":{"reserveGb":1,"remoteDownloads":true}}
```

A fonte de verdade continua sendo o provider Camera. O patch exige revisão segura
não negativa e pelo menos uma chave válida. Aceita os 11 booleanos do Camera,
`quality` (`economy`, `standard`, `high`), `reserveGb` (1, 5, 10, 20 GiB) e
`overlayPosition` (`top_left`, `top_right`, `bottom_left`, `bottom_right`).
O bridge envia `video_settings_update` com `requestId`, `expectedRevision` e `patch`.
Só o resultado correlacionado com snapshot válido confirma a alteração. Conflito
retorna `409` com o estado confirmado atual; carro offline/timeout retorna `503`
e nunca aplica o patch solicitado localmente. A revisão de settings é independente
da revisão de catálogo. O leitor Android antigo ainda rejeita reserva 1; esse
cliente precisa da extensão prevista na entrega Android antes de aplicar 1 GiB.

`DELETE /api/video/recordings` recebe
`{"tripIds":["42"],"confirmation":"DELETE_COMPLETED"}`. A frase literal registra
confirmação explícita do proprietário; não é credencial de autenticação.
A rota valida até 256 IDs distintos concluídos, recusa viagem em transferência ou
exclusão concorrente com `409` e envia `video_delete` com os mesmos campos e
`requestId`. Só retorna `204` depois da confirmação do carro. A lista não é removida
por otimismo: espera o snapshot autoritativo seguinte. O cliente Android atual
não implementa `video_delete`; sua extensão é requisito de rollout separado.

Somente catálogo e settings validados são gravados como JSON por substituição
atômica em `ECOTRIP_DATA_DIR/video_metadata.json` (ou DATA_DIR legado). Falha ao
gravar mantém a revisão anterior. Leitura de boot é limitada e revalidada. Nada de
sessão, token, offset parcial, socket ou payload HVC1/HVT1 entra nesse arquivo.
Nenhuma rota de vídeo usa `rec_cache`, upload HTTP, `express.raw` ou arquivo MP4.

## Transferência HVT1

`POST /api/video/transfer/session` recebe
`{"tripId":"42","segmentIds":["1"]}`. Exige metadados completos e permite até
256 segmentos distintos. Retorna `201` com `sessionId`, `viewerUrl`, `viewerToken`,
`connectExpiresAt`, `expiresAt` e `offsets` (strings decimais). O token de produtor
segue somente para o carro. Existe no máximo uma transferência por instância,
além da sessão live existente; uma segunda seleção retorna `409`.
`remoteDownloads: false` confirmado impede criar ou renovar transferência.

O comando `video_transfer` contém `requestId` exclusivo por tentativa,
`sessionId`, `viewerSession` (mesmo ID), `tripId`, `segmentIds`, `sessionUrl`,
`producerToken`, `expiresAt`, `offsets`, `completedSegmentIds` e `paused`.
As adições de URL/token/offsets são o contrato para o produtor da próxima tarefa;
o handler Android legado ainda não consome esses campos.
Cada tentativa começa com `paused: true` até o viewer conectar. Se o produtor
conectar primeiro, recebe `{"type":"pause","reason":"viewer"}`; DATA/EOF
antecipado é descartado sem ACK, retenção ou consumo do token do viewer.
Quando ambas as pontas estão prontas e não há live, o produtor recebe `resume`
com os offsets confirmados, inclusive quando o viewer conectou primeiro.
Os WebSockets são `/ws/video/transfer/car?session=ID` e
`/ws/video/transfer/viewer?session=ID`. Reutilizam o roteador e os servidores WS do
relay existente, com a mesma exigência TLS/proxy confiável e limitação de tentativas
inválidas. Tokens aleatórios de uso único duram 60 segundos e são exclusivos de
sessão, papel e protocolo. A sessão dura no máximo 30 minutos, inclusive retries.

Framing canônico: Camera `docs/VIDEO_PROTOCOL.md` no commit
`e1d0d7fc268bd9a1e0de6838e4b86f2b640ac008`. O header tem 56 bytes: magic HVT1,
versão 1, tipo DATA/EOF/ACK/ERROR, flags zero, ordinal u32, offset u64, tamanho u32,
SHA-256 binário de 32 bytes. Todos os números são big-endian. Node lê offset
com `readBigUInt64BE`; nunca passa por `Number`. ACKs com o bit alto e u64 máximo
são válidos no codec; o consumidor ainda exige ordinal/offset da seleção.
Os seis fixtures canônicos foram copiados literalmente para os testes Node.

- DATA: 1–262144 bytes, SHA-256 por chunk, offset contíguo, sem overflow u64.
- EOF: sem payload, tamanho e SHA-256 iguais aos metadados completos do segmento.
- ACK: sem payload, digest zero, offset exatamente igual ao fim pendente.
- ERROR: offset zero, 1–1024 bytes de UTF-8 estrito com SHA-256 correspondente.

O relay mantém somente contadores/metadados em memória e uma mensagem pendente
sem bytes. Encaminha o Buffer original diretamente ao `send` ativo. Permite
somente um DATA/EOF sem ACK por vez. O callback bem-sucedido do envio ao viewer é
necessário, mas não gera ACK: o viewer só envia ACK após persistir e verificar os
bytes no telefone. ACK prematuro, offset pulado, ordinal desconhecido, hash/flags/
comprimento inválido ou texto no lugar de frame fecha a tentativa com `4004`, sem
ACK nem ERROR de resposta. EOF só conclui após o ACK final do viewer; todos os
segmentos concluídos encerram a sessão com `4000`. O bridge compara o hash de EOF
com o catálogo; a verificação do arquivo completo pertence ao viewer.

Pressão acima de 1 MiB contando o próximo frame fecha a tentativa com `4007`.
Erro de send, desconexão ou ERROR válido fecha as duas pontas com `4000`; nenhum
ACK é inferido. Texto ERROR é encaminhado somente pelo socket, nunca logado.
O produtor deve usar erro seguro sem credencial, caminho ou conteúdo capturado.

Para reconectar, o proprietário repete o POST com a mesma seleção e
`sessionId`. A identidade deve coincidir; as duas pontas anteriores precisam estar
fechadas. A resposta usa tokens novos no mesmo ID, offsets exclusivamente dos ACKs
confirmados e ordinais já concluídos. Não aceita offsets escolhidos pelo cliente.
A desconexão abre janela de 60 segundos para renovar; nunca estende os 30 minutos.
Reinício do bridge perde offsets/sessões e exige uma seleção nova desde zero.

Live tem prioridade desde a reserva da sessão, antes da confirmação de start.
O produtor da transferência recebe `{"type":"pause","reason":"live"}`;
DATA/EOF em trânsito durante a pausa é descartado sem retenção/ACK. ACK pendente
pode terminar. Após confirmação de stop live, recebe
`{"type":"resume","offsets":{"1":"0"}}`. O produtor deve respeitar `paused` e
reler o último offset confirmado ao retomar. Se stop live falhar, a pausa permanece
até a expiração original do live; não se presume que a câmera parou.
Se DATA/EOF aguarda ACK durável quando live termina, `resume` espera esse ACK e
anuncia o offset atualizado. Se o ACK conclui o último EOF, a sessão encerra sem
enviar `resume`.

`DELETE /api/video/transfer/session/:id` remove estado/credenciais, fecha ambas as
pontas e aguarda `video_transfer_cancel` (`requestId`, `sessionId`). Retorna `204`
confirmado, `503` em falha de confirmação e `404` para ID ausente. Expiração,
retenção e conclusão também limpam o estado e tentam cancelamento limitado.
Resultados dos novos comandos usam `<prefix>/cmd/COMMAND/result` e o broker já
existente; publicar MQTT não confirma execução. Mensagens de vídeo/catálogo/settings
são consumidas antes do logger genérico MQTT.

## Verificação Node (coordenador permitido)

```sh
/root/.local/share/node24/bin/node --test bridge/test/video-relay.test.js
node --check bridge/video-relay.js
node --check bridge/server.js
```

Em `bridge`, `npm test` ou `npm run test:video` executa a suíte. Use Node 24.
São testes com dados sintéticos e sockets locais; não inicia o servidor de produção,
não lê segredos, não reinicia serviços e não compila Android/Gradle/Kotlin/Xcode.
