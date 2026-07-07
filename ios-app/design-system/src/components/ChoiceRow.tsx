import React from 'react';
import { color, radius, size, font } from '../tokens';

export interface ChoiceRowProps<T extends string | number> {
  options: Array<{ value: T; label: string }>;
  selected: T;
  /** Accent for the selected segment (solid fill + black text) */
  color?: string;
  onPick: (v: T) => void;
}

/** Large-touch segmented selector used in sheets (charge limit 70/80/90/100, periods…). */
export function ChoiceRow<T extends string | number>({
  options,
  selected,
  color: accent = color.green,
  onPick,
}: ChoiceRowProps<T>) {
  return (
    <div style={{ display: 'flex', gap: 8 }}>
      {options.map((opt) => {
        const on = opt.value === selected;
        return (
          <button
            key={String(opt.value)}
            onClick={() => onPick(opt.value)}
            style={{
              flex: 1,
              height: size.choiceRowH,
              borderRadius: radius.choice,
              border: on ? 'none' : `1px solid ${color.border}`,
              background: on ? accent : color.panel2,
              color: on ? '#000' : color.text,
              fontFamily: font.family,
              fontSize: 15,
              fontWeight: 700,
              cursor: 'pointer',
            }}
          >
            {opt.label}
          </button>
        );
      })}
    </div>
  );
}
