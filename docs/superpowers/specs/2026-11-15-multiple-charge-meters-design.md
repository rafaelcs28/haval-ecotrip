# Vários carregadores por local — design

## Intenção

Um local conhecido pode usar vários carregadores, inclusive vários Zeeda, vários YellotMob ou uma mistura dos dois. Cada carregador mantém configuração e tarifa próprias. O mesmo par `provider + charger_id` não pode aparecer duas vezes no mesmo local.

## Abordagens consideradas

1. Lista independente `charge_meters`: escolhida. Representa cada carregador por completo e permite provedores e tarifas diferentes sem regras especiais.
2. Agrupar carregadores por provedor: rejeitada. Compartilharia configuração que precisa ser individual e complicaria edição e reconciliação.
3. Manter um carregador principal e uma lista de extras: rejeitada. Criaria duas fontes de verdade e rollback ambíguo.

## Dados e compatibilidade

O Bridge passa a persistir:

```json
{
  "charge_meters": [
    {
      "enabled": true,
      "provider": "zeeda",
      "charger_id": "D42787B28BA6",
      "charger_name": "Jardins Lisboa",
      "tariffs": [
        { "effective_from_ms": 1794760000000, "price_per_kwh": 0.18 }
      ]
    },
    {
      "enabled": true,
      "provider": "yellotmob",
      "charger_id": "273",
      "charger_name": "Pão de Açúcar T-63",
      "tariffs": []
    }
  ]
}
```

Leitores novos aceitam `charge_meters`. Quando ele não existe, transformam o `charge_meter` legado em uma lista de um item. Durante a janela de compatibilidade, o Bridge grava `charge_meters` e também mantém `charge_meter` como espelho do primeiro item. Nenhuma migração destrutiva ou regravação em massa será feita.

Rollback para o aplicativo anterior mantém o primeiro carregador visível. Os demais continuam preservados em `charge_meters`, mas não ficam editáveis até retornar à versão nova.

## Interface

O cartão do local mostra todos os carregadores configurados. A edição oferece `Adicionar carregador` e uma linha por configuração, com provedor, carregador, estado e tarifa quando for Zeeda.

Adicionar abre o seletor rolável de provedor e depois o seletor rolável de carregador. Editar ou remover afeta apenas o item escolhido. Salvar valida a lista inteira e exige confirmação antes de remover uma configuração existente.

Zeeda exige tarifa individual. YellotMob usa energia e custo fornecidos pelo provedor e não mostra tarifa.

## Bridge e validação

`PUT /api/known-places/:id` aceita `charge_meters` e continua aceitando `charge_meter` legado. O Bridge:

- valida cada provedor, carregador e histórico de tarifas;
- rejeita duplicatas pelo par normalizado `provider + charger_id`;
- nunca recebe credenciais dos provedores pelo aplicativo;
- persiste a atualização inteira ou mantém a configuração anterior;
- retorna erro 400 descritivo sem alterar o local quando a lista for inválida.

Catálogos existentes continuam em:

```text
GET /api/charge-meter/providers
GET /api/charge-meter/providers/:provider/chargers
```

## Reconciliação

Para cada recarga, o Bridge consulta todos os carregadores ativos vinculados ao local. Sessões são conciliadas pelo carregador correto e pela janela oficial da recarga. Se mais de um carregador tiver sessão compatível, o Bridge usa a correspondência temporal mais forte; não soma carregadores diferentes na mesma recarga sem evidência de sobreposição com o período.

Cada Zeeda usa sua própria tarifa vigente. Cada YellotMob usa seu próprio custo informado. Valores manuais continuam com precedência e nunca são sobrescritos.

## Fora do escopo

- Usar dois carregadores simultaneamente na mesma recarga física.
- Compartilhar tarifa entre carregadores.
- Remover o campo legado `charge_meter`.
- Alterar credenciais ou serviços Zeeda/YellotMob.

## Verificação

- Decodificar local legado e novo sem perda.
- Salvar dois Zeeda com tarifas diferentes.
- Salvar dois YellotMob e uma mistura entre provedores.
- Rejeitar duplicata exata sem alterar o JSON persistido.
- Adicionar, editar e remover um item sem afetar os demais.
- Confirmar listas roláveis no iOS e build no Mac Mini autorizado.
- Validar Bridge em produção antes de publicar o novo TestFlight.
