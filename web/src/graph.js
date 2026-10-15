// Cortex neural graph. Every visual parameter lives in `S` and can be changed live via Cortex.setStyle
// (the app's "Darstellung" panel). Recall lights hits, their tags and their connections in S.recallColor.
import ForceGraph3D from '3d-force-graph';
import SpriteText from 'three-spritetext';
import { forceRadial, forceX, forceY, forceZ } from 'd3-force-3d';
import * as THREE from 'three';

// Defaults mirror GraphStyle.swift.
const S = {
  coreColor: '#f3e9df', contextColor: '#e5484d', memoryColor: '#b8a397', orphanColor: '#5e463c', recallColor: '#ffc21a',
  packColor: '#5b9bd5',
  nodeSize: 1, nodeOpacity: 1,
  gloss: 70, reflection: 0.35, glow: 0, glowSize: 4,
  manualLinkColor: '#eb5458', autoLinkColor: '#a0b6b4', manualLinkOpacity: 0.85, autoLinkOpacity: 0.5,
  lineWidth: 0.2, curvature: 0, showAutoLinks: true,
  pulseRate: 6, pulseSize: 1.2, pulseSpeed: 0.01, pulseColor: '#f3e9df',
  labels: 'context', labelSize: 1,
  backgroundInner: '#3a3938', backgroundOuter: '#141414',
  rotation: 0.3, spread: 1,
};

const LAYER = {
  core:    { radius: 0,   size: 5.5, strength: 0.9 },
  context: { radius: 110, size: 3.0, strength: 0.3 },
  memory:  { radius: 230, size: 1.6, strength: 0.15 },
  pack:    { radius: 360, size: 2.4, strength: 0.2 },  // installed knowledge: one constellation per pack
};
const MONO = '"SF Mono", Menlo, monospace';
const FIRE = new THREE.Color(S.recallColor);

const post = (msg) => window.webkit?.messageHandlers?.cortex?.postMessage(msg);

function rgba(hex, alpha) {
  const v = parseInt(hex.slice(1), 16);
  return `rgba(${(v >> 16) & 255},${(v >> 8) & 255},${v & 255},${alpha})`;
}

const haloTexture = (() => {
  const c = document.createElement('canvas');
  c.width = c.height = 128;
  const g = c.getContext('2d');
  const grd = g.createRadialGradient(64, 64, 0, 64, 64, 64);
  grd.addColorStop(0, 'rgba(255,255,255,1)');
  grd.addColorStop(0.2, 'rgba(255,255,255,0.5)');
  grd.addColorStop(0.5, 'rgba(255,255,255,0.12)');
  grd.addColorStop(1, 'rgba(255,255,255,0)');
  g.fillStyle = grd;
  g.fillRect(0, 0, 128, 128);
  return new THREE.CanvasTexture(c);
})();

const nodeSize = (n) => (LAYER[n.layer].size + Math.sqrt(n.degree || 0) * 0.9) * S.nodeSize;
// Pack notes (and the active persona inside the core) keep their pack colour.
const baseHex = (n) => n.color ?? (n.layer === 'memory' && !n.linked ? S.orphanColor : S[`${n.layer}Color`]);
const hasLabel = (n) => ({ none: false, core: n.layer === 'core', context: n.layer !== 'memory', all: true }[S.labels]);

// ---- label tags ----------------------------------------------------------------

function tag(text, layer) {
  const label = new SpriteText(text.toUpperCase(), (layer === 'core' ? 3.2 : 2.1) * S.labelSize);
  label.fontFace = MONO;
  label.fontWeight = '500';
  label.padding = [3, 1.5];
  label.borderRadius = 0;
  styleTag(label, layer === 'core' ? 'light' : 'dark');
  label.material.depthWrite = false;
  label.center.set(0, 0.5);
  return label;
}

