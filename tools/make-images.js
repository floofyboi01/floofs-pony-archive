// Generates the icon + splash PNGs Roku's manifest requires.
// Pure Node, no dependencies: minimal PNG encoder plus a procedural sparkle mark.

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

//---------------------------------------------------------------
// Minimal PNG encoder (truecolour, 8 bit)
//---------------------------------------------------------------

const CRC_TABLE = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  const body = Buffer.concat([Buffer.from(type, 'latin1'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body), 0);
  return Buffer.concat([len, body, crc]);
}

function encodePng(width, height, rgb) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;  // bit depth
  ihdr[9] = 2;  // colour type: truecolour
  ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;

  // One filter byte (0 = None) per scanline.
  const raw = Buffer.alloc(height * (width * 3 + 1));
  let p = 0;
  for (let y = 0; y < height; y++) {
    raw[p++] = 0;
    rgb.copy(raw, p, y * width * 3, (y + 1) * width * 3);
    p += width * 3;
  }

  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

//---------------------------------------------------------------
// Artwork
//---------------------------------------------------------------

const BG_TOP    = [0x1b, 0x14, 0x38];
const BG_BOTTOM = [0x0b, 0x08, 0x18];
const MINT      = [0xba, 0xf4, 0xc2];
const MAGENTA   = [0xe8, 0x7d, 0xc4];

const clamp01 = v => (v < 0 ? 0 : v > 1 ? 1 : v);
const mix = (a, b, t) => [
  a[0] + (b[0] - a[0]) * t,
  a[1] + (b[1] - a[1]) * t,
  a[2] + (b[2] - a[2]) * t,
];

// True six-pointed star polygon: fold the angle into one tip sector, then
// intersect the ray with the straight edge joining the outer tip to the
// inner vertex. Straight edges and sharp points, unlike a cosine lobe.
const STAR_POINTS = 6;
const STAR_SECTOR = (Math.PI * 2) / STAR_POINTS;
const STAR_INNER = 0.40;

const EDGE = (() => {
  const p1 = { x: 1, y: 0 };
  const p2 = {
    x: STAR_INNER * Math.cos(STAR_SECTOR / 2),
    y: STAR_INNER * Math.sin(STAR_SECTOR / 2),
  };
  const a = p2.y - p1.y;
  const b = p1.x - p2.x;
  return { a, b, c: -(a * p1.x + b * p1.y) };
})();

function starMask(dx, dy, radius) {
  const r = Math.hypot(dx, dy);
  if (r > radius * 1.9) return { fill: 0, glow: 0 };

  // Rotate so a point faces straight up, then fold into a single sector.
  let theta = Math.atan2(dy, dx) + Math.PI / 2;
  theta = ((theta % STAR_SECTOR) + STAR_SECTOR) % STAR_SECTOR;
  const a = Math.abs(theta - STAR_SECTOR / 2);

  const denom = EDGE.a * Math.cos(a) + EDGE.b * Math.sin(a);
  const limit = radius * (Math.abs(denom) < 1e-9 ? 1 : -EDGE.c / denom);

  const edge = Math.max(radius * 0.012, 0.75);
  const fill = clamp01((limit - r) / edge + 0.5);
  const glow = Math.exp(-Math.pow(r / (radius * 0.7), 2)) * 0.35;
  return { fill, glow };
}

// Small four-point twinkles scattered around the mark, built from the same
// straight-edged polygon construction but with a much thinner waist.
const TWINKLE_SECTOR = (Math.PI * 2) / 4;
const TWINKLE_EDGE = (() => {
  const inner = 0.16;
  const p1 = { x: 1, y: 0 };
  const p2 = {
    x: inner * Math.cos(TWINKLE_SECTOR / 2),
    y: inner * Math.sin(TWINKLE_SECTOR / 2),
  };
  const a = p2.y - p1.y;
  const b = p1.x - p2.x;
  return { a, b, c: -(a * p1.x + b * p1.y) };
})();

function twinkle(dx, dy, size) {
  const r = Math.hypot(dx, dy);
  if (r > size * 1.4) return 0;

  let theta = Math.atan2(dy, dx) + Math.PI / 2;
  theta = ((theta % TWINKLE_SECTOR) + TWINKLE_SECTOR) % TWINKLE_SECTOR;
  const a = Math.abs(theta - TWINKLE_SECTOR / 2);

  const denom = TWINKLE_EDGE.a * Math.cos(a) + TWINKLE_EDGE.b * Math.sin(a);
  const limit = size * (Math.abs(denom) < 1e-9 ? 1 : -TWINKLE_EDGE.c / denom);
  return clamp01((limit - r) / Math.max(size * 0.05, 0.6) + 0.5);
}

