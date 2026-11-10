// Cortex memory map: a flat 2D map read from the centre out.
// Core (always loaded) in the middle, the persona ring around it, groups as nebulas in their own sectors,
// then context, memory and installed packs on rings further out. Every visual parameter lives in `S` and
// can be changed live via Cortex.setStyle. Recall lights hits and their connections in S.recallColor.
import { forceSimulation, forceLink, forceManyBody, forceRadial, forceX, forceY, forceCollide } from 'd3-force-3d';

// Defaults mirror GraphStyle.swift.
const S = {
  background: '#242834',
  coreColor: '#b6ff00', personaColor: '#7d53ff', contextColor: '#e9ecf2', memoryColor: '#7a8195',
  orphanColor: '#4a5063', recallColor: '#b6ff00', packColor: '#9aa1b5',
  manualLinkColor: '#e9ecf2', autoLinkColor: '#e9ecf2', manualLinkOpacity: 0.22, autoLinkOpacity: 0.04, showAutoLinks: true,
  nodeSize: 1, nebula: 1, labels: 'context', labelSize: 1, spread: 1,
  pulseRate: 5, pulseColor: '#e9ecf2',
};

// Ring radii in world units (scaled by S.spread).
const R = { core: 80, persona: 136, context: 270, memory: 420, pack: 570 };
const SIZE = { core: 9, persona: 7, personaNote: 4, context: 5, memory: 3.2, pack: 3.6 };
const NEBULA_RADIUS = 34;
const FONT = '-apple-system, "SF Pro Text", system-ui, sans-serif';

const post = (msg) => window.webkit?.messageHandlers?.cortex?.postMessage(msg);

// ---- colour helpers --------------------------------------------------------------

const rgb = (hex) => { const v = parseInt(hex.slice(1), 16); return [(v >> 16) & 255, (v >> 8) & 255, v & 255]; };
const rgba = (hex, a) => { const [r, g, b] = rgb(hex); return `rgba(${r},${g},${b},${a})`; };
// `hex` laid over the background at strength t, as an opaque colour (so overlapping shapes never darken).
const mix = (hex, t) => {
  const a = rgb(hex), b = rgb(S.background);
  return `rgb(${a.map((v, i) => Math.round(b[i] + (v - b[i]) * t)).join(',')})`;
};
// Like mix, for any colour this file produces (hex or rgb()).
const mixColor = (color, t) => (t >= 1 ? color : mix(color.startsWith('#') ? color : toHex(color), t));
const toHex = (c) => `#${c.match(/\d+/g).slice(0, 3).map((v) => (+v).toString(16).padStart(2, '0')).join('')}`;
// RGB 0…255 ↔ HSL 0…1.
function toHsl([r, g, b]) {
  r /= 255; g /= 255; b /= 255;
  const max = Math.max(r, g, b), min = Math.min(r, g, b), l = (max + min) / 2, d = max - min;
  if (!d) return [0, 0, l];
  const s = d / (1 - Math.abs(2 * l - 1));
  const h = max === r ? ((g - b) / d + 6) % 6 : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
  return [h / 6, s, l];
}
const hsla = (h, s, l, a) => `hsl(${Math.round(h * 360)} ${Math.round(s * 100)}% ${Math.round(l * 1000) / 10}% / ${a})`;
// A nebula's two tones in the group's hue: its body, and the light where its notes gather. Built from the hue
// rather than mixed towards the background, which would grey it out.
function nebulaTones(hex) {
  const [h, s] = toHsl(rgb(hex));
  const light = toHsl(rgb(S.background))[2] > 0.5;
  return light
    ? { h, body: [Math.min(0.5, s * 0.55), 0.84], glow: [Math.min(0.6, s * 0.7), 0.72] }
    : { h, body: [Math.min(0.5, s * 0.6), 0.3], glow: [Math.min(0.75, s * 0.85), 0.62] };
}
// `hex` lightened towards white by t (0 = itself).
const tint = (hex, t) => `rgb(${rgb(hex).map((v) => Math.round(v + (255 - v) * t)).join(',')})`;
const shade = (hex, t) => `rgb(${rgb(hex).map((v) => Math.round(v * (1 - t))).join(',')})`;

// ---- state -----------------------------------------------------------------------

let nodes = [], links = [], personas = [];
let nodesById = new Map(), linksByNode = new Map(), neighbours = new Map();
let groupColors = new Map(), groupList = [], groupAngle = new Map(), packAnchor = new Map();
let layersOn = new Set(['core', 'context', 'memory', 'pack']);
let timelineCutoff = null;
let hits = new Map();           // id → score during a recall
let litLinks = new Set();
let hovered = null, selected = null;
let dim = 0, dimTarget = 0;     // 0…1: how far everything outside the recall fades

const isPersonaNote = (n) => n.layer === 'core' && n.pack != null;
const inGroup = (n) => n.group != null && n.layer !== 'core' && n.layer !== 'pack';
const visible = (n) => !!n && layersOn.has(n.layer) && (timelineCutoff == null || n.created <= timelineCutoff);
const radius = (n) => {
  if (isPersonaNote(n)) return SIZE.personaNote * S.nodeSize;
  const base = SIZE[n.layer] + (n.layer === 'context' || n.layer === 'memory' ? Math.sqrt(n.degree || 0) * 0.9 : 0);
  return base * S.nodeSize;
};
const fill = (n) => {
  if (n.layer === 'core') return isPersonaNote(n) ? S.personaColor : S.coreColor;
  if (n.layer === 'pack') return null; // hollow: installed knowledge, not the user's own
  // Inside a nebula a note takes its group's colour: pale for context, deeper for memory.
  if (inGroup(n)) {
    const hex = groupColor(n.group);
    const light = toHsl(rgb(S.background))[2] > 0.5; // on a light map, pale dots would vanish: darken instead
    return n.layer === 'context' ? (light ? shade(hex, 0.45) : tint(hex, 0.6)) : mix(hex, n.linked ? 0.8 : 0.5);
  }
  if (n.layer === 'memory' && !n.linked) return S.orphanColor;
  return S[`${n.layer}Color`];
};

