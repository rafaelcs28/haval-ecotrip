# EcoTrip camera: LAN preferencial com fallback confirmado

## Intenção

Entregar vídeo ao vivo e gravações do Haval Camera no EcoTrip do iPhone. Quando iPhone e carro estiverem na mesma rede Wi-Fi, os bytes devem ficar na LAN. Quando a LAN não estiver disponível, o usuário pode autorizar o uso da internet. A mudança aproveita a descoberta Bonjour e o servidor local existentes no EcoTrip, sem tornar o Haval Camera dependente do telefone.

## Escopo da entrega

- Haval Camera Android: gravação corrigida, produção HVC1 para relay local restrito e leitura segura de segmentos concluídos.
- EcoTrip Android do carro: integração IPC com Haval Camera, sessão LAN autenticada, relay HVC1 local e download HTTP com Range.
- Bridge: sessões remotas ao vivo e transferência de gravações, sem persistir bytes de vídeo.
- EcoTrip iOS: viewer, galeria, download e seleção automática LAN/remoto.
- Distribuição: APKs assinados do Haval Camera e EcoTrip instalados juntos; EcoTrip iOS enviado ao TestFlight.

## Comportamento escolhido

1. Ao tocar em **Ver ao vivo**, o iPhone procura `_havalobd._tcp` por uma janela curta.
2. Se o serviço LAN responder e autenticar, o iPhone abre uma sessão local e exibe `LAN` na tela.
3. Se a LAN não estiver disponível no início, o app pede confirmação antes de criar uma sessão pela internet.
4. Se a LAN cair durante a reprodução, o quadro é limpo, a sessão local é encerrada e o app pede confirmação antes de usar internet. Nunca troca silenciosamente para dados móveis.
5. Se o usuário recusar, o vídeo fica parado e pode ser tentado novamente.
6. A autorização para internet vale somente enquanto aquela ação de live ou download permanecer aberta. Renovação e reconexão remota da mesma ação podem reutilizá-la. Fechar a ação, voltar à LAN ou iniciar outro vídeo/download invalida o consentimento; uma nova transição LAN→internet pergunta novamente.
7. Gravações usam LAN primeiro. Sem LAN, o app pede confirmação antes do download remoto. O arquivo parcial pode retomar somente no mesmo transporte e identidade de gravação; trocar transporte inicia uma transferência autenticada compatível, sem misturar bytes.
8. O Haval Camera continua utilizável sozinho na multimídia para câmera, gravação, reprodução, configurações e compartilhamento temporário.

## Abordagens consideradas

### 1. Relay LAN no EcoTrip Android — escolhida

Reutiliza `_havalobd._tcp`, `LANDiscovery` e `LocalApiServer`. O EcoTrip Android autentica o iPhone com o token já pareado, controla o Haval Camera por IPC assinado e retransmite HVC1 sem decodificar. É o único caminho local anunciado ao iPhone.

Vantagens: uma descoberta, uma configuração LAN e integração com o fallback existente. Custo: o EcoTrip Android precisa de relay binário limitado e testes de pressão.

### 2. Servidor LAN próprio no Haval Camera

Reduz um salto local, mas duplica Bonjour, autenticação, configuração e lifecycle. Também contraria a decisão de aproveitar a ponte EcoTrip existente. Rejeitada.

### 3. Sempre usar o bridge

Mantém apenas WSS remoto, porém desperdiça dados e aumenta latência quando os dispositivos estão na mesma rede. Rejeitada.

## Arquitetura

### Descoberta e seleção de rota

`LANDiscovery` continua resolvendo `_havalobd._tcp`. Um roteador de vídeo puro recebe estado LAN, preferência do usuário e evento de falha, e decide entre `lan`, `askInternet` e `offline`. O viewer não constrói URLs por conta própria.

O iOS usa HTTPS/WSS somente no caminho remoto. O caminho local aceita HTTP/WS somente para o host e porta recém-resolvidos por Bonjour. URLs locais recebidas do servidor devem corresponder exatamente a esse endpoint, sem credenciais, fragmento ou redirecionamento.

### Sessão LAN ao vivo

