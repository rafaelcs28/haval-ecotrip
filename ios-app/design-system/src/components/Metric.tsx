import React from 'react';
import { color, font } from '../tokens';

export interface MetricProps {
  /** Pre-formatted value (pt-BR: comma decimals) */
  value: string;
  unit?: string;
  /** CAPS label under the value */
  label: string;
  /** Value color (default text; green=regen, orange=consumption, etc.) */
  color?: string;
  /** Smaller font for 4-column rows */
  compact?: boolean;
}

/** Compact metric: big rounded tabular value + small unit + CAPS label below. */
export function Metric({
  value,
  unit,
  label,
  color: valueColor = color.text,
  compact = false,
}: MetricProps) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 2, minWidth: 0 }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 2 }}>
        <span
          style={{
            fontFamily: font.familyRounded,
            fontSize: compact ? font.metricValueCompact : font.metricValue,
            fontWeight: 600,
            color: valueColor,
            fontVariantNumeric: 'tabular-nums',
            whiteSpace: 'nowrap',
          }}
        >
          {value}
        </span>
        {unit && (
          <span style={{ fontSize: compact ? 9 : font.metricUnit, color: color.muted }}>
            {unit}
          </span>
        )}
      </div>
      <span
        style={{
          fontSize: compact ? 9 : font.metricLabel,
          fontWeight: 600,
          letterSpacing: 0.3,
          textTransform: 'uppercase',
          color: color.muted,
          whiteSpace: 'nowrap',
        }}
      >
        {label}
      </span>
    </div>
  );
}