function styleTag(label, style) {
  const s = {
    dark: ['rgba(8,8,8,0.92)', '#e8e2dc'], light: ['#f3efe9', '#111'], fire: [S.recallColor, '#111'],
    proposal: ['rgba(8,8,8,0.92)', S.recallColor],
  }[style];
  label.backgroundColor = s[0];
  label.color = s[1];
}

// ---- nodes ---------------------------------------------------------------------

function makeNode(n) {
  const r = nodeSize(n);
  const group = new THREE.Group();
  const mat = new THREE.MeshPhongMaterial({ transparent: true });
  const mesh = new THREE.Mesh(new THREE.SphereGeometry(r, 28, 20), mat);
  group.add(mesh);

  const halo = new THREE.Sprite(new THREE.SpriteMaterial({
    map: haloTexture, transparent: true, depthWrite: false, blending: THREE.AdditiveBlending,
  }));
  group.add(halo);

  Object.assign(n, { __mat: mat, __mesh: mesh, __halo: halo, __r: r, __label: null, __tempLabel: false });
  n.flash ??= 0; n.hold ??= 0; n.dim ??= 0;
  applyMaterial(n);

  if (hasLabel(n) || n.proposal) {
    n.__label = tag(n.proposal ? `new · ${n.title}` : n.title, n.layer);
    styleTag(n.__label, restingTag(n));
    n.__label.position.set(r + 1.5, r * 0.6, 0);
    group.add(n.__label);
  }
  return group;
}

const restingTag = (n) => (n.proposal ? 'proposal' : n.layer === 'core' ? 'light' : 'dark');

function applyMaterial(n) {
  n.__base = new THREE.Color(baseHex(n));
  n.__mat.shininess = S.gloss;
  n.__mat.specular.setScalar(S.reflection);
}

const el = document.getElementById('graph');
const graph = new ForceGraph3D(el, { controlType: 'orbit' })
  .cooldownTicks(220)
  .backgroundColor('rgba(0,0,0,0)') // gradient comes from CSS behind the canvas
  .showNavInfo(false)
  .nodeThreeObject(makeNode)
  .nodeLabel((n) => `<div class="tip"><b>${escapeHtml(n.title)}</b><span>${escapeHtml(n.folder)}</span></div>`)
  .linkOpacity(1) // library default is 0.2, which multiplies with our per-line alpha
  .linkCurveRotation((l) => (l.__rot ??= Math.random() * Math.PI * 2))
  .onNodeClick((n) => { post({ type: 'select', id: n.id }); focusNode(n); })
  .onBackgroundClick(() => clearRecall());

// ---- links -----------------------------------------------------------------------

let litLinks = new Set();
let recallActive = false;
let layersOn = new Set(['core', 'context', 'memory', 'pack']);
let timelineCutoff = null; // ms; nodes created later are hidden
const nodeVisible = (n) => !!n && layersOn.has(n.layer) && (timelineCutoff == null || n.created <= timelineCutoff);
const endNode = (end) => (typeof end === 'object' ? end : byId(end));

function styleLinks() {
  const color = (l) => (l.kind === 'manual' ? S.manualLinkColor : S.autoLinkColor);
  const alpha = (l) => (l.kind === 'manual' ? S.manualLinkOpacity : S.autoLinkOpacity);
  graph
    .linkColor((l) => (litLinks.has(l) ? S.recallColor : rgba(color(l), recallActive ? alpha(l) * 0.15 : alpha(l))))
    .linkWidth((l) => (litLinks.has(l) ? Math.max(0.5, S.lineWidth * 2) : l.kind === 'manual' ? S.lineWidth : S.lineWidth * 0.65))
    .linkCurvature(() => S.curvature)
    .linkDirectionalParticleColor((l) => (litLinks.has(l) ? S.recallColor : S.pulseColor))
    .linkDirectionalParticleWidth((l) => (litLinks.has(l) ? S.pulseSize * 1.6 : S.pulseSize))
    .linkDirectionalParticleSpeed(() => S.pulseSpeed)
    .linkVisibility((l) => (S.showAutoLinks || l.kind === 'manual') && nodeVisible(endNode(l.source)) && nodeVisible(endNode(l.target)));
}