O iPhone nunca envia seu token longo para o endpoint descoberto por Bonjour. Primeiro pede um desafio contendo `carId`, nonce aleatório e expiração máxima de 30 segundos. Ele responde com `HMAC-SHA256(bridgeToken, "haval-camera-lan-v1|carId|nonce|expiresAt")`. O EcoTrip Android calcula e compara o HMAC em tempo constante, exige o mesmo `carId` pareado, aceita o nonce uma única vez e não registra desafio, resposta ou token. Isso autentica posse do segredo sem expô-lo a um serviço Bonjour falso.

Após autenticar o desafio, o EcoTrip Android cria identificador e credenciais aleatórias curtas, limita a uma sessão de produtor e uma de viewer e devolve a URL local de viewer. A sessão não reutiliza o HMAC como token de mídia.

O EcoTrip Android envia `START_LIVE` ao Haval Camera pela permissão de assinatura. Para relay local, o Haval Camera aceita `ws://127.0.0.1` somente neste contrato IPC assinado, com porta local válida, sessão única, token de tamanho limitado e expiração máxima de 30 minutos. Qualquer host não loopback continua exigindo WSS. O token segue somente no header `Authorization`.

O relay local valida framing HVC1, tamanho máximo de 4 MiB, ordem CONFIG/keyframe e fila limitada. Pressão descarta deltas e solicita novo keyframe; nunca bloqueia a gravação. O relay não grava nem transforma frames.

### Sessão remota

Mantém o contrato já implementado: iOS cria sessão no bridge, bridge envia credencial curta ao EcoTrip Android, EcoTrip controla Haval Camera por IPC, Haval Camera produz HVC1 por WSS e o iOS recebe pelo viewer WSS. A confirmação de internet acontece antes de criar a sessão.

### Gravações

Somente viagens concluídas aparecem. Na LAN, o EcoTrip Android lê catálogo e segmentos pelo provider protegido do Haval Camera e expõe metadados e bytes ao iPhone após autenticação. IDs são validados; caminhos de arquivo nunca vêm do cliente. HTTP Range é limitado ao tamanho do segmento e mantém lease durante a leitura.

Fora da LAN, o bridge coordena HVT1 com tokens curtos, chunks limitados, ACK e retomada. O bridge nunca persiste bytes. O iOS verifica tamanho e SHA-256 antes de promover o arquivo baixado. Transferência e live obedecem ao limite existente: live pausa transferência.

Antes de implementar transferência, `docs/VIDEO_PROTOCOL.md` passa a fixar HVT1 versão 1 em nível de bytes: header big-endian, tipos DATA/EOF/ACK/ERROR, ordinal do segmento, offset `u64`, comprimento, SHA-256 de 32 bytes, limites e fixtures idênticas para Java, Node e Swift. Hoje existe somente o contrato comportamental no plano; nenhum runtime pode inventar framing isoladamente.

### Correção de gravação

O carro observado possui cerca de 2,4 GB livres, enquanto a reserva legada é 5 GB. O Haval Camera passará a oferecer reserva de 1 GB e usará 1 GB como padrão para novas instalações. Na instalação final deste carro, o EcoTrip/Haval Camera aplicará explicitamente 1 GB pela API de configurações, sem apagar gravações. Reservas maiores continuam disponíveis.

O primeiro erro do pipeline permanece visível. Erros secundários como `Muxer is closed` não substituem `Reserva de armazenamento indisponível`. A validação física exige MP4 real de aproximadamente 10 segundos, duração legível, bytes maiores que zero e catálogo concluído.

## Segurança

- Token LAN obrigatório nos novos endpoints de câmera; restrição por IP privado sozinha não basta.
- Comparação de token em tempo constante quando disponível na plataforma; nenhum token em URL, log ou Git.
- Uma sessão LAN de viewer e uma de produtor; expiração, encerramento explícito e limpeza após desconexão.
- Filas e mensagens limitadas; cliente lento não bloqueia encoder, gravação, telemetria ou controles.
- Caminho remoto permanece TLS/WSS e com credenciais de escopo curto.
- Somente segmentos concluídos podem ser lidos. Arquivos parciais, viagem ativa e caminhos arbitrários são recusados.
- Nenhum fallback para internet acontece sem confirmação no iPhone.
- Nenhuma instalação silenciosa. APKs preservam o certificado aprovado; iOS usa assinatura Apple e TestFlight.

