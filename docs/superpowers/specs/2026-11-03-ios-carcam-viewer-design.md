# Viewer iOS da dashcam CarCam

## Intenção

Adicionar a dashcam ao fluxo existente **Escuta do carro → Câmeras ao vivo**. O usuário escolhe entre a câmera Haval existente e a dashcam, inicia a transmissão manualmente e vê vídeo H.264 com áudio no iPhone.

## Escopo

- Manter `CameraVideoView` como única entrada e adicionar um seletor `Haval`/`Dashcam`.
- Encerrar a sessão ativa antes de trocar de fonte ou fechar a tela; nunca manter as duas fontes conectadas.
- Usar WHEP/WebRTC nativo, somente receptor, sem `WKWebView`, STUN, TURN, trickle ICE ou fallback público.
- Fixar o bridge em `https://100.105.51.56:8443` e o pin SPKI observado `sha256/xrgHHco8oU6hgRpPvXv2qflSUKzUkmXmi/uQKl+evxA=`.
- Reutilizar o token atual do EcoTrip, copiando-o para um item próprio do Keychain antes do uso. Nunca versionar ou registrar o valor.
- Mostrar falhas de autenticação, viewer ocupado, bridge/câmera indisponível e timeout como estados recuperáveis por tentativa manual.

## Fora do escopo

- Configuração editável, múltiplos Galaxy, descoberta automática, gravação local, segundo viewer, retry automático ou mudança no bridge Android.
- Validar a câmera física sem o carro, Galaxy e dashcam disponíveis.

## Abordagens

1. **Seletor na tela atual — escolhido.** Menos navegação, mantém a entrada existente e impede sessões simultâneas.
2. Tela intermediária com dois cards. Mais simples internamente, mas adiciona um toque e fragmenta o fluxo pedido.
3. Dois players simultâneos. Rejeitado por banda, áudio concorrente e limite de uma sessão CarCam.

## Arquitetura

`CarCamViewerSession` é o estado `@MainActor`. Ele usa `CarCamWHEPClient` para HTTPS autenticado e pinado e `CarCamPeerConnection` para oferta, ICE completo, answer e tracks. `CarCamVideoSurface` apenas hospeda `RTCMTLVideoView`. O token vem de `Settings.bridgeToken`, é sincronizado para `CarCamCredentialStore` no Keychain e só então entregue ao cliente WHEP.

TLS aceita somente desafio `serverTrust` do host fixo, certificado EC P-256 válido e pin SPKI em comparação constante. Redirect, host diferente, certificado/pin ausente ou divergente falham antes de adicionar `Authorization`. `Location` deve ser HTTPS no host e porta esperados e só vive durante a sessão.

## Aceite

- Um áudio e um vídeo `recvonly`; POST só após ICE completo.
- `201 application/sdp` aplica answer e inicia mídia; Stop envia no máximo um DELETE e fecha tudo.
- Saída da tela, falha, troca de fonte e cancelamento limpam sessão local e remota.
- Sem Tailscale não há fallback público. `401`, `409`, `502`, `503` e `504` aparecem sem loop.
- Nenhum token, SDP ou `Location` aparece em logs, testes, commits ou analytics.
