# MHZ MOB no Haval Hub — design

## Intenção

Adicionar `mhzmob` como provedor externo separado, usando o editor e a conciliação já existentes. O app continua falando somente com o Bridge e nunca recebe credenciais do fornecedor.

## Abordagem

O catálogo genérico publica `{ id: "mhzmob", name: "MHZ MOB", requires_tariff: false }`. Catálogo e sessões usam o namespace autenticado `/api/mhzmob`; o payload que ainda declara `provider: "yellotmob"` é associado à configuração `mhzmob` pela rota consultada, não pelo campo interno. Energia e custo vêm do provedor, como no YellotMob.

Copiar um cliente ou tela YellotMob foi rejeitado porque o app atual não possui cliente específico: `ConfigStore` e `PlaceRow` já são genéricos. A mudança correta fica no registro e adaptador do Bridge; o mesmo SwiftUI passa a mostrar MHZ automaticamente.

## Limites

- Sem login MHZ no app.
- Sem tarifa local, comandos, WebSocket ou acesso direto ao domínio do fornecedor.
- Sem inferir potência, custo ou término ausentes.
- Polling ao vivo permanece responsabilidade do backend atual; este incremento cobre seleção e conciliação automática de recargas concluídas.

## Aceite

- MHZ MOB aparece separado, lista 7 carregadores e aceita múltiplos vínculos por local.
- `transaction:2084` normaliza 20,722 kWh, R$ 32,88 e status Pago.
- Custo do provedor é preservado; `raw` e credenciais não aparecem.
- Sem token continua 401 no namespace MHZ.