function render(width, height, opts) {
  const starScale = opts.starScale;
  const showTwinkles = opts.showTwinkles;

  const cx = width * (opts.cx !== undefined ? opts.cx : 0.5);
  const cy = height * 0.5;
  const radius = Math.min(width, height) * starScale;

  const stars = [];
  if (showTwinkles) {
    const unit = Math.min(width, height);
    stars.push(
      { x: cx + radius * 1.55, y: cy - radius * 0.85, s: unit * 0.035 },
      { x: cx - radius * 1.70, y: cy + radius * 0.60, s: unit * 0.028 },
      { x: cx + radius * 1.25, y: cy + radius * 1.15, s: unit * 0.020 },
      { x: cx - radius * 1.20, y: cy - radius * 1.10, s: unit * 0.022 },
    );
  }

  const rgb = Buffer.alloc(width * height * 3);
  const SS = 3;                  // 3x3 supersampling
  const inv = 1 / (SS * SS);

  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      let acc = [0, 0, 0];

      for (let sy = 0; sy < SS; sy++) {
        for (let sx = 0; sx < SS; sx++) {
          const px = x + (sx + 0.5) / SS;
          const py = y + (sy + 0.5) / SS;

          // Background: vertical gradient plus a soft glow behind the mark.
          let col = mix(BG_TOP, BG_BOTTOM, py / height);
          const halo = Math.exp(-Math.pow(Math.hypot(px - cx, py - cy) / (radius * 2.1), 2));
          col = mix(col, [0x3a, 0x2a, 0x6e], halo * 0.55);

          const { fill, glow } = starMask(px - cx, py - cy, radius);
          col = mix(col, MAGENTA, clamp01(glow) * 0.5);
          if (fill > 0) {
            // Mint core fading toward magenta at the tips.
            const tip = clamp01(Math.hypot(px - cx, py - cy) / radius);
            col = mix(col, mix(MINT, MAGENTA, tip * 0.75), fill);
          }

          for (const s of stars) {
            const t = twinkle(px - s.x, py - s.y, s.s);
            if (t > 0) col = mix(col, [0xff, 0xff, 0xff], t * 0.85);
          }

          acc[0] += col[0]; acc[1] += col[1]; acc[2] += col[2];
        }
      }

      const o = (y * width + x) * 3;
      rgb[o]     = Math.round(clamp01(acc[0] * inv / 255) * 255);
      rgb[o + 1] = Math.round(clamp01(acc[1] * inv / 255) * 255);
      rgb[o + 2] = Math.round(clamp01(acc[2] * inv / 255) * 255);
    }
  }
  return rgb;
}

//---------------------------------------------------------------

// Roku's documented asset sizes. mm_icon_focus_fhd (540x405) and
// mm_icon_focus_hd (290x218) are the required app icons; mm_icon_focus_sd and
// the mm_icon_side_* variants are deprecated and no longer used by devices.
const TARGETS = [
  { file: 'icon_focus_fhd.png', w: 540,  h: 405,  starScale: 0.30, showTwinkles: true },
  { file: 'icon_focus_hd.png',  w: 290,  h: 218,  starScale: 0.30, showTwinkles: true },
  { file: 'splash_sd.png',      w: 720,  h: 480,  starScale: 0.20, showTwinkles: true },
  { file: 'splash_hd.png',      w: 1280, h: 720,  starScale: 0.20, showTwinkles: true },
  { file: 'splash_fhd.png',     w: 1920, h: 1080, starScale: 0.20, showTwinkles: true },
];

const outDir = path.join(__dirname, '..', 'images');
fs.mkdirSync(outDir, { recursive: true });

for (const t of TARGETS) {
  const rgb = render(t.w, t.h, t);
  const png = encodePng(t.w, t.h, rgb);
  fs.writeFileSync(path.join(outDir, t.file), png);
  console.log(`${t.file.padEnd(22)} ${String(t.w).padStart(4)}x${String(t.h).padStart(4)}  ${String(png.length).padStart(7)} bytes`);
}
console.log('\nWrote ' + TARGETS.length + ' images to images/');
