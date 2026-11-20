# Medidor externo ao vivo — design

## Intenção

Mostrar durante a recarga, no Haval Hub e na Live Activity, os dados do carregador vinculado ao local: potência, energia acumulada, custo e perda comparada ao carro.

## Abordagem

O Bridge consulta a cada 15 segundos somente quando o Haval informa `charging_state == "Carregando"`. A localização do Haval escolhe o local conhecido mais próximo dentro do raio; somente os carregadores vinculados a esse local são consultados. Zeeda usa `/api/zeeda/chargers/:id/live`; YellotMob e MHZ MOB usam seus endpoints `current-session`. Todos viram o mesmo objeto normalizado.

O snapshot externo entra no `/api/state` e no content-state APNs. O app continua buscando `/api/state`; não recebe credenciais dos fornecedores nem chama adaptadores diretamente.

## Regras

- Sessão YellotMob ou MHZ MOB está ativa somente com `status == "Charging"`, sem exigir `power_kw`.
- Zeeda está ativo com status de carga ou potência positiva.
- `started_at` não decide atividade.
- Um carregador ativo em outro local, inclusive usado pelo carro da esposa, é ignorado.
- Se o Haval não estiver carregando, nenhum carregador externo alimenta o app, mesmo que exista sessão ativa na conta do fornecedor.
- Havendo exatamente uma sessão ativa entre os carregadores vinculados ao local, ela alimenta a tela.
- Zero sessões limpa os dados externos; mais de uma deixa o resultado ambíguo e não mostra dados possivelmente errados.
- Perda energética é `max(0, kWh do carregador - kWh recebidos pelo carro)`; percentual usa kWh do carregador como base.
- Custo vem do YellotMob/MHZ MOB. No Zeeda, usa energia externa multiplicada pela tarifa vigente do carregador.
- Histórico, conciliação final e valores manuais não mudam.

## Apresentação

O card de recarga e a Live Activity mostram, quando disponíveis:

- potência do carregador e do carro, com perda percentual instantânea;
- kWh do carregador e do carro, com perda em kWh e percentual;
- custo atual.

Ausência de potência não esconde energia, custo ou estado ativo.

## Limites

- O app em primeiro plano atualiza pelo polling existente de 5 segundos sobre o cache do Bridge.
- O Bridge atualiza o fornecedor a cada 15 segundos.
- A tela bloqueada depende do orçamento e entrega do APNs.
- Sessões simultâneas em dois carregadores vinculados ao mesmo local ficam ambíguas por segurança.

## Aceite

- Zeeda, YellotMob e MHZ MOB usam o mesmo contrato ao vivo.
- YellotMob `charging:472330` continua ativo com `power_kw: null`.
- A localização atual do Haval seleciona Pão de Açúcar T-63 e ignora o Zeeda ativo em Jardins Lisboa.
- Nenhum `raw`, token ou credencial chega ao app.
- Tela do app e Live Activity exibem energia externa, custo e perdas quando houver sessão única.
- Testes Node e iOS passam; novo build fica `VALID` no TestFlight.