// ---- forces, lights, camera ---------------------------------------------------

function applyForces() {
  graph.d3Force('charge').strength(-40 * S.spread);
  graph.d3Force('link')
    .distance((l) => (l.kind === 'manual' ? 36 : 64) * S.spread)
    .strength((l) => (l.kind === 'manual' ? 0.5 : 0.08 * l.weight));
  graph.d3Force('radial', forceRadial((n) => LAYER[n.layer].radius * S.spread).strength((n) => LAYER[n.layer].strength));
  // Each pack gathers around its own anchor on the outer ring.
  const anchor = (n) => packAnchors.get(n.pack) ?? { x: 0, y: 0, z: 0 };
  const pull = (n) => (n.layer === 'pack' ? 0.1 : 0);
  graph.d3Force('packX', forceX((n) => anchor(n).x * S.spread).strength(pull));
  graph.d3Force('packY', forceY((n) => anchor(n).y * S.spread).strength(pull));
  graph.d3Force('packZ', forceZ((n) => anchor(n).z * S.spread).strength(pull));
}

let packAnchors = new Map();
function placePacks(nodes) {
  const packs = [...new Set(nodes.filter((n) => n.layer === 'pack').map((n) => n.pack))].sort();
  packAnchors = new Map(packs.map((p, i) => {
    const a = (i / Math.max(1, packs.length)) * Math.PI * 2 + 0.6;
    return [p, { x: Math.cos(a) * 360, y: (i % 2 ? 70 : -70), z: Math.sin(a) * 360 }];
  }));
}

const scene = graph.scene();
scene.add(new THREE.HemisphereLight(0xffffff, 0x302826, 1.2));
const key = new THREE.DirectionalLight(0xffffff, 2.2);
key.position.set(-300, 400, 300);
scene.add(key);
const rim = new THREE.DirectionalLight(0x9fb4c0, 0.8);
rim.position.set(200, -300, -200);
scene.add(rim);

graph.cameraPosition({ x: 0, y: 0, z: 460 });
const controls = graph.controls();
controls.addEventListener('start', () => { controls.autoRotate = false; });

// Track the element, not the window: the native panel beside the graph changes our width.
new ResizeObserver(() => graph.width(el.clientWidth).height(el.clientHeight)).observe(el);

// ---- style -------------------------------------------------------------------

function applyScene() {
  FIRE.set(S.recallColor);
  document.body.style.background =
    `radial-gradient(ellipse 90% 80% at 45% 35%, ${S.backgroundInner} 0%, ${S.backgroundOuter} 100%)`;
  controls.autoRotate = S.rotation > 0;
  controls.autoRotateSpeed = S.rotation;
  styleLinks();
}

applyForces();
applyScene();

const REBUILD = ['nodeSize', 'labels', 'labelSize'];
let pending = null;

function setStyle(next) {
  if (!pending) requestAnimationFrame(applyPending); // coalesce slider drags to one update per frame
  pending = { ...(pending || {}), ...next };
}

function applyPending() {
  const changed = Object.keys(pending).filter((k) => pending[k] !== S[k]);
  Object.assign(S, pending);
  pending = null;
  if (!changed.length) return;

  if (changed.some((k) => REBUILD.includes(k))) {
    clearRecall();
    graph.nodeThreeObject((n) => makeNode(n)); // a new accessor makes every node object rebuild
  } else {
    for (const n of graph.graphData().nodes) if (n.__mat) applyMaterial(n);
  }
  if (changed.includes('spread')) { applyForces(); graph.d3ReheatSimulation(); }
  applyScene();
}

// ---- ambient pulses: random signals along visible lines (lit lines only during a recall) ----

