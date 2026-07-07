/**
 * Haval Hub design tokens.
 * Source of truth: ios-app/HavalEcoTrip/DesignSystem.swift (enum DS) — the values
 * below mirror the SwiftUI palette, which itself mirrors the PWA/cluster :root.
 * Dark-only theme (in-car / night use is the primary context).
 */

export const color = {
  /** App background */
  bg: '#000000',
  /** Card surface */
  panel: '#0d0d0f',
  /** Inner surfaces, bars, wells */
  panel2: '#16161a',
  /** Primary text */
  text: '#f5f5f5',
  /** Secondary text, labels */
  muted: '#6b7280',
  /** Card borders (1px) */
  border: 'rgba(255,255,255,0.08)',

  /** OK / regen / EV */
  green: '#22c55e',
  /** Actions / info */
  blue: '#38bdf8',
  /** Consumption / attention */
  orange: '#fb923c',
  /** Charging */
  teal: '#22d3ee',
  /** Warning */
  yellow: '#facc15',
  /** Critical */
  red: '#ef4444',
} as const;

export const radius = {
  /** Cards */
  card: 18,
  /** Action buttons */
  action: 14,
  /** Segmented choices */
  choice: 12,
  /** Chips: fully rounded */
  pill: 999,
} as const;

export const space = {
  cardPadX: 14,
  cardPadY: 12,
  cardPadXCompact: 10,
  cardPadYCompact: 6,
  cardGap: 12,
  cardGapCompact: 4,
} as const;

export const font = {
  family:
    "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', Roboto, sans-serif",
  /** Numeric values use rounded + tabular digits */
  familyRounded:
    "'SF Pro Rounded', -apple-system, BlinkMacSystemFont, sans-serif",
  metricValue: 21,
  metricValueCompact: 17,
  metricUnit: 11,
  metricLabel: 10,
  cardTitle: 12,
  chip: 13,
  actionButton: 16,
  /** CAPS labels tracking (letter-spacing, px) */
  trackingLabel: 0.5,
} as const;

export const size = {
  actionButtonH: 52,
  actionButtonHCompact: 40,
  choiceRowH: 50,
  levelBarH: 6,
} as const;

/** pt-BR number formatting: 1.234,56 / R$ */
export const nf0 = new Intl.NumberFormat('pt-BR', { maximumFractionDigits: 0 });
export const nf1 = new Intl.NumberFormat('pt-BR', {
  minimumFractionDigits: 1,
  maximumFractionDigits: 1,
});
export const nf2 = new Intl.NumberFormat('pt-BR', {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});
export const brl = (v: number) => 'R$ ' + nf2.format(v);
