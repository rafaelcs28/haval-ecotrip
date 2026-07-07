import React from 'react';
import { color, size, font } from '../tokens';

export interface LevelBadgeProps {
  icon?: React.ReactNode;
  /** 0…1 fill */
  fraction: number;
  value: string;
  unit: string;
  /** CAPS label under the bar */
  label: string;
  tint: string;
  /** Optional tick on the bar (e.g. charge limit), 0…1 */
  markerFraction?: number;
}

/**
 * Level gauge: tinted icon + big value + capsule fill bar with optional
 * marker tick. Used for SOC %, fuel, range.
 */
export function LevelBadge({
  icon,
  fraction,
  value,
  unit,
  label,
  tint,
  markerFraction,
}: LevelBadgeProps) {
  const f = Math.min(1, Math.max(0, fraction));
  return (
    <div style={{ display: 'flex', gap: 12, alignItems: 'center', fontFamily: font.family }}>
      {icon && <div style={{ width: 30, color: tint, fontSize: 26 }}>{icon}</div>}
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 5 }}>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 3 }}>
          <span
            style={{
              fontFamily: font.familyRounded,
              fontSize: 24,
              fontWeight: 600,
              color: color.text,
              fontVariantNumeric: 'tabular-nums',
            }}
          >
            {value}
          </span>
          <span style={{ fontSize: 12, color: color.muted }}>{unit}</span>
        </div>
        <div
          style={{
            position: 'relative',
            height: size.levelBarH,
            borderRadius: size.levelBarH / 2,
            background: color.panel2,
          }}
        >
          <div
            style={{
              position: 'absolute',
              inset: 0,
              width: `max(4px, ${f * 100}%)`,
              borderRadius: size.levelBarH / 2,
              background: tint,
            }}
          />
          {markerFraction != null && markerFraction > 0 && markerFraction < 1 && (
            <div
              style={{
                position: 'absolute',
                top: -2.5,
                left: `calc(${markerFraction * 100}% - 1px)`,
                width: 2,
                height: 11,
                borderRadius: 1,
                background: 'rgba(255,255,255,0.85)',
              }}
            />
          )}
        </div>
        <span
          style={{
            marginTop: 3,
            fontSize: 9,
            fontWeight: 600,
            letterSpacing: 0.4,
            textTransform: 'uppercase',
            color: color.muted,
          }}
        >
          {label}
        </span>
      </div>
    </div>
  );
}