let lastPulse = performance.now();
let pulseBudget = 0;
setInterval(() => {
  const now = performance.now();
  pulseBudget = Math.min(pulseBudget + ((now - lastPulse) / 1000) * S.pulseRate, 5);
  lastPulse = now;
  if (pulseBudget < 1) return;
  const pool = recallActive ? [...litLinks] : graph.graphData().links.filter((l) => l.__lineObj?.visible);
  for (; pulseBudget >= 1; pulseBudget--) {
    if (pool.length) graph.emitParticle(pool[Math.floor(Math.random() * pool.length)]);
  }
}, 50);

// ---- animation: flash decay towards held activation, dimming, glow ---------------

const tmp = new THREE.Color();
let dimTarget = 0;
(function tick() {
  const now = performance.now() / 1000;
  for (const n of graph.graphData().nodes) {
    if (!n.__mat) continue;
    n.flash = n.hold + (n.flash - n.hold) * 0.985;
    n.dim += ((n.flash > 0.08 ? 0 : dimTarget) - n.dim) * 0.06;
    tmp.copy(n.__base).lerp(FIRE, Math.min(1, n.flash * 1.3));
    n.__mat.color.copy(tmp);
    n.__mat.emissive.copy(FIRE).multiplyScalar(n.flash * 0.35);
    n.__mat.opacity = S.nodeOpacity * (1 - n.dim * 0.8) * (n.isPrivate ? 0.45 : 1);
    const breathe = n.proposal ? 0.18 * Math.sin(now * 3) : 0; // proposals pulse until reviewed
    n.__mesh.scale.setScalar(1 + breathe + Math.min(1, n.flash) * (n.layer === 'memory' ? 1.2 : 0.5));
    const glow = Math.min(1, S.glow + (S.glow > 0 ? n.flash * 0.6 : 0)) * (1 - n.dim * 0.85);
    n.__halo.visible = glow > 0.01;
    n.__halo.material.opacity = glow;
    n.__halo.material.color.copy(tmp);
    n.__halo.scale.setScalar(n.__r * S.glowSize * 2 * (1 + n.flash * 0.6));
    if (n.__label) n.__label.material.opacity = 1 - n.dim * 0.85;
  }
  requestAnimationFrame(tick);
})();

// ---- API for Swift ------------------------------------------------------------

let neighbours = new Map();
let linksByNode = new Map();
let nodesById = new Map();

let fitted = false;

// Called on launch and on every live reload: nodes that already exist keep their position,
// new nodes are born with a flash, and an active recall is re-lit on the new data.
function setGraph(data) {
  const previous = new Map(graph.graphData().nodes.map((n) => [n.id, n]));
  for (const n of data.nodes) {
    const p = previous.get(n.id);
    if (p) {
      for (const k of ['x', 'y', 'z', 'vx', 'vy', 'vz', 'flash', 'dim']) n[k] = p[k];
    } else if (previous.size) {
      n.flash = 1;
    }
  }
  nodesById = new Map(data.nodes.map((n) => [n.id, n]));
  neighbours = new Map(data.nodes.map((n) => [n.id, new Set()]));
  linksByNode = new Map(data.nodes.map((n) => [n.id, []]));
  for (const l of data.links) {
    neighbours.get(l.source)?.add(l.target);
    neighbours.get(l.target)?.add(l.source);
    linksByNode.get(l.source)?.push(l);
    linksByNode.get(l.target)?.push(l);
  }
  for (const n of data.nodes) n.linked = neighbours.get(n.id).size > 0;
  placePacks(data.nodes);
  applyForces();
  graph.graphData(data);
  if (recallActive) relight();
  // Frame once the first layout has settled (nodes start at the origin and expand).
  // (rAF is throttled while the window is occluded, so a timer backs up onEngineStop.)
  if (!previous.size) {
    const fitOnce = () => { if (!fitted) { fitted = true; fit(0); } };
    graph.onEngineStop(fitOnce);
    setTimeout(fitOnce, 4000);
  }
}