// ---- canvas & view ---------------------------------------------------------------

const el = document.getElementById('graph');
const canvas = document.createElement('canvas');
el.appendChild(canvas);
const ctx = canvas.getContext('2d');
const tip = document.createElement('div');
tip.className = 'tip';
el.appendChild(tip);

let W = 0, H = 0, dpr = 1;
const view = { x: 0, y: 0, k: 1 };    // screen = world * k + (W/2 + x, H/2 + y)
let tween = null;

new ResizeObserver(() => {
  dpr = window.devicePixelRatio || 1;
  W = el.clientWidth; H = el.clientHeight;
  canvas.width = W * dpr; canvas.height = H * dpr;
  canvas.style.width = `${W}px`; canvas.style.height = `${H}px`;
}).observe(el);

const toScreen = (x, y) => [x * view.k + W / 2 + view.x, y * view.k + H / 2 + view.y];
const toWorld = (sx, sy) => [(sx - W / 2 - view.x) / view.k, (sy - H / 2 - view.y) / view.k];

function animateView(target, ms = 700) {
  if (!ms) { Object.assign(view, target); tween = null; return; }
  tween = { from: { ...view }, to: target, start: performance.now(), ms };
}

function fit(ms = 700) {
  const shown = nodes.filter((n) => visible(n) && n.x != null);
  if (!shown.length || !W) return;
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const n of shown) { x0 = Math.min(x0, n.x); y0 = Math.min(y0, n.y); x1 = Math.max(x1, n.x); y1 = Math.max(y1, n.y); }
  const pad = 90; // room for the ring and group labels
  const k = Math.min(2.2, Math.max(0.2, Math.min((W - pad * 2) / (x1 - x0 || 1), (H - pad * 2) / (y1 - y0 || 1))));
  animateView({ k, x: -((x0 + x1) / 2) * k, y: -((y0 + y1) / 2) * k }, ms);
}

function focus(n, k = Math.max(view.k, 1.6)) {
  if (n?.x == null) return;
  animateView({ k, x: -n.x * k, y: -n.y * k });
}

// ---- layout ----------------------------------------------------------------------

let simulation = null;

function place() {
  const sp = S.spread;
  // Core notes sit evenly on a small ring around the centre, persona notes on the persona ring (top),
  // with the installed personas spaced around the rest of that ring.
  const core = nodes.filter((n) => n.layer === 'core' && !isPersonaNote(n));
  core.forEach((n, i) => {
    const a = -Math.PI / 2 + (i / core.length) * Math.PI * 2 + Math.PI / core.length;
    n.fx = Math.cos(a) * R.core * sp; n.fy = Math.sin(a) * R.core * sp;
  });
  const personaNotes = nodes.filter(isPersonaNote);
  // The persona's own notes travel with it: small dots on the ring either side of its marker.
  personaNotes.forEach((n, i) => {
    const side = i % 2 ? 1 : -1, step = Math.floor(i / 2) + 1;
    const a = -Math.PI / 2 + side * step * 0.13;
    n.fx = Math.cos(a) * R.persona * sp; n.fy = Math.sin(a) * R.persona * sp;
  });
  const others = personas.filter((p) => !p.active);
  const start = personas.some((p) => p.active) ? 1 : 0;
  personas.forEach((p) => {
    const i = p.active ? 0 : start + others.indexOf(p);
    p.angle = -Math.PI / 2 + (i / Math.max(1, others.length + start)) * Math.PI * 2;
  });

  // Groups split the circle into equal sectors; packs sit between them on the outer ring.
  groupList = [...new Set(nodes.filter(inGroup).map((n) => n.group))].sort();
  groupAngle = new Map(groupList.map((g, i) => [g, -Math.PI / 2 + ((i + 0.5) / groupList.length) * Math.PI * 2]));
  const packs = [...new Set(nodes.filter((n) => n.layer === 'pack').map((n) => n.pack))].sort();
  packAnchor = new Map(packs.map((p, i) => {
    const a = -Math.PI / 2 + ((i + 0.5) / packs.length) * Math.PI * 2 + Math.PI / Math.max(2, groupList.length);
    return [p, { x: Math.cos(a) * R.pack * sp, y: Math.sin(a) * R.pack * sp }];
  }));

  const target = (n) => {
    if (n.layer === 'pack') return packAnchor.get(n.pack);
    if (!inGroup(n)) return null;
    const a = groupAngle.get(n.group);
    const r = (n.layer === 'context' ? R.context + 30 : R.memory - 30) * sp;
    return { x: Math.cos(a) * r, y: Math.sin(a) * r };
  };
  const pull = (n) => (n.layer === 'pack' ? 0.25 : inGroup(n) ? 0.22 : 0);
  const ring = (n) => (n.layer === 'core' ? 0 : R[n.layer] * sp);

  simulation?.stop();
  simulation = forceSimulation(nodes, 2)
    .force('charge', forceManyBody().strength(-26 * sp).distanceMax(220))
    .force('link', forceLink(links).id((n) => n.id)
      .distance((l) => (l.kind === 'manual' ? 40 : 70) * sp)
      .strength((l) => (l.kind === 'manual' ? 0.12 : 0.02 * (l.weight ?? 1))))
    .force('ring', forceRadial(ring).strength((n) => (n.layer === 'core' ? 0 : inGroup(n) ? 0.05 : 0.35)))
    .force('x', forceX((n) => target(n)?.x ?? 0).strength(pull))
    .force('y', forceY((n) => target(n)?.y ?? 0).strength(pull))
    .force('collide', forceCollide((n) => radius(n) + 7))
    .stop();
}

