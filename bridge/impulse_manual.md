Disclaimer: USE POR SUA CONTA E RISCO. Nenhuma garantia deste aplicativo
ou seu funcionamento, sob qualquer hipótese, é fornecida. Assim como
responsabilidades sobre os impactos em garantia do veículo que possam
ser imputadas pela GWM.

Antes de iniciar, tenha certeza de que seu carro está atualizado ou a
instalação do Impulse não terá efeito:Atualização Haval H6 - GWM

Veja o passo “Revertendo o processo” antes de decidir instalar o app.

Não compatível com os modelos HAVAL H6 2026 ou HAVAL H9

NÃO DIVULGUE ESTE DOCUMENTO

COMUNIDADE HAVALEIROS BRASIL https://havaleirosbrasil.com.br

Atualizado em: 22 de dezembro de 2025, às 17:40h. Versão atual: 1.0.0.43

Desenvolvido por: https://github.com/bobaoapae e atualizado por
https://github.com/netseek

Source code disponível em:
https://github.com/bobaoapae/haval-app-tool-multimidia

Script e aplicação de instalação por: https://github.com/paulovitin

Quer ajudar? É um projeto open-source. Submeta seu PR.

Gostou do trabalho? Faça uma contribuição para o autor, que fez todo
esse trabalho sem cobrar nada por isso, mas merece reconhecimento. Mais
de um ano de pesquisas.

Atenção: esta é uma contribuição direta ao desenvolvedor, não para a
comunidade.

[]

Chave PIX

joaovitorbor@gmail.com

Sobre o Haval Impulse 2

  Impacto sobre a garantia de fábrica 3

  Segurança do veículo e interferências nos sistemas padrões 3

Orientações para Instalação do Haval Impulse 4

  Conectando no hotspot do carro 4

  Instalação automática usando um computador 5

  Dica para Windows 5

  Dica para Mac 5

  Instalação manual passo a passo 6

  Configurações disponíveis 9

  Controles do ar-condicionado no volante 13

  Atualizações 13

Instalar aplicativos adicionais 15

  Instalando Apps através do Haval Impulse 16

  Instalando a versão Preview do Haval Impulse 16

Configurações adicionais 16

Reiniciando a central multimídia 17

Revertendo o processo 17

Novidades para novas releases 19

Novidades da Release 1.0.0.43 19

Novidades da Release 1.0.0.42 19

  Novas opções de atalho para volante para controle das câmeras 19

  Novo cluster 19

  Novo controle de ar condicionado 21

  Modo MAX AUTO para ar-condicionado 21

  Escolha dos modos de regeneração de energia 22

  Gráficos 22

  Modo Plaid 23

  Problemas conhecidos 24

Sobre o Haval Impulse

O HAVAL IMPULSE é uma solução criada pela comunidade para expandir as
capacidades do seu veículo sem alterar sua estrutura básica. Ele oferece
um conjunto de funcionalidades integradas que ampliam os recursos do
veículo (veja aqui), sem custo adicional, para controle e a conveniência
do carro, além de permitir a instalação de aplicativos de terceiros com
total liberdade de escolha.

Esta é uma solução focada no Haval H6 até 2025, visto que o Haval H9 e
HAVAL H6 2026 utilizam uma nova versão do sistema operacional Coffee OS,
não compatível com esta solução. Também não se aplica para os modelos
Ora, Tank, Poer e Wey.

Antes de iniciar, tenha certeza de que seu carro está atualizado ou a
instalação do Impulse não terá efeito (a instalação será finalizada, mas
o ícone do Haval Impulse não aparecerá na Central Multimídia):

https://www.gwmmotors.com.br/pt/experience/atualizacaoota

O HAVAL IMPULSE foi criado após esforço da comunidade em realizar o
jailbreak da central multimídia. Após mais de um ano de estudos e
testes, o HAVAL IMPULSE foi criado como um processo pessoal para
contornar funcionalidades que não existiam ou não funcionavam como
esperado no Haval H6. Após esforço conjunto da comunidade HAVALEIROS
BRASIL, o instalador foi criado, assim como este guia.

