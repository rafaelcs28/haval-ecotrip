'use strict';
/**
 * Gera os ícones PWA (icon-192.png e icon-512.png) sem dependências externas.
 * Execute: node generate-icons.js
 */
const fs   = require('fs');
const path = require('path');
const zlib = require('zlib');

// ── CRC32 ────────────────────────────────────────────────────────────────────
const crcTable = new Uint32Array(256);
for (let n = 0; n < 256; n++) {
  let c = n;
  for (let k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
  crcTable[n] = c;
}
function crc32(buf) {
  let c = 0xFFFFFFFF;
  for (let i = 0; i < buf.length; i++) c = crcTable[(c ^ buf[i]) & 0xFF] ^ (c >>> 8);
  return (c ^ 0xFFFFFFFF) >>> 0;
}

// ── PNG builder ───────────────────────────────────────────────────────────────
function pngChunk(type, data) {
  const t = Buffer.from(type, 'ascii');
  const l = Buffer.allocUnsafe(4); l.writeUInt32BE(data.length);
  const r = Buffer.allocUnsafe(4); r.writeUInt32BE(crc32(Buffer.concat([t, data])));
  return Buffer.concat([l, t, data, r]);
}

/** pixels: Uint8Array length = w*h*3, row-major RGB */
function buildPNG(w, h, pixels) {
  const raw = Buffer.allocUnsafe(h * (1 + w * 3));
  for (let y = 0; y < h; y++) {
    raw[y * (1 + w * 3)] = 0; // filter: None
    for (let x = 0; x < w; x++) {
      const src = (y * w + x) * 3;
      const dst = y * (1 + w * 3) + 1 + x * 3;
      raw[dst]   = pixels[src];
      raw[dst+1] = pixels[src+1];
      raw[dst+2] = pixels[src+2];
    }
  }
  const idat = zlib.deflateSync(raw, { level: 6 });
  const ihdr = Buffer.allocUnsafe(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4);
  ihdr[8]=8; ihdr[9]=2; ihdr[10]=0; ihdr[11]=0; ihdr[12]=0;
  return Buffer.concat([
    Buffer.from([137,80,78,71,13,10,26,10]),
    pngChunk('IHDR', ihdr),
    pngChunk('IDAT', idat),
    pngChunk('IEND', Buffer.alloc(0)),
  ]);
}

// ── Render ────────────────────────────────────────────────────────────────────
// Cores do app
const BG   = [0x06, 0x08, 0x0C]; // #06080C
const CARD = [0x0C, 0x10, 0x19]; // #0C1019
const NEON = [0x39, 0xFF, 0x88]; // #39FF88

/** Anti-aliasing helper: 1.0 = fully neon, 0.0 = fully bg */
function blend(fg, bg, t) {
  return [
    Math.round(fg[0]*t + bg[0]*(1-t)),
    Math.round(fg[1]*t + bg[1]*(1-t)),
    Math.round(fg[2]*t + bg[2]*(1-t)),
  ];
}

function renderIcon(size) {
  const px = new Uint8Array(size * size * 3);

  const cx = size / 2, cy = size / 2;
  const half  = size * 0.42;         // half-side do quadrado
  const r     = size * 0.20;         // raio dos cantos

  // Letra E  — proporções relativas ao tamanho do ícone
  const eL  = size * 0.27;  const eR  = size * 0.70;
  const eT  = size * 0.23;  const eB  = size * 0.77;
  const mid = (eT + eB) / 2;
  const sw  = size * 0.09;  // stroke width
  const midH = sw * 0.9;    // espessura do traço do meio

  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const dx = Math.abs(x - cx), dy = Math.abs(y - cy);

      // ── 1. Rounded-rect SDF (signed-distance ≈) ──────────────────────────
      const qx = Math.max(0, dx - (half - r));
      const qy = Math.max(0, dy - (half - r));
      const dist = Math.sqrt(qx*qx + qy*qy) - r;  // <0 = inside

      let col;
      if (dist > 1.5)      { col = BG;   }           // fora do ícone
      else if (dist < 0.5) { col = CARD; }           // dentro — inicia com card color
      else                 { col = blend(CARD, BG, 1 - (dist - 0.5)); } // AA borda

      // ── 2. Letra "E" sobre o fundo do card ───────────────────────────────
      if (dist < 0.5) {
        // barra vertical esquerda
        const inV = x >= eL && x <= eL + sw && y >= eT && y <= eB;
        // barra superior
        const inT = x >= eL && x <= eR && y >= eT && y <= eT + sw;
        // barra do meio (um pouco mais curta)
        const inM = x >= eL && x <= eL + (eR - eL) * 0.78 && y >= mid - midH && y <= mid + midH;
        // barra inferior
        const inB = x >= eL && x <= eR && y >= eB - sw && y <= eB;

        if (inV || inT || inM || inB) col = NEON;
      }

      const off = (y * size + x) * 3;
      px[off] = col[0]; px[off+1] = col[1]; px[off+2] = col[2];
    }
  }
  return buildPNG(size, size, px);
}

// ── Main ──────────────────────────────────────────────────────────────────────
const outDir = path.join(__dirname, 'public');

fs.writeFileSync(path.join(outDir, 'icon-192.png'), renderIcon(192));
console.log('✓ icon-192.png');

fs.writeFileSync(path.join(outDir, 'icon-512.png'), renderIcon(512));
console.log('✓ icon-512.png');