// Settles the layout before the first frame: a map that holds still is easier to read than one that wobbles in.
function settle(ticks) {
  simulation.alpha(1);
  for (let i = 0; i < ticks; i++) simulation.tick();
}

// ---- drawing -------------------------------------------------------------------

function draw() {
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.fillStyle = S.background;
  ctx.fillRect(0, 0, W, H);
  ctx.setTransform(dpr * view.k, 0, 0, dpr * view.k, dpr * (W / 2 + view.x), dpr * (H / 2 + view.y));
  const px = 1 / view.k; // one screen pixel in world units
  const fade = 1 - dim * 0.8;

  drawRings(px);
  drawNebulas(fade);
  drawLinks(px);
  drawPulses(px);
  drawPersonaRing(px, fade);
  for (const n of nodes) if (visible(n) && n.x != null) drawNode(n, px);
  drawLabels();
}

function drawRings(px) {
  ctx.lineWidth = px;
  ctx.setLineDash([2 * px, 5 * px]);
  ctx.strokeStyle = mix(S.contextColor, 0.14);
  for (const layer of ['context', 'memory', 'pack']) {
    if (!layersOn.has(layer) || (layer === 'pack' && !packAnchor.size)) continue;
    ctx.beginPath();
    ctx.arc(0, 0, R[layer] * S.spread, 0, Math.PI * 2);
    ctx.stroke();
  }
  ctx.setLineDash([]);
}

// A nebula is the union of discs around a group's notes and along spokes to their centre. It is painted small and
// scaled up, which softens its edge; light gathers around each note and the centre, then fine grain and a few faint
// specks make it read as gas rather than a flat shape. Painting is cached and redone only when zoom or layout change.
const NEBULA_SOFTEN = 6;       // the body is painted at 1/6 resolution: the upscale is the soft edge
const nebulaCache = new Map(); // group → { key, image, x, y, w, h }

const grainPattern = (() => {
  const c = document.createElement('canvas');
  c.width = c.height = 128;
  const g = c.getContext('2d');
  const img = g.createImageData(128, 128);
  for (let i = 0; i < img.data.length; i += 4) {
    const v = Math.random() < 0.5 ? 0 : 255;
    img.data[i] = img.data[i + 1] = img.data[i + 2] = v;
    img.data[i + 3] = Math.random() * 56;
  }
  g.putImageData(img, 0, 0);
  return c;
})();

// Same name, same specks: a small seeded generator.
function seeded(text) {
  let h = [...text].reduce((a, c) => (a * 31 + c.charCodeAt(0)) >>> 0, 2166136261);
  return () => ((h = (h * 1664525 + 1013904223) >>> 0) / 4294967296);
}

function nebulaShape(c, members, cx, cy, r) {
  c.beginPath();
  for (const n of members) {
    c.moveTo(n.x + r, n.y); c.arc(n.x, n.y, r, 0, Math.PI * 2);
    // Discs along the spoke keep the nebula in one piece when a note drifts away from the rest.
    const d = Math.hypot(n.x - cx, n.y - cy), steps = Math.floor(d / (r * 0.5));
    for (let i = 1; i < steps; i++) {
      const x = cx + ((n.x - cx) * i) / steps, y = cy + ((n.y - cy) * i) / steps;
      c.moveTo(x + r * 0.7, y); c.arc(x, y, r * 0.7, 0, Math.PI * 2);
    }
  }
}