É importante destacar que, embora o HAVAL IMPULSE viabilize a execução
de softwares externos e facilite seu uso na central multimídia do
veículo, não assume responsabilidade pela operação, desempenho ou
efeitos desses apps de terceiros. Ou seja, você tem autonomia para
instalar e usar as ferramentas que desejar, cuidando da compatibilidade
e da segurança conforme seu critério.

Com esta abordagem, buscamos entregar versatilidade e inovação, enquanto
mantemos clareza sobre os limites de atuação do próprio app. Nas seções
seguintes você encontrará uma visão detalhada de cada funcionalidade
incorporada, dos requisitos técnicos para instalação e de como reverter
o sistema para sua originalidade.

Conheça também a integração para Home Assistant disponível em:
https://github.com/havaleiros/hassio-haval-h6-to-mqtt

Esperamos que este documento lhe dê uma visão clara e objetiva do que o
HAVAL IMPULSE oferece e como você pode usá-lo com confiança. Em caso de
dúvidas, envie sua dúvida em qualquer grupo da nossa comunidade.

Impacto sobre a garantia de fábrica

Qualquer modificação realizada pode impactar a garantia do veículo,
especialmente em casos relacionados ao sistema da central multimídia
(CM). Por exemplo, problemas como consumo elevado de dados, lentidão ou
falhas no sistema podem não ser cobertos, caso seja identificado que
foram causados por alterações ou aplicativos instalados pelo usuário. No
caso específico do plano de dados, a justificativa pode ser de que o
consumo adicional foi gerado pelos recursos instalados.

Segurança do veículo e interferências nos sistemas padrões

Não há impacto direto na segurança do veículo. O Haval Impulse opera
apenas no nível do Android da central multimídia, sem acesso à rede
CAN-FD, que é responsável pelos controles críticos do carro. Portanto,
não há interferência no funcionamento dos sistemas veiculares
essenciais, consumo de combustível, alteração em velocidade máxima do
veículo ou qualquer outra alteração no veículo em si.

Orientações para Instalação do Haval Impulse

Conectando no hotspot do carro

No menu lateral da Central Multimídia, toque no ícone das 4 caixas.

Toque em Configurações.

[]

Depois em Hotspot. Verifique se o hotspot está ligado.

Conecte seu celular ou computador à rede Wi-Fi do carro.

Você irá precisar de conexão estável e com internet. Logo, esteja com o
veículo em um local com sinal suficiente para isso. Se seu veículo fica
em um subsolo, com certeza isto impedirá o download dos aplicativos que
deverão ser instalados para o correto funcionamento.

[A hand holding a car key AI-generated content may be incorrect.]

Certifique-se que o carro tem uma conexão 4G estável. Caso contrário
você não terá sucesso no processo de instalação.

[]

Instalação automática usando um computador

Disponível em:
https://github.com/tontonhaval/haval-tool/releases/tag/app-v0.1.2

Baixe a versão de acordo com o sistema operacional de seu computador -
Isto não pode ser utilizado em celulares.

Exemplo: *.exe para Windows, *.dmg para Mac - sendo que é necessário
saber o tipo de processador de seu Mac, podendo ser ARM ou X86.

Este processo pode levar até 10 minutos. Aguarde o fim da instalação.

Caso apresente erro, faça novas tentativas e se ainda assim não tiver
sucesso, siga o procedimento de instalação manual.

[][]

Dica para Windows

Caso seu computador apresente a mensagem de risco, clique em “Mais
informações” e depois no botão “Executar mesmo assim”.Isto ocorre porque
o instalador não é assinado digitalmente.

[]

Dica para Mac

O instalador foi gerado por uma conta não verificada pela Apple e o
instalador é considerado uma ameaça. Utilize o comando abaixo em um
terminal do MacOS para iniciar a instalação.

sudo xattr -c '/Applications/Haval Install.app'

Instalação manual passo a passo

ATENÇÃO: Este processo deve ser seguido somente caso o processo
automático não funcione.

Vídeo explicativo: clique para acessar o vídeo no YouTube

Neste guia será considerado o uso de um computador Windows, mas os
passos podem ser executados via celular com um aplicativo que permita a
conexão via Telnet, porta 23. Por padrão, os aplicativos são definidos
para utilizar SSH ao invés de Telnet.

-   Para Android uma opção é o aplicativo [Termux]

