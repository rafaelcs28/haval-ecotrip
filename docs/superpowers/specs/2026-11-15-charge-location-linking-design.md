# Vínculo de locais de recarga

## Intenção

Permitir que locais já usados no histórico de recargas sejam vinculados aos locais conhecidos do Haval Hub. O vínculo define qual provider e qual carregador devem preencher energia, custo e potência.

## Fluxo aprovado

O Bridge centraliza a lista e o vínculo. `GET /api/charge-locations` retorna locais distintos usados em recargas, com identificador estável, nome, coordenadas quando disponíveis e `known_place_id` opcional.

O Haval Hub mostra os locais não vinculados em **Configurações > Locais conhecidos**. Para cada item, o usuário escolhe um local conhecido existente ou solicita a criação de um novo. A criação ou o vínculo sempre exige confirmação. Depois, o usuário seleciona provider e `charger_id` no local conhecido.

O Bridge persiste a associação por IDs. Nomes são apenas apresentação e podem divergir entre Haval Hub, Zeeda e YellotMob.

## Regras

- Nunca criar ou vincular local automaticamente.
- Nunca usar igualdade de nomes como vínculo definitivo.
- Não duplicar locais com o mesmo identificador estável.
- Provider e carregador continuam configurados no local conhecido.
- Recargas antigas permanecem inalteradas até conciliação explícita.
- Falha ou ausência do catálogo não remove vínculos existentes.

## Contrato mínimo proposto

- `GET /api/charge-locations`: lista locais usados e seu vínculo atual.
- `POST /api/charge-locations/:id/link`: recebe `known_place_id`.
- `POST /api/charge-locations/:id/create-known-place`: cria após confirmação e retorna o novo `known_place_id`.

## Abordagens consideradas

Escolhida: Bridge centraliza a lista e o vínculo. Garante IDs estáveis, coordenadas e uso pelos demais clientes.

Descartada: o aplicativo deduz locais por `location_name` no histórico. É menor, mas cria duplicatas e não possui identidade ou coordenadas confiáveis.

## Não objetivos

- Inferir provider pelo prefixo do nome.
- Vincular automaticamente pela proximidade.
- Alterar recargas históricas sem ação do usuário.

## Aceitação

- Locais usados em recargas aparecem uma única vez.
- Local não vinculado permite escolher existente ou criar novo com confirmação.
- Renomear qualquer lado não quebra o vínculo.
- Após vincular, provider e carregador podem ser configurados no local conhecido.
