import React, { useState } from 'react';
import { color, radius, font } from '../tokens';
import { Card } from './Card';

export interface CollapsibleCardProps {
  icon?: React.ReactNode;
  title: string;
  /** One-line summary shown while collapsed */
  summary: string;
  /** Anomaly mode: forces open, yellow tint + yellow border */
  alert?: boolean;
  children: React.ReactNode;
}

/**
 * Collapsible section card (pneus/TPMS, manutenção, alertas). Collapsed by
 * default with a one-line summary; `alert` forces it open and paints it yellow.
 */
export function CollapsibleCard({
  icon,
  title,
  summary,
  alert = false,
  children,
}: CollapsibleCardProps) {
  const [userOpen, setUserOpen] = useState(false);
  const open = userOpen || alert;
  const tint = alert ? color.yellow : color.muted;

  return (
    <div
      style={{
        borderRadius: radius.card,
        boxShadow: alert ? `inset 0 0 0 1.5px ${color.yellow}b3` : undefined,
      }}
    >
      <Card>
        <button
          onClick={() => setUserOpen((v) => !v)}
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: 8,
            width: '100%',
            background: 'none',
            border: 'none',
            padding: 0,
            cursor: 'pointer',
            fontFamily: font.family,
            fontSize: font.cardTitle,
            fontWeight: 600,
            letterSpacing: font.trackingLabel,
            textTransform: 'uppercase',
            color: tint,
          }}
        >
          {alert ? '⚠' : icon}
          <span>{title}</span>
          <span style={{ flex: 1 }} />
          {!open && (
            <span style={{ fontWeight: 400, textTransform: 'none', letterSpacing: 0 }}>
              {summary}
            </span>
          )}
          <span style={{ color: color.muted }}>{open ? '⌃' : '⌄'}</span>
        </button>
        {open && children}
      </Card>
    </div>
  );
}
