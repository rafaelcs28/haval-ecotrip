# Haval Hub Design System (React mirror)

Espelho em React/TypeScript do design system real do app, que é **SwiftUI**
(`ios-app/HavalEcoTrip/DesignSystem.swift`). Existe só para o `/design-sync` do
Claude Design conseguir ler tokens + componentes — a fonte da verdade continua
sendo o Swift.

- `src/tokens.ts` — paleta, radii, espaçamento, tipografia, formatação pt-BR
- `src/components/` — Card, Metric, ActionButton, Chip, LevelBadge, ChoiceRow,
  CollapsibleCard (equivalentes de DSCard, DSMetric, DSActionButton, DSChip,
  LevelBadge, DSChoiceRow, CollapsibleCard)

Contexto completo do produto e das telas: `../DESIGN-HANDOFF.md`.

Regras do tema: dark-only, densidade alta, pt-BR, sem emoji na UI, glass só em
camada flutuante sobre mapa — cards de dados são sólidos (#0d0d0f).