function paintNebula(g, members, scale) {
  const r = NEBULA_RADIUS * S.spread;
  const cx = members.reduce((a, n) => a + n.x, 0) / members.length;
  const cy = members.reduce((a, n) => a + n.y, 0) / members.length;
  const pad = r * 1.6;
  const x0 = Math.min(...members.map((n) => n.x)) - pad, y0 = Math.min(...members.map((n) => n.y)) - pad;
  const w = Math.max(...members.map((n) => n.x)) + pad - x0, h = Math.max(...members.map((n) => n.y)) + pad - y0;
  const sc = Math.min(scale, Math.sqrt(3e6 / (w * h))); // cap the image at ~3 megapixels when zoomed far in
  const t = nebulaTones(groupColor(g));

  // 1. Body and light, painted small.
  const small = document.createElement('canvas');
  small.width = Math.max(1, Math.ceil((w * sc) / NEBULA_SOFTEN));
  small.height = Math.max(1, Math.ceil((h * sc) / NEBULA_SOFTEN));
  const s1 = small.getContext('2d');
  s1.setTransform(small.width / w, 0, 0, small.height / h, -x0 * (small.width / w), -y0 * (small.height / h));
  nebulaShape(s1, members, cx, cy, r);
  s1.fillStyle = hsla(t.h, ...t.body, 1);
  s1.fill();
  s1.globalCompositeOperation = 'source-atop';
  const spot = (x, y, radius, alpha) => {
    const grd = s1.createRadialGradient(x, y, 0, x, y, radius);
    grd.addColorStop(0, hsla(t.h, ...t.glow, alpha));
    grd.addColorStop(1, hsla(t.h, ...t.glow, 0));
    s1.fillStyle = grd;
    s1.fillRect(x - radius, y - radius, radius * 2, radius * 2);
  };
  const extent = Math.max(r, ...members.map((n) => Math.hypot(n.x - cx, n.y - cy)));
  spot(cx, cy, extent + r, 0.55);
  for (const n of members) spot(n.x, n.y, r * 0.9, 0.35);

  // 2. Scaled up to full size (the soft edge), then grain and specks only where the gas is.
  const full = document.createElement('canvas');
  full.width = Math.max(1, Math.ceil(w * sc));
  full.height = Math.max(1, Math.ceil(h * sc));
  const f = full.getContext('2d');
  f.imageSmoothingEnabled = true;
  f.imageSmoothingQuality = 'high';
  f.drawImage(small, 0, 0, full.width, full.height);
  f.globalCompositeOperation = 'source-atop';
  f.fillStyle = f.createPattern(grainPattern, 'repeat');
  f.fillRect(0, 0, full.width, full.height);
  const rand = seeded(g);
  f.setTransform(full.width / w, 0, 0, full.height / h, -x0 * (full.width / w), -y0 * (full.height / h));
  for (let i = 0; i < members.length * 4; i++) {
    const n = members[Math.floor(rand() * members.length)];
    const a = rand() * Math.PI * 2, d = Math.sqrt(rand()) * r * 1.1;
    f.globalAlpha = 0.25 + rand() * 0.45;
    f.fillStyle = hsla(t.h, t.glow[0] * 0.5, 0.88, 1);
    f.beginPath();
    f.arc(n.x + Math.cos(a) * d, n.y + Math.sin(a) * d, (0.4 + rand() * 0.7) / sc, 0, Math.PI * 2);
    f.fill();
  }
  return { image: full, x: x0, y: y0, w, h };
}

function drawNebulas(fade) {
  // Repaint at zoom steps of 25 %: in between, the cached image is scaled, which nobody notices.
  const zoomStep = Math.round(Math.log(view.k) / Math.log(1.25));
  const scale = Math.pow(1.25, zoomStep) * dpr;
  for (const g of groupList) {
    const members = nodes.filter((n) => inGroup(n) && n.group === g && visible(n) && n.x != null);
    if (!members.length) continue;
    const key = [zoomStep, dpr, groupColor(g), S.background, S.spread,
      ...members.map((n) => `${n.id}@${Math.round(n.x)},${Math.round(n.y)}`)].join('|');
    let cached = nebulaCache.get(g);
    if (cached?.key !== key) { cached = { key, ...paintNebula(g, members, scale) }; nebulaCache.set(g, cached); }
    ctx.globalAlpha = Math.min(1, 0.62 * S.nebula) * fade;
    ctx.drawImage(cached.image, cached.x, cached.y, cached.w, cached.h);
    ctx.globalAlpha = 1;
  }
}

// ---- impulses: small signals travelling along the lines ------------------------------

let pulses = [];      // { link, t (0…1), forward, lit }
let pulseBudget = 0;
const PULSE_SPEED = 110; // world units per second

function emitPulse(link, lit = false) {
  pulses.push({ link, t: 0, forward: Math.random() < 0.5, lit });
}

function stepPulses(seconds) {
  pulseBudget = Math.min(pulseBudget + seconds * S.pulseRate, 4);
  if (pulseBudget >= 1) {
    // During a recall the signals run between the answer's notes only.
    const pool = litLinks.size ? [...litLinks]
      : links.filter((l) => (S.showAutoLinks || l.kind === 'manual') && visible(l.source) && visible(l.target));
    for (; pulseBudget >= 1; pulseBudget--) {
      if (!pool.length) break;
      // Linked notes carry more traffic than the automatic similarity lines.
      const pick = pool[Math.floor(Math.random() * pool.length)];
      if (pick.kind === 'manual' || litLinks.size || Math.random() < 0.4) emitPulse(pick, litLinks.has(pick));
    }
  }
  for (const p of pulses) {
    const len = Math.hypot(p.link.target.x - p.link.source.x, p.link.target.y - p.link.source.y) || 1;
    p.t += (seconds * PULSE_SPEED) / len;
  }
  pulses = pulses.filter((p) => p.t < 1);
}

function drawPulses(px) {
  for (const p of pulses) {
    const a = p.forward ? p.link.source : p.link.target, b = p.forward ? p.link.target : p.link.source;
    if (!visible(a) || !visible(b) || a.x == null || b.x == null) continue;
    const len = Math.hypot(b.x - a.x, b.y - a.y) || 1;
    const head = p.t, tail = Math.max(0, p.t - 26 / len);
    const hx = a.x + (b.x - a.x) * head, hy = a.y + (b.y - a.y) * head;
    const tx = a.x + (b.x - a.x) * tail, ty = a.y + (b.y - a.y) * tail;
    const color = p.lit ? S.recallColor : S.pulseColor;
    const strength = (p.lit ? 1 : 1 - dim * 0.9) * Math.sin(Math.PI * Math.min(1, p.t * 1.15)); // fade in and out
    if (strength <= 0.02) continue;
    const grd = ctx.createLinearGradient(tx, ty, hx, hy);
    grd.addColorStop(0, rgba(color, 0));
    grd.addColorStop(1, rgba(color, 0.7 * strength));
    ctx.strokeStyle = grd;
    ctx.lineWidth = 1.4 * px;
    ctx.lineCap = 'round';
    ctx.beginPath(); ctx.moveTo(tx, ty); ctx.lineTo(hx, hy); ctx.stroke();
    ctx.fillStyle = rgba(color, strength);
    ctx.beginPath(); ctx.arc(hx, hy, 1.7 * px, 0, Math.PI * 2); ctx.fill();
  }
}