-   Para iPhone uma opção é o aplicativo [Termius]

Ao usar os aplicativos para celular, não informe usuário ou senha. Deixe
os campos vazios.

Abra um command prompt (Iniciar → Executar → digite “cmd”) ou o
Powershell em seu computador.
Encontre o IP do carro com o comando:

arp -a

O endereço 192.168.33.### onde ### for diferente de 255 será o IP do
carro.

Você também pode usar o comando ipconfig /all e obter o endereço do
gateway.

[A computer screen with white text AI-generated content may be
incorrect.]

Via celular, verifique as configurações da conexão Wi-Fi.

Para dispositivos Android, utilize o app “Wi-Fi Info” para identificar o
endereço de gateway, que será o endereço do veículo.

Abaixo, um exemplo no iOS. O endereço IP do carro estará em ROTEADOR.

[]

Ainda no console/command prompt, conecte via telnet.

Atenção: Para instalar o cliente Telnet no Windows, você precisa ativar
o recurso através do Painel de Controle. No painel de controle, vá em
"Programas" → "Ativar ou desativar recursos do Windows" e marque a opção
"Cliente Telnet". Em laptops Mac, instale via Homebrew.

telnet endereço_ip_do_carro

Por exemplo: telnet 192.168.33.204

Já conectado ao console do carro, copie uma linha de comando por vez,
acessando o endereço abaixo. Note que a primeira linha é longa. Tome o
devido cuidado para copiar todo o conteúdo.

Clique aqui para ter acesso aos comandos e copiá-los

Com a primeira linha executada, execute a segunda linha para acessar a
pasta de instalação. Por fim, copie, cole e execute a terceira linha
para iniciar o processo de instalação, como exibido na imagem a seguir.

[A blue screen with white text AI-generated content may be incorrect.]

O processo de instalação pode falhar. Caso isto ocorra, execute
novamente a terceira linha de comando. Se o erro persistir, acesse a
pasta /data/local/tmp como na imagem acima, apague todos os arquivos na
pasta e repita todo o processo, desde a primeira linha. Cuidado ao
executar este comando.

