import React from 'react';
import { color, radius, font } from '../tokens';

export interface ChipProps {
  text: string;
  color?: string;
  /** filled = solid accent + black text; otherwise 15% tint + accent text */
  filled?: boolean;
}

/** State pill (gear, ligado/desligado, carregando…). */
export function Chip({ text, color: accent = color.muted, filled = false }: ChipProps) {
  return (
    <span
      style={{
        display: 'inline-block',
        padding: '6px 12px',
        borderRadius: radius.pill,
        fontFamily: font.family,
        fontSize: font.chip,
        fontWeight: 700,
        color: filled ? '#000' : accent,
        background: filled ? accent : `${accent}26`,
      }}
    >
      {text}
    </span>
  );
}