function drawLinks(px) {
  for (const l of links) {
    const a = l.source, b = l.target;
    if (!visible(a) || !visible(b) || a.x == null || b.x == null) continue;
    const lit = litLinks.has(l);
    const near = hovered && (a === hovered || b === hovered);
    if (!lit && !near && l.kind !== 'manual' && !S.showAutoLinks) continue;
    let color, alpha, width = px;
    if (lit) { color = S.recallColor; alpha = 0.85; width = 1.5 * px; }
    else if (near) { color = S.contextColor; alpha = 0.55; }
    else {
      color = l.kind === 'manual' ? S.manualLinkColor : S.autoLinkColor;
      alpha = (l.kind === 'manual' ? S.manualLinkOpacity : S.autoLinkOpacity) * (1 - dim * 0.85) * (hovered ? 0.5 : 1);
    }
    ctx.strokeStyle = rgba(color, alpha);
    ctx.lineWidth = width;
    ctx.beginPath();
    ctx.moveTo(a.x, a.y);
    ctx.lineTo(b.x, b.y);
    ctx.stroke();
  }
}

function drawPersonaRing(px, fade) {
  if (!layersOn.has('core') || (!personas.length && !nodes.some(isPersonaNote))) return;
  const r = R.persona * S.spread;
  ctx.strokeStyle = mix(S.personaColor, 0.6 * fade);
  ctx.lineWidth = 1.5 * px;
  ctx.beginPath();
  ctx.arc(0, 0, r, 0, Math.PI * 2);
  ctx.stroke();
  for (const p of personas) {
    const x = Math.cos(p.angle) * r, y = Math.sin(p.angle) * r;
    p.x = x; p.y = y;
    const size = (p.active ? SIZE.persona : SIZE.persona * 0.62) * S.nodeSize;
    ctx.beginPath();
    ctx.arc(x, y, size, 0, Math.PI * 2);
    ctx.fillStyle = p.active ? mix(S.personaColor, fade) : S.background;
    ctx.fill();
    if (!p.active) {
      ctx.strokeStyle = mix(S.personaColor, (p === hovered ? 1 : 0.8) * fade);
      ctx.lineWidth = 1.5 * px;
      ctx.stroke();
    }
  }
}

function drawNode(n, px) {
  const r = radius(n);
  const hit = hits.has(n.id);
  const faded = (hovered && hovered !== n && !neighbours.get(hovered.id)?.has(n.id) && !hovered.isPersona) ? 0.35 : 1;
  // Faded dots are drawn in a solid colour closer to the background, so no line shows through them.
  const strength = (hit ? 1 : (1 - dim * 0.82) * faded) * (n.isPrivate ? 0.5 : 1);
  ctx.beginPath();
  ctx.arc(n.x, n.y, r, 0, Math.PI * 2);
  const color = fill(n);
  ctx.fillStyle = color ? mixColor(color, strength) : S.background;
  ctx.fill();
  if (!color) {
    ctx.strokeStyle = mixColor(S.packColor, strength);
    ctx.lineWidth = 1.5 * px;
    ctx.stroke();
  }
  // Rings around a node: recall hit (solid), proposal waiting for review (dashed), selection (outer).
  const ringAt = (gap, color, dash) => {
    ctx.beginPath();
    ctx.setLineDash(dash ? [3 * px, 3 * px] : []);
    ctx.arc(n.x, n.y, r + gap * px, 0, Math.PI * 2);
    ctx.strokeStyle = color;
    ctx.lineWidth = 1.5 * px;
    ctx.stroke();
    ctx.setLineDash([]);
  };
  if (hit) ringAt(4, S.recallColor);
  if (n.proposal) ringAt(4, mix(S.contextColor, 0.6), true); // quiet: lime means “in the AI's context”
  if (n === selected) ringAt(hit || n.proposal ? 8 : 4, S.contextColor);
  if (n.flash > 0.01) { // born or recalled: one ring that widens and fades
    ctx.globalAlpha = n.flash;
    ringAt(4 + (1 - n.flash) * 22, n.layer === 'core' ? S.coreColor : S.recallColor);
  }
  ctx.globalAlpha = 1;
}

// ---- labels (screen space, constant size, never overlapping) ----------------------

function labelPriority(n) {
  if (n === hovered || n === selected) return 0;
  if (hits.has(n.id)) return 1;
  if (n.layer === 'core') return 2;
  return { context: 4, pack: 5, memory: 6 }[n.layer] - Math.min(1, (n.degree || 0) / 10);
}

function wantsLabel(n) {
  if (n === hovered || n === selected || hits.has(n.id)) return true;
  if (isPersonaNote(n)) return false; // the ring already names the persona
  if (dim > 0.5) return false;
  const mode = { none: 0, core: 1, context: 2, all: 3 }[S.labels] ?? 2;
  if (n.layer === 'core') return mode >= 1;
  if (n.layer === 'context') return mode >= 2 && view.k > 0.75;
  if (n.layer === 'pack') return mode >= 2 && view.k > 1.1;
  return (mode >= 3 && view.k > 0.9) || view.k > 2.2;
}

