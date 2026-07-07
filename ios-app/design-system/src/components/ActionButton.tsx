import React from 'react';
import { color, radius, size, font } from '../tokens';

export interface ActionButtonProps {
  icon?: React.ReactNode;
  title: string;
  /** Accent color — icon/text tinted, surface = 10% tint + 28% border */
  color?: string;
  /** Shows a spinner and disables the button (command in flight) */
  busy?: boolean;
  compact?: boolean;
  onClick?: () => void;
}

/**
 * Large touch-friendly action button (Travar, Vidros, Clima…).
 * Mirrors SwiftUI DSActionButton: subtle tinted glass surface, accent-colored
 * icon+label. Commands take 1–3s with verify — use `busy` while confirming.
 */
export function ActionButton({
  icon,
  title,
  color: accent = color.blue,
  busy = false,
  compact = false,
  onClick,
}: ActionButtonProps) {
  return (
    <button
      onClick={onClick}
      disabled={busy}
      style={{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        gap: compact ? 6 : 8,
        width: '100%',
        height: compact ? size.actionButtonHCompact : size.actionButtonH,
        borderRadius: radius.action,
        border: `1px solid ${accent}47`,
        background: `${accent}1a`,
        color: accent,
        fontFamily: font.family,
        fontSize: compact ? 14 : font.actionButton,
        fontWeight: 600,
        cursor: busy ? 'default' : 'pointer',
        opacity: busy ? 0.7 : 1,
      }}
    >
      {busy ? <Spinner color={accent} /> : icon}
      {title}
    </button>
  );
}

function Spinner({ color: c }: { color: string }) {
  return (
    <span
      style={{
        width: 14,
        height: 14,
        borderRadius: '50%',
        border: `2px solid ${c}40`,
        borderTopColor: c,
        animation: 'hh-spin 0.8s linear infinite',
      }}
    />
  );
}