rm -rf /data/local/tmp/*

Caso todo o processo seja finalizado, você verá a tela como abaixo e a
finalização da instalação.

[]

O ícone do Haval Impulse já estará disponível na Central Multimídia.

Atenção: O app Shizuku é utilizado pelo Haval Impulse e não é um
aplicativo de uso regular. Simplesmente o ignore. Não o remova.Caso
contrário o Haval Impulse não mais funcionará.

[A screen on a car AI-generated content may be incorrect.]

Configurações disponíveis

Agora é possível utilizar os recursos do Haval Impulse.[][]

+---+---------------------------------------------------------------------+
|   | 1.  Fecha todas as janelas ao desligar o veículo.                   |
|   |                                                                     |
|   | 2.  Desativa o aviso sonoro que o carro faz até 30km/h.             |
|   |                                                                     |
|   | 3.  Fecha todas as janelas ao recolher os retrovisores (exceto se o |
|   |     veículo estiver em D).                                          |
|   |                                                                     |
|   | 4.  Quando parado no trânsito, a câmera aciona com algo que passe   |
|   |     próximo ao carro, principalmente motoboy. Isso impede a câmera  |
|   |     de acionar com o carro parado.                                  |
|   |                                                                     |
|   | 5.  Fecha teto solar ao desligar o veículo.                         |
|   |                                                                     |
|   | 6.  Habilita o controle do ar-condicionado no volante, substituindo |
|   |     o controle de músicas. Pressione a seta para o lado esquerdo no |
|   |     volante para ativar. Isto funciona em conjunto com as opções    |
|   |     “Habilitar dados no painel de instrumentos” e "Habilitar        |
|   |     integração personalizada de mídia no painel de instrumentos" na |
|   |     aba Telas.                                                      |
|   |     Esta opção foi substituida após a release 1.0.0.42 por          |
|   |     Habilitar menu customizado no cluster, menu detalhado mais      |
|   |     adiante neste documento                                         |
|   |                                                                     |
|   | 7.  Fecha o teto solar ao recolher os retrovisores (exceto se o     |
|   |     veículo estiver em D).                                          |
|   |                                                                     |
|   | 8.  Liga o ventilador do banco do motorista no nível máximo sempre  |
|   |     que o ar condicionado for acionado.                             |
|   |                                                                     |
|   | 9.  Fecha a cortina ao fechar o teto solar automaticamente nos      |
|   |     itens 5 e 7.                                                    |
|   |                                                                     |
|   | 10. Desligar bluetooth ao desligar o veículo. O bluetooth é         |
|   |     reativado ao religar o veículo.                                 |
|   |                                                                     |
|   | 11. Ao atingir a velocidade definida (ex.: 60 km/h) os vidros serão |
|   |     fechados.                                                       |
|   |                                                                     |
|   | 12. Desligar ponto de acesso (hotspot) ao desligar o veículo. Ele é |
|   |     reativado automaticamente ao conectar o celular via Android     |
|   |     Auto ou Apple CarPlay.                                          |
|   |                                                                     |
|   | 13. Configura o brilho das telas de forma personalizada, sendo      |
|   |     possível escolher o nível do brilho em cada turno (dia/noite).  |
|   |                                                                     |
|   | 14. Ao atingir a velocidade definida (ex.: 60 km/h) o teto solar    |
|   |     será fechado.                                                   |
|   |                                                                     |
|   | 15. Desativa a câmera interna que há no GT e no PHEV34 para não     |
|   |     ocorrer alertas de atenção ao volante.                          |
|   |                                                                     |
|   | 16. Define o volume para o valor configurado ao ligar o carro.      |
|   |                                                                     |
|   | 17. Adicionado na versão 1.0.0.36 em 18 de setembro de 2025, função |
|   |     de habilitar botões personalizados no volante, com ações        |
|   |     diferentes do que vem habilitado por padrão.                    |
|   |                                                                     |
|   | []                                                                  |
|   |                                                                     |
|   | 18. Adicionado na versão 1.0.0.42 em 24 de dezembro de 2025 opções  |
|   |     para controle da câmera.                                        |
|   |                                                                     |
|   |     a.  Alternar o modo de desabilitar a câmera com o carro parado: |
|   |         é um atalho para alternar entre habilitado e desabilitado o |
|   |         modo de AVM, do item 4 acima, sem ter que entrar no app     |
|   |         Impulse. Note que não há notificação na tela sobre a        |
|   |         execução do comando, então use com atenção                  |
|   |                                                                     |
|   |     b.  Abir câmera sem interrupções: Quando a opção 4 acima está   |
|   |         habilitada, se o carro estiver parado e você tentar abrir a |
|   |         câmera pelo botão []do carro, ela fecha imediatamente.      |
|   |         Neste caso, para melhor usabilidade, você pode usar definir |
|   |         este atalho que força a exibição da câmera sem ser          |
|   |         imediatamente interrompida pelo modo AVM. Ela funciona      |
|   |         também para fechar a imagem da câmera quando em exibição.   |
|   |                                                                     |
|   |   []                                                                |
+===+=====================================================================+
|   |                                                                     |
+---+---------------------------------------------------------------------+

Configurações disponíveis na aba de telas. []

Com o aviso de revisão ativo, será exibido no cluster como o exemplo
abaixo:

[]

Ao ativar a opção "Habilitar integração personalizada de mídia no painel
de instrumentos" para visualizar as informações do ar-condicionado no
painel do carro, será necessário reiniciar a central multimídia para que
isto tenha efeito.

Controles do ar-condicionado no volante

+------------------------------+---------------------------------------+
| [][][]                       | Para acessar a tela do                |
|                              | ar-condicionado no painel do carro    |
|                              | (cluster), toque na seta para direita |
|                              | nos botões do lado direito do         |
|                              | volante.                              |
|                              |                                       |
|                              | Isto irá mostrar o novo cluster       |
|                              | (disponível desde a release           |
|                              | 1.0.0.42). Em versões anteriores, ele |
|                              | deve levar à tela antiga do A/C. Ao   |
|                              | pressionar “OK” na opção “Menu A/C”,  |
|                              | este leva ao controle do A/C.         |
|                              |                                       |
|                              | -   Nesta nova versão o botão “OK”    |
|                              |     navega entre as opções de         |
|                              |     temperatura e velocidade do       |
|                              |     vento.                            |
|                              |                                       |
|                              | -   As setas para cima e para baixo   |
|                              |     ajustam o valor na opção          |
|                              |     selecionada.                      |
|                              |                                       |
|                              | -   Segurando as setas para cima ou   |
|                              |     para baixo, muda-se para os       |
|                              |     valores máximos ou mínimos        |
|                              |     respectivamente.                  |
|                              |                                       |
|                              | -   Setar a velocidade em 0 desliga o |
|                              |     ar condicionado                   |
|                              |                                       |
|                              | -   O botão voltar retorna ao menu    |
|                              |     principal.                        |
|                              |                                       |
|                              | -   Se o botão “voltar” for segurado  |
|                              |     ele ativa e desativa a            |
|                              |     recirculação de ar.               |
|                              |                                       |
|                              | -   Se o botão “OK” for segurado, o   |
|                              |     modo AUTO do ar-condicionado é    |
|                              |     ativado. No entanto, ele não pode |
|                              |     ser desligado pelo volante, assim |
|                              |     como não pode ser desligado pela  |
|                              |     central multimídia. Para          |
|                              |     desativar, altere a velocidade do |
|                              |     vento.                            |
|                              |                                       |
|                              | Em versões anteriores o mecanismo era |
|                              | parecido, porém alternando também     |
|                              | entre uma opção de “power”.           |
+==============================+=======================================+
+------------------------------+---------------------------------------+

Importante: Para funcionar a navegação e exibição do menu, as seguintes
opções precisam estar habilitadas

[][]

Atualizações

Basta clicar no botão de atualização presente na tela informações:

[]

 

Instalar aplicativos adicionais

O Haval Impulse pode instalar aplicativos se estes estiverem na pasta
data/local/tmp e com o nome application.apk.

Com isso, é necessário baixar e instalar um por vez. Ao finalizar,
remova o instalador via telnet com o comando rm application.apk

Também é possível instalar através da URL ou os padrões listados em
Instalar Aplicativos.

ReVanced Manager: para instalar aplicativos Google, como YouTube e
YouTube Music.

MicroG Revanced: Para configurar sua conta Google e ser utilizada pelo
YouTube e YouTube Music Revanced.

Aurora Store: para instalar quaisquer aplicativos de terceiros exceto os
do Google.

[]

Instalando Apps através do Haval Impulse

No Haval Impulse, toque em “Instalar Apps” na barra lateral do
aplicativo. Será exibida a lista de aplicativos disponíveis para
instalação e no topo da tela há um campo para digitação do endereço de
um pacote Android (APK). Digite o endereço e a instalação será iniciada.

Para instalar o Revanced Manager, utilize este link:
https://shorturl.at/h7Zx4

Para instalar a alternativa NewPipe: https://shorturl.at/C4tjl

Instalando a versão Preview do Haval Impulse

Para instalar a versão preview do Haval Impulse, obtenha o link mais
recente em:

https://github.com/bobaoapae/haval-app-tool-multimidia/releases

O link encurtado para a versão 1.0.0.62-preview:
https://shorturl.at/rV3UY

ATENÇÃO: Use as versões preview por conta e risco, sabendo que são
versões em desenvolvimento. Se você não é um usuário regular, utilize
somente as versões estáveis, marcadas com o selo LATEST.

Após a instalação da versão preview, será possível atualizar para novas
releases automaticamente.

Configurações adicionais

Para o Aurora Store, configure o modelo do dispositivo como Google Pixel
3A em Aurora Store 🡪 Gerenciar Simulação.

Para o MigroG, mude o modelo de dispositivo configurações do MicroG,
entre em Registro do Dispositivo Google. Na opção "Auto: native", mude
para Google Nexus 5X.

Volte e abra as configurações novamente. Toque em “Contas do Google”.
Desative os 4 interruptores desta tela antes de tentar adicionar a
conta.

Agora, tente adicionar sua conta Google novamente.

Se tiver problemas para conexão com outros aplicativos, volte em “Contas
do Google” e reative o primeiro e último interruptores.

Para erros ao abrir o histórico no YouTube ReVanced, vá em Configurações
🡪 Configurações do ReVanced 🡪 Geral 🡪 Layout fator de forma. Altere para
Tablet e teste novamente.

Reiniciando a central multimídia

  -----------------------------------------------------------------------
  Para isto, com o carro ligado,      []
  câmbio em P, pressione e segure o   
  último botão no painel (exibido ao  
  lado) até que todas as telas        
  desliguem, o que pode levar até 15  
  segundos para ser executado.        
  ----------------------------------- -----------------------------------

  -----------------------------------------------------------------------

Revertendo o processo

Caso queira desfazer o procedimento, você pode fazê-lo através em
[Configurações] 🡪 [Sistema] 🡪 [Restaurar e recuperar] 🡪 Restaurar as
configurações de fábrica.

[]

Como modo avançado e menos invasivo, você também pode remover todos os
apps instalados através das configurações do Android. Para isto, abra o
Haval Impulse → Informações e clique no botão para abrir as
configurações do Android. Vá em Apps e Notificações e remova todos os
apps instalados (Haval Impulse , Shikuzu e qualquer outro app que tenha
instalado). Ao fechar a tela de configurações você não mais conseguirá
voltar, pois o Haval Impulse terá sido removido.

[]

Novidades para novas releases

Ainda em versão Preview/Beta. Acompanhe em
https://github.com/bobaoapae/haval-app-tool-multimidia/releases e na
comunidade Havaleiros Brasil.

Novidades da Release 1.0.0.43

Release somente com alterações de documentação.

Novidades da Release 1.0.0.42

Release capitaneada pelo Marcel (https://github.com/netseek),
trabalhando para criar um novo dashboard para o cluster, com gráficos,
opções para atalhos no volante, nova tela para controle do
ar-condicionado e modo AUTO MAX para o ar-condicionado.

Novas opções de atalho para volante para controle das câmeras

Estas opções estão descritas no item 18 da seção de Configurações
disponíveis.

+-----------------------------------+-----------------------------------+
| 1.  Ativar/Desativar a câmera AVM | []                                |
|     quando o veículo estiver      |                                   |
|     parado                        |                                   |
|                                   |                                   |
| 2.  Opção para abrir (ou fechar)  |                                   |
|     a câmera AVM ignorando a      |                                   |
|     configuração de AVM do        |                                   |
|     aplicativo (abre a câmera sem |                                   |
|     fechá-la se o carro estiver   |                                   |
|     parado).                      |                                   |
+===================================+===================================+
+-----------------------------------+-----------------------------------+

Novo cluster

Esta é a principal melhoria desta versão, ela traz um novo menu
navegável que substitui a antiga tela do dashboard que exibia
informações da mídia (nas últimas versões permitindo exibir o controle
do ar-condicionado).

+-----------------------------------+-----------------------------------+
| []                                | Para acessar, toque na seta para  |
|                                   | direita nos botões do lado        |
|                                   | direito do volante.               |
|                                   |                                   |
|                                   | Para navegar pelo Menu:           |
|                                   |                                   |
|                                   | -   Teclas para cima e para baixo |
|                                   |     alternam entre as opções da   |
|                                   |     tela atual                    |
|                                   |                                   |
|                                   | -   OK - tecla de ação (ex:       |
|                                   |     alterna entre valores ou      |
|                                   |     acessa o sub-menu)            |
|                                   |                                   |
|                                   | -   Voltar - Retorna à tela       |
|                                   |     anterior                      |
|                                   |                                   |
|                                   | -   As outras teclas podem ter    |
|                                   |     ações específicas a depender  |
|                                   |     de cada tela                  |
+===================================+===================================+
+-----------------------------------+-----------------------------------+

+-----------------------------------+-----------------------------------+
| []                                | -   ESP: Ligado/Desligado         |
|                                   |                                   |
|                                   | -   Modo Híbrido: EV, Prioridade  |
|                                   |     EV, HEV                       |
|                                   |                                   |
|                                   | -   Modos de potência: Normal,    |
|                                   |     ECO, SPORT                    |
|                                   |                                   |
|                                   | -   Menu de controle do ar        |
|                                   |     condicionado                  |
|                                   |                                   |
|                                   | -   Modo de direção: Conforto,    |
|                                   |     Esportiva, Normal             |
|                                   |                                   |
|                                   | -   Menu de regeneração de        |
|                                   |     energia                       |
|                                   |                                   |
|                                   | -   Gráficos                      |
+===================================+===================================+
+-----------------------------------+-----------------------------------+

Nota: O sistema memoriza a última tela exibida ao ligar o carro
novamente.

Novo controle de ar condicionado

  -----------------------------------------------------------------------
  []                                  Menu redesenhado, adicionando
                                      temperaturas externa e interna para
                                      referência, além das opções já
                                      existentes de controle de
                                      velocidade de ventilação,
                                      temperatura, ionização, controle de
                                      entrada de ar e ativação do modo
                                      auto.
  ----------------------------------- -----------------------------------

  -----------------------------------------------------------------------

Modo MAX AUTO para ar-condicionado

Liga o ar-condicionado no máximo se a temperatura estiver acima da
temperatura de disparo configurada, até atingir a temperatura alvo
configurada.

Ao se aproximar da temperatura alvo (~2 graus antes) o sistema irá
gradativamente reduzir a potência para maior conforto (menos ruído).

Ao atingir a velocidade alvo, ou atingir o limite de tempo
(configurável), ou se o usuário modificar os parâmetros do ar pelos
botões do volante, o sistema sai do modo MAX AUTO e retorna para as
configurações de A/C definidas previamente.

[][]

Escolha dos modos de regeneração de energia

+-----------------------------------+-----------------------------------+
| []                                | Navegação entre os modos Alto,    |
|                                   | Normal e Baixo de regeneração de  |
|                                   | energia.                          |
|                                   |                                   |
|                                   | Se o botão “OK” no volante for    |
|                                   | pressionado e mantido, será       |
|                                   | ativado o modo One Pedal. Para    |
|                                   | sair do modo One Pedal, pressione |
|                                   | e mantenha novamente.             |
|                                   |                                   |
|                                   | Um gráfico de regeneração de      |
|                                   | energia é exibido ao fundo da     |
|                                   | tela.                             |
+===================================+===================================+
+-----------------------------------+-----------------------------------+

Gráficos

Gráficos de acompanhamento de consumo no modo EV, consumo imediato no
modo combustão e velocidade. Use as setas para cima e para baixo para
navegar entre as opções de gráficos.

[][][]

Modo Plaid

+-----------------------------------+-----------------------------------+
| Ativado no gráfico de velocidade  | []                                |
| e quando detectada aceleração     |                                   |
| brusca, simula o modo Plaid       |                                   |
| disponível nos veículos Tesla.    |                                   |
|                                   |                                   |
| Para ativação é necessário:       |                                   |
|                                   |                                   |
| -   O carro inicia uma aceleração |                                   |
|     rápida a partir de 0 (parado) |                                   |
|                                   |                                   |
| -   Modo SPORT ativado            |                                   |
|                                   |                                   |
| -   O painel está exibindo o      |                                   |
|     gráfico de velocidade do      |                                   |
|     veículo                       |                                   |
+===================================+===================================+
+-----------------------------------+-----------------------------------+

Ao atingir 100 km/h o painel irá exibir o tempo calculado. Este tempo
permanece em tela por alguns segundos e não é armazenado pelo sistema.
Caso não atinja a velocidade de 100km/h em até 15s, o cronômetro é
cancelado.

Nota: O modo é disparado pela variação da velocidade nos primeiros
milissegundos ao sair de 0 km/h, portanto, ele pode disparar em
situações variadas.

Problemas conhecidos

1. Não é possível instalar o app da Netflix.

Instale Youtube e Youtube Music somente através do ReVanced ou não irão
funcionar.

Waze pode ter incompatibilidade com Android Auto/CarPlay nativos e
ocorrer uma tela branca, sem exibir o mapa. Há uma versão chamada
“chupitto” para a qual há relatos de resolver este problema. Pesquise no
Youtube sobre.

2. Vejo o menu no cluster mas ele não responde aos botões do volante

Certifique-se de que seguiu este direcionamento:

Para funcionar a navegação e exibição do menu, as seguintes opções
precisam estar habilitadas

[][]

Caso o problema ainda persista, desabilite as opções, reinicie o app
Haval Impulse e habilite novamente.