function drawLabels() {
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  const placed = [];
  const free = (b) => !placed.some((p) => b.x < p.x + p.w && b.x + b.w > p.x && b.y < p.y + p.h && b.y + b.h > p.y);
  const text = (str, x, y, { size = 11, weight = 500, color = S.contextColor, align = 'left', spacing = 0, force = false, alpha = 1 }) => {
    ctx.font = `${weight} ${size * S.labelSize}px ${FONT}`;
    ctx.letterSpacing = `${spacing}px`;
    const w = ctx.measureText(str).width, h = size * S.labelSize * 1.25;
    const bx = align === 'center' ? x - w / 2 : align === 'right' ? x - w : x;
    const box = { x: bx - 3, y: y - h / 2 - 2, w: w + 6, h: h + 4 };
    if (!force && !free(box)) return false;
    placed.push(box);
    ctx.globalAlpha = alpha;
    ctx.fillStyle = color;
    ctx.textAlign = align;
    ctx.textBaseline = 'middle';
    ctx.fillText(str, x, y);
    ctx.globalAlpha = 1;
    return true;
  };
  const zone = { size: 9.5, weight: 600, spacing: 1.6, align: 'center', color: mix(S.contextColor, 0.42) };

  // The map explains itself: each ring names what it holds and when the AI gets it.
  if (dim < 0.5) {
    const core = nodes.some((n) => n.layer === 'core' && !isPersonaNote(n));
    if (core && layersOn.has('core')) {
      const [cx, cy] = toScreen(0, 0);
      text('CORE', cx, cy - 7, { ...zone, color: S.coreColor, size: 10.5, force: true });
      text('always loaded', cx, cy + 8, { size: 10, color: mix(S.contextColor, 0.5), align: 'center', force: true });
    }
    for (const [layer, title, when] of [['context', 'CONTEXT', 'when relevant'], ['memory', 'MEMORY', 'on search'], ['pack', 'PACKS', 'installed knowledge']]) {
      if (!layersOn.has(layer) || (layer === 'pack' && !packAnchor.size)) continue;
      const [x, y] = toScreen(0, -R[layer] * S.spread);
      text(`${title} · ${when.toUpperCase()}`, x, y, { ...zone, force: true });
    }
  }

  // Groups: name and size above each nebula.
  for (const g of groupList) {
    const members = nodes.filter((n) => inGroup(n) && n.group === g && visible(n) && n.x != null);
    if (!members.length) continue;
    const cx = members.reduce((s, n) => s + n.x, 0) / members.length;
    const top = Math.min(...members.map((n) => n.y)) - NEBULA_RADIUS * S.spread;
    const [x, y] = toScreen(cx, top);
    const alpha = 1 - dim * 0.7;
    text(g.toUpperCase(), x, y - 20, { size: 11.5, weight: 700, spacing: 1.4, align: 'center', color: groupColor(g), force: true, alpha });
    text(`${members.length} notes`, x, y - 6, { size: 10, align: 'center', color: mix(S.contextColor, 0.5), force: true, alpha });
  }

  // Packs: a quiet name above each constellation of installed knowledge.
  if (layersOn.has('pack')) {
    for (const p of packAnchor.keys()) {
      const members = nodes.filter((n) => n.layer === 'pack' && n.pack === p && visible(n) && n.x != null);
      if (!members.length) continue;
      const cx = members.reduce((s, n) => s + n.x, 0) / members.length;
      const [x, y] = toScreen(cx, Math.min(...members.map((n) => n.y)));
      text(p.toUpperCase(), x, y - 16, { size: 10, weight: 600, spacing: 1.2, align: 'center', color: S.packColor, force: true, alpha: 1 - dim * 0.7 });
    }
  }

  // Persona ring: the active persona's name, and the others' on hover.
  if (layersOn.has('core')) {
    for (const p of personas) {
      if (!p.active && p !== hovered) continue;
      const [x, y] = toScreen(p.x, p.y);
      const above = Math.sin(p.angle) < 0;
      if (p.active) {
        text('PERSONA', x, y + (above ? -30 : 30), { ...zone, color: S.personaColor, force: true });
        text(p.name, x, y + (above ? -16 : 16), { size: 12, weight: 600, align: 'center', color: mix(S.personaColor, 1), force: true });
      } else {
        text(`${p.name} · click to switch`, x, y + (above ? -16 : 16), { size: 11, weight: 500, align: 'center', color: S.contextColor, force: true });
      }
    }
  }

  const candidates = nodes.filter((n) => visible(n) && n.x != null && wantsLabel(n)).sort((a, b) => labelPriority(a) - labelPriority(b));
  for (const n of candidates) {
    const [x, y] = toScreen(n.x, n.y);
    const r = radius(n) * view.k;
    const hit = hits.has(n.id);
    const strong = n.layer === 'core' || hit || n === hovered || n === selected;
    const color = hit ? S.recallColor : n.layer === 'core' ? (isPersonaNote(n) ? mix(S.personaColor, 1) : S.contextColor)
      : n.layer === 'memory' ? mix(S.contextColor, 0.62) : n.layer === 'pack' ? S.packColor : S.contextColor;
    const title = n.proposal ? `new · ${n.title}` : n.title;
    const short = title.length > 34 && !strong ? `${title.slice(0, 32)}…` : title;
    // Core labels point away from the centre; everything else sits to the right of its dot.
    const left = n.layer === 'core' && !isPersonaNote(n) && n.x < -1;
    text(short, left ? x - r - 6 : x + r + 6, y, {
      size: strong ? 12 : 11, weight: strong ? 600 : 500, color, align: left ? 'right' : 'left',
      force: n === hovered || n === selected || (n.layer === 'core' && !hit), alpha: hit ? 1 : 1 - dim * 0.8,
    });
  }
}