const byId = (id) => nodesById.get(id);

// hits: [{id, score}] ordered best first. Lights up in rank order and stays lit until clearRecall.
let lastHits = [];
function recall(hits) {
  clearRecall();
  dimTarget = 0.8;
  recallActive = true;
  lastHits = hits;
  litLinks = litLinksFor(hits);
  styleLinks();

  hits.forEach((h, rank) => later(() => {
    const n = byId(h.id);
    if (!n) return;
    n.flash = 1;
    light(n, h.score);
    for (const l of linksByNode.get(n.id) || []) graph.emitParticle(l);
  }, rank * 140));
  if (hits[0]) later(() => focusNode(byId(hits[0].id), 150), 200);
}

function litLinksFor(hits) {
  const ids = new Set(hits.map((h) => h.id));
  return new Set(hits.flatMap((h) => linksByNode.get(h.id) || [])
    .filter((l) => ids.has(l.source.id ?? l.source) || ids.has(l.target.id ?? l.target)));
}

function light(n, score) {
  n.hold = 0.55 + 0.45 * score;
  if (!n.__label) {
    n.__label = tag(n.title, n.layer);
    n.__label.position.set(n.__r + 1.5, n.__r * 0.6, 0);
    n.__threeObj?.add(n.__label);
    n.__tempLabel = true;
  }
  styleTag(n.__label, 'fire');
}

// Re-apply the current recall after a live reload replaced the node and link objects.
function relight() {
  litLinks = litLinksFor(lastHits);
  styleLinks();
  setTimeout(() => lastHits.forEach((h) => { const n = byId(h.id); if (n) light(n, h.score); }), 50);
}

function clearRecall() {
  clearTimers();
  dimTarget = 0;
  recallActive = false;
  litLinks = new Set();
  styleLinks();
  for (const n of graph.graphData().nodes) {
    n.hold = 0;
    if (n.__tempLabel) { n.__threeObj?.remove(n.__label); n.__label = null; n.__tempLabel = false; }
    else if (n.__label) styleTag(n.__label, restingTag(n));
  }
}

function focusNode(n, dist = 120) {
  if (!n) return;
  controls.autoRotate = false;
  const ratio = 1 + dist / Math.hypot(n.x || 1, n.y || 1, n.z || 1);
  graph.cameraPosition({ x: n.x * ratio, y: n.y * ratio, z: n.z * ratio }, n, 1400);
}

function select(id) {
  const n = byId(id);
  if (n) { n.flash = Math.max(n.flash, 0.6); focusNode(n); }
}

function setLayers(layers) {
  layersOn = new Set(layers);
  graph.nodeVisibility((n) => nodeVisible(n));
  styleLinks();
}

// Timeline: show only memories created up to `ms` (null = everything). Newly revealed memories flash as they're born.
function setTimeline(ms) {
  const before = timelineCutoff;
  timelineCutoff = ms;
  if (ms != null && before != null && ms > before) {
    for (const n of graph.graphData().nodes) if (n.created > before && n.created <= ms) n.flash = 1;
  }
  graph.nodeVisibility((n) => nodeVisible(n));
  styleLinks();
}

function overview() {
  clearRecall();
  controls.autoRotate = S.rotation > 0;
  fit(1200);
}

// Frame the connected network; isolated outliers may fall outside the view.
const fit = (ms) => graph.zoomToFit(ms, 10, (n) => n.linked);

let timers = [];
function later(fn, ms) { timers.push(setTimeout(fn, ms)); }
function clearTimers() { timers.forEach(clearTimeout); timers = []; }

function escapeHtml(s) {
  return String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
}

window.Cortex = { setGraph, recall, clearRecall, select, setLayers, setTimeline, overview, setStyle, _graph: graph };
post({ type: 'ready' });
