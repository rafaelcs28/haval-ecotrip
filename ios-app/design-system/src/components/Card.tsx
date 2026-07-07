import React from 'react';
import { color, radius, space, font } from '../tokens';

export interface CardProps {
  /** CAPS section title (muted, tracked) */
  title?: string;
  /** Emoji-free icon slot rendered before the title */
  icon?: React.ReactNode;
  /** Translucent surface for use over maps (mirrors SwiftUI glassPanel) */
  glass?: boolean;
  /** Override surface color (e.g. highlight when a device is on) */
  bg?: string;
  /** Override border color */
  borderColor?: string;
  /** Reduced padding for single-line rows */
  compact?: boolean;
  children: React.ReactNode;
}

/** Standard dark card: #0d0d0f surface, 18px continuous radius, 1px 8%-white border. */
export function Card({
  title,
  icon,
  glass = false,
  bg,
  borderColor,
  compact = false,
  children,
}: CardProps) {
  return (
    <div
      style={{
        display: 'flex',
        flexDirection: 'column',
        gap: compact ? space.cardGapCompact : space.cardGap,
        padding: compact
          ? `${space.cardPadYCompact}px ${space.cardPadXCompact}px`
          : `${space.cardPadY}px ${space.cardPadX}px`,
        borderRadius: radius.card,
        border: `1px solid ${borderColor ?? color.border}`,
        background: glass ? 'rgba(22,22,26,0.55)' : bg ?? color.panel,
        backdropFilter: glass ? 'blur(20px)' : undefined,
        WebkitBackdropFilter: glass ? 'blur(20px)' : undefined,
        color: color.text,
        fontFamily: font.family,
      }}
    >
      {title && (
        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: 6,
            fontSize: font.cardTitle,
            fontWeight: 600,
            letterSpacing: font.trackingLabel,
            textTransform: 'uppercase',
            color: color.muted,
          }}
        >
          {icon}
          {title}
        </div>
      )}
      {children}
    </div>
  );
}