// ---- frame loop --------------------------------------------------------------------

let lastFrame = performance.now();
(function frame(now) {
  const steps = Math.min(60, (now - lastFrame) / (1000 / 60)); // in 60 fps frames, so fades keep time when frames are skipped
  lastFrame = now;
  if (tween) {
    const t = Math.min(1, (now - tween.start) / tween.ms);
    const e = 1 - Math.pow(1 - t, 3);
    for (const k of ['x', 'y', 'k']) view[k] = tween.from[k] + (tween.to[k] - tween.from[k]) * e;
    if (t >= 1) tween = null;
  }
  dim += (dimTarget - dim) * (1 - Math.pow(0.88, steps));
  stepPulses(steps / 60);
  for (const n of nodes) if (n.flash) n.flash = n.flash < 0.01 ? 0 : n.flash * Math.pow(0.965, steps);
  if (W) draw();
  requestAnimationFrame(frame);
})(performance.now());

// ---- interaction -----------------------------------------------------------------

function pick(sx, sy) {
  const [wx, wy] = toWorld(sx, sy);
  const slop = 5 / view.k;
  if (layersOn.has('core')) {
    for (const p of personas) {
      if (p.x != null && Math.hypot(p.x - wx, p.y - wy) < SIZE.persona * S.nodeSize + slop) return p;
    }
  }
  let best = null, bestD = Infinity;
  for (const n of nodes) {
    if (!visible(n) || n.x == null) continue;
    const d = Math.hypot(n.x - wx, n.y - wy);
    if (d < radius(n) + slop && d < bestD) { best = n; bestD = d; }
  }
  return best;
}

let drag = null;
canvas.addEventListener('pointerdown', (e) => {
  drag = { x: e.clientX, y: e.clientY, vx: view.x, vy: view.y, moved: false };
  canvas.setPointerCapture(e.pointerId);
});
canvas.addEventListener('pointermove', (e) => {
  const rect = canvas.getBoundingClientRect();
  if (drag) {
    const dx = e.clientX - drag.x, dy = e.clientY - drag.y;
    if (Math.hypot(dx, dy) > 3) drag.moved = true;
    if (drag.moved) { tween = null; view.x = drag.vx + dx; view.y = drag.vy + dy; canvas.style.cursor = 'grabbing'; return; }
  }
  const found = pick(e.clientX - rect.left, e.clientY - rect.top);
  if (found !== hovered) hovered = found;
  canvas.style.cursor = found ? 'pointer' : 'default';
  showTip(found, e.clientX - rect.left, e.clientY - rect.top);
});
canvas.addEventListener('pointerleave', () => { hovered = null; showTip(null); });
canvas.addEventListener('pointerup', (e) => {
  const wasDrag = drag?.moved;
  drag = null;
  canvas.style.cursor = hovered ? 'pointer' : 'default';
  if (wasDrag) return;
  const rect = canvas.getBoundingClientRect();
  const found = pick(e.clientX - rect.left, e.clientY - rect.top);
  if (found?.isPersona) { if (!found.active) post({ type: 'persona', id: found.id }); return; }
  if (found) { selected = found; post({ type: 'select', id: found.id }); focus(found); }
  else clearRecall();
});
canvas.addEventListener('dblclick', (e) => { if (!pick(e.offsetX, e.offsetY)) overview(); });

// Trackpad: two-finger scroll pans, pinch (ctrlKey) zooms. A mouse wheel zooms.
canvas.addEventListener('wheel', (e) => {
  e.preventDefault();
  tween = null;
  const rect = canvas.getBoundingClientRect();
  const sx = e.clientX - rect.left, sy = e.clientY - rect.top;
  const isMouseWheel = !e.ctrlKey && e.deltaMode === 1;
  if (e.ctrlKey || isMouseWheel) {
    const [wx, wy] = toWorld(sx, sy);
    const k = Math.min(6, Math.max(0.15, view.k * Math.exp(-e.deltaY * (isMouseWheel ? 0.05 : 0.01))));
    view.k = k;
    view.x = sx - W / 2 - wx * k;
    view.y = sy - H / 2 - wy * k;
  } else {
    view.x -= e.deltaX;
    view.y -= e.deltaY;
  }
}, { passive: false });

function showTip(n, x, y) {
  if (!n) { tip.style.display = 'none'; return; }
  const where = n.isPersona ? (n.active ? 'Active persona' : 'Persona · click to switch')
    : n.layer === 'pack' ? `Pack · ${n.pack}` : isPersonaNote(n) ? `Persona · ${n.pack}`
    : [n.folder, n.group].filter(Boolean).join(' · ');
  tip.innerHTML = `<b>${escapeHtml(n.isPersona ? n.name : n.title)}</b>${where ? `<span>${escapeHtml(where)}</span>` : ''}`;
  tip.style.display = 'flex';
  tip.style.left = `${Math.min(x + 14, W - tip.offsetWidth - 8)}px`;
  tip.style.top = `${y + 14}px`;
}

// ---- API for Swift ---------------------------------------------------------------