## UI

- Viewer mostra `LAN` ou `Internet` e latência estimada.
- Antes de usar internet: confirmação informa consumo aproximado da qualidade selecionada.
- Queda da LAN limpa o último quadro e apresenta **Usar internet** e **Cancelar**.
- Galeria mostra rota usada no download, progresso, retomada e erro compreensível.
- Configurações existentes de gravação, live remoto, downloads remotos, qualidade, retenção e carimbos continuam sendo a fonte de verdade do Haval Camera e ficam editáveis no EcoTrip.

## Falhas e fallback

- Descoberta LAN ausente: pedir internet, sem tentativa local infinita.
- Autenticação LAN recusada: não cair silenciosamente para remoto; mostrar erro e oferecer internet.
- Queda local: encerrar credenciais locais, limpar decoder e pedir confirmação.
- Bridge indisponível: mostrar carro offline/serviço indisponível; não reutilizar quadro antigo.
- Haval Camera ausente ou desabilitado: EcoTrip continua telemetria, viagens e controles normalmente.
- Falha de gravação ou transferência nunca encerra viagem EcoTrip.

## Compatibilidade e rollout

O Haval Camera e o EcoTrip Android precisam do mesmo certificado de assinatura para permissões IPC. A ordem final é: bridge compatível primeiro; builds assinados e verificados; instalação conjunta dos dois APKs no carro; teste local; teste remoto autorizado; depois envio iOS ao TestFlight. O iOS mantém compatibilidade com carros sem endpoints LAN de câmera: descoberta de telemetria pode funcionar, mas vídeo local é considerado indisponível e o app oferece internet.

O servidor LAN expõe uma resposta de capacidades versionada. `cameraLiveLan=1`, `cameraDownloadLan=1`, `hvcVersion=1` e `hvtVersion=1` habilitam cada fluxo. Campos ausentes significam recurso indisponível, nunca uma versão implícita. Bridge e APIs remotas recebem somente extensões aditivas. Assim, iOS novo funciona com carro antigo pelo bridge; carro novo funciona com iOS antigo sem ativar câmera LAN; rollback de qualquer app remove apenas a capacidade correspondente.

O bridge deve ser compatível com clientes anteriores durante o rollout. Novos endpoints ou campos são aditivos. Feature flags/configurações permitem desativar live e downloads sem afetar gravação local.

## Validação

- Testes puros de seleção de rota: LAN inicial, ausência de LAN, recusa de internet, queda da LAN e confirmação posterior.
- Testes Android do relay: autenticação, sessão única, expiração, framing HVC1, fila limitada, cliente lento, keyframe e isolamento da gravação.
- Testes de download: catálogo concluído, Range, lease, retomada, hash, traversal e parcial/ativo recusados.
- Testes Swift de parser/decoder, lifecycle, limpeza de quadro, confirmação e mudança de rota.
- Builds somente no Mac Mini autorizado. TestFlight usa Xcode 26.3, scheme `HavalEcoTrip`, Team ID `7Y6MPKR5CD` e assinatura automática. O scheme `KmDoLucro` pertence ao outro aplicativo no mesmo host e não entra neste archive.
- Carro parado: MP4 de 10 segundos; live LAN na mesma Starlink; queda de Wi-Fi sem fallback silencioso; live remoto após confirmação; download LAN e remoto; reinício dos apps; nenhum crash.
- Registrar commits, hashes dos APKs, certificado, build TestFlight e limitações físicas.

## Não objetivos

- Selecionar câmeras individuais; o firmware comprovou somente a composição 3D atual no app.
- Sentry mode ou ligar o carro remotamente.
- Persistir vídeo no bridge.
- Tornar EcoTrip obrigatório para uso local do Haval Camera.
- Trocar automaticamente para internet sem consentimento.

## Decisões do construtor

- Reutilizar tipos HVC1/HVT1 e contratos já revisados; não criar outro formato.
- Extrair controladores puros somente onde permitirem testes reais de rota/lifecycle.
- Usar dependências já presentes. Nova biblioteca exige justificativa e revisão explícita.
- Aplicar a menor mudança compatível em cada repositório e revisar cada fronteira separadamente.