function groupColor(g) { return groupColors.get(g) ?? DEFAULT_GROUP_COLORS[[...g].reduce((h, c) => (h * 31 + c.charCodeAt(0)) >>> 0, 7) % DEFAULT_GROUP_COLORS.length]; }
// Fallback only: the app sends every group's colour (Groups.palette in CortexKit).
const DEFAULT_GROUP_COLORS = ['#4fc3d9', '#ef86ad', '#f0b65a', '#6fd3a0', '#7d9bff', '#e8875a', '#a3b8d9', '#d8d36a'];

let fitted = false;

// Called on launch and on every live reload: notes that already exist keep their place, new ones are born with a flash.
function setGraph(data) {
  const previous = new Map(nodes.map((n) => [n.id, n]));
  nodes = data.nodes.map((n) => ({ ...n }));
  for (const n of nodes) {
    const p = previous.get(n.id);
    if (p) { n.x = p.x; n.y = p.y; n.flash = p.flash; }
    else if (previous.size) n.flash = 1;
  }
  nodesById = new Map(nodes.map((n) => [n.id, n]));
  links = data.links.filter((l) => nodesById.has(l.source) && nodesById.has(l.target)).map((l) => ({ ...l }));
  neighbours = new Map(nodes.map((n) => [n.id, new Set()]));
  linksByNode = new Map(nodes.map((n) => [n.id, []]));
  for (const l of links) {
    neighbours.get(l.source).add(l.target); neighbours.get(l.target).add(l.source);
    linksByNode.get(l.source).push(l); linksByNode.get(l.target).push(l);
  }
  for (const n of nodes) n.linked = neighbours.get(n.id).size > 0;
  groupColors = new Map(Object.entries(data.groups || {}));
  personas = (data.personas || []).map((p) => ({ ...p, isPersona: true }));
  hovered = null;
  selected = selected && nodesById.get(selected.id);

  pulses = [];
  place(); // forceLink swaps the ids in links for the node objects
  settle(previous.size ? 120 : 400);
  if (hits.size) litLinks = litLinksFor([...hits.keys()]);
  if (!fitted) { fitted = true; if (W) fit(0); else requestAnimationFrame(() => fit(0)); }
}

// hits: [{id, score}] best first. They light up in rank order and stay lit until clearRecall.
let timers = [];
function recall(list) {
  clearRecall();
  dimTarget = 1;
  hits = new Map();
  litLinks = litLinksFor(list.map((h) => h.id));
  list.forEach((h, rank) => timers.push(setTimeout(() => {
    const n = nodesById.get(h.id);
    if (!n) return;
    hits.set(h.id, h.score);
    n.flash = 1;
    for (const l of linksByNode.get(h.id) || []) if (litLinks.has(l)) emitPulse(l, true);
  }, rank * 120)));
  const first = nodesById.get(list[0]?.id);
  if (first) focusAll(list.map((h) => nodesById.get(h.id)).filter(Boolean));
}

// Frames all hits at once, so the answer's sources can be seen together.
function focusAll(found) {
  const xs = found.map((n) => n.x), ys = found.map((n) => n.y);
  const pad = 120;
  const w = Math.max(...xs) - Math.min(...xs), h = Math.max(...ys) - Math.min(...ys);
  const k = Math.min(1.8, Math.max(0.35, Math.min((W - pad * 2) / (w || 1), (H - pad * 2) / (h || 1))));
  const cx = (Math.max(...xs) + Math.min(...xs)) / 2, cy = (Math.max(...ys) + Math.min(...ys)) / 2;
  animateView({ k, x: -cx * k, y: -cy * k }, 800);
}

function litLinksFor(ids) {
  const set = new Set(ids);
  // Only the lines between two hits: the answer's own network, not everything it touches.
  return new Set(ids.flatMap((id) => linksByNode.get(id) || []).filter((l) => set.has(l.source.id) && set.has(l.target.id)));
}

function clearRecall() {
  timers.forEach(clearTimeout);
  timers = [];
  hits = new Map();
  litLinks = new Set();
  dimTarget = 0;
}

function select(id) {
  const n = nodesById.get(id);
  if (!n) return;
  selected = n;
  n.flash = Math.max(n.flash || 0, 0.6);
  focus(n);
}

function setLayers(list) { layersOn = new Set(list); }

// Timeline: only notes created up to `ms` (null = everything). Newly revealed notes flash as they're born.
function setTimeline(ms) {
  const before = timelineCutoff;
  timelineCutoff = ms;
  if (ms != null && before != null && ms > before) for (const n of nodes) if (n.created > before && n.created <= ms) n.flash = 1;
}

// colors: { group: hex }. Recolours the nebulas live while a colour is being picked.
function setGroupColors(colors) { for (const [g, hex] of Object.entries(colors)) groupColors.set(g, hex); }

let pendingStyle = null;
function setStyle(next) {
  if (!pendingStyle) requestAnimationFrame(applyStyle); // coalesce slider drags to one update per frame
  pendingStyle = { ...(pendingStyle || {}), ...next };
}

function applyStyle() {
  const changed = Object.keys(pendingStyle).filter((k) => k in S && pendingStyle[k] !== S[k]);
  for (const k of changed) S[k] = pendingStyle[k];
  pendingStyle = null;
  document.body.style.background = S.background;
  if ((changed.includes('spread') || changed.includes('nodeSize')) && nodes.length) { place(); settle(200); }
}

function overview() { clearRecall(); selected = null; fit(800); }

function escapeHtml(s) {
  return String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
}

window.Cortex = { setGraph, recall, clearRecall, select, setLayers, setTimeline, overview, setStyle, setGroupColors };
post({ type: 'ready' });
