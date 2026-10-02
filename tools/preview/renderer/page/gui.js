// gui.js - paints the exported GUI paint list as absolutely positioned DOM over the canvas.
// All layout (positions, sizes, wrapping, text sizes) was computed by the Luau runtime with
// Roblox rules; this only draws: backgrounds, UICorner, UIStroke (box-shadow / text
// stroke), UIGradient (CSS gradients), text segments, image placeholders, scroll bars,
// Path2D (SVG), CanvasGroup opacity and ViewportFrame images.

const SVGNS = 'http://www.w3.org/2000/svg';

function css(c, alphaMul = 1) {
  if (!c) return 'transparent';
  const a = (c.length > 3 ? c[3] : 1) * alphaMul;
  return `rgba(${Math.round(c[0] * 255)},${Math.round(c[1] * 255)},${Math.round(c[2] * 255)},${a.toFixed(3)})`;
}

// Samples a keypoint list [[t, ...values]] at t.
function sample(list, t) {
  if (!list.length) return null;
  if (t <= list[0][0]) return list[0].slice(1);
  for (let i = 0; i < list.length - 1; i++) {
    const a = list[i], b = list[i + 1];
    if (t >= a[0] && t <= b[0]) {
      const u = (t - a[0]) / Math.max(b[0] - a[0], 1e-6);
      return a.slice(1).map((v, k) => v + (b[k + 1] - v) * u);
    }
  }
  return list[list.length - 1].slice(1);
}

// CSS linear-gradient for a UIGradient over a base colour [r, g, b, a].
function gradientCss(g, base) {
  // Roblox: Rotation 0 = left→right, 90 = top→bottom; Offset shifts the sequence.
  const stops = new Set([0, 1]);
  for (const k of g.colors) stops.add(k[0]);
  for (const k of g.alphas) stops.add(k[0]);
  const shift = Math.abs(g.rotation % 180) === 90 ? g.offset[1] : g.offset[0];
  const parts = [];
  for (const t of [...stops].sort((a, b) => a - b)) {
    const col = sample(g.colors, t) || [1, 1, 1];
    const al = (sample(g.alphas, t) || [1])[0];
    const c = [base[0] * col[0], base[1] * col[1], base[2] * col[2], base[3] * al];
    const pos = (t + shift) * 100;
    parts.push(`${css(c)} ${pos.toFixed(2)}%`);
  }
  return `linear-gradient(${g.rotation + 90}deg, ${parts.join(', ')})`;
}

let fontFiles = null;
export function setFontFiles(map) { fontFiles = map; }

export function usedFonts(layers) {
  const set = new Set();
  const walk = (items) => {
    for (const it of items) {
      if (it.items) walk(it.items);
      if (it.text) for (const l of it.text.lines) for (const s of l.segs) set.add(`${s.font}|${s.weight}|${s.style}`);
    }
  };
  for (const l of layers) walk(l.items);
  return [...set];
}

function matrixCss(m, dx = 0, dy = 0) {
  return `matrix(${m[0]},${m[1]},${m[2]},${m[3]},${m[4] - dx},${m[5] - dy})`;
}

function strokeShadow(s) {
  const c = css(s.color);
  const t = s.thickness;
  if (s.position === 'Inner') return `inset 0 0 0 ${t}px ${c}`;
  if (s.position === 'Center') return `0 0 0 ${t / 2}px ${c}, inset 0 0 0 ${t / 2}px ${c}`;
  return `0 0 0 ${t}px ${c}`;
}

function paintItem(container, it, viewportImages) {
  let host = container;
  let dx = 0, dy = 0;
  if (it.clip) {
    const [x0, y0, x1, y1] = it.clip;
    if (x1 <= x0 || y1 <= y0) return;
    const clip = document.createElement('div');
    clip.style.cssText = `left:${x0}px;top:${y0}px;width:${x1 - x0}px;height:${y1 - y0}px;overflow:hidden;`;
    container.appendChild(clip);
    host = clip;
    dx = x0; dy = y0;
  }
  if (it.t === 'path') {
    const svg = document.createElementNS(SVGNS, 'svg');
    svg.setAttribute('width', '4000'); svg.setAttribute('height', '4000');
    svg.style.cssText = `position:absolute;left:0;top:0;overflow:visible;transform-origin:0 0;transform:${matrixCss(it.m, dx, dy)}`;
    const p = document.createElementNS(SVGNS, 'path');
    p.setAttribute('d', it.path.d);
    p.setAttribute('fill', 'none');
    p.setAttribute('stroke', css(it.path.color));
    p.setAttribute('stroke-width', String(it.path.thickness));
    p.setAttribute('stroke-linecap', 'round');
    p.setAttribute('stroke-linejoin', 'round');
    svg.appendChild(p);
    host.appendChild(svg);
    return;
  }
  const el = document.createElement('div');
  el.dataset.name = it.name || '';
  el.style.left = '0px'; el.style.top = '0px';
  el.style.width = it.w + 'px'; el.style.height = it.h + 'px';
  el.style.transformOrigin = '0 0';
  el.style.transform = matrixCss(it.m, dx, dy);
  if (it.radius) el.style.borderRadius = it.radius + 'px';
  if (it.bg) {
    if (it.gradient) el.style.background = gradientCss(it.gradient, it.bg);
    else el.style.background = css(it.bg);
  }
  const shadows = [];
  if (it.border) shadows.push(it.border.mode === 'Inset' ? `inset 0 0 0 ${it.border.w}px ${css(it.border.color)}` : `0 0 0 ${it.border.w}px ${css(it.border.color)}`);
  if (it.stroke && it.stroke.thickness > 0 && it.stroke.color[3] > 0) shadows.push(strokeShadow(it.stroke));
  if (shadows.length) el.style.boxShadow = shadows.join(', ');
  const artKey = it.image && window.__artMap && (/rbxassetid:\/\/(\d+)/.exec(it.image.src || '') || [])[1];
  if (artKey && window.__artMap[artKey]) {
    // an uploaded owner picture (art/): drawn for real, tint as brightness, alpha as opacity
    const url = '/art/' + window.__artMap[artKey] + '.png';
    const c = it.image.color;
    const img = document.createElement('div');
    const fit = { Fit: 'contain', Crop: 'cover', Stretch: '100% 100%', Tile: 'auto' }[it.image.scaleType] || '100% 100%';
    let style = `left:0;top:0;width:100%;height:100%;border-radius:inherit;opacity:${c[3]};filter:brightness(${((c[0] + c[1] + c[2]) / 3).toFixed(3)});`;
    if (it.image.slice) {
      const [x0, y0, x1, y1, k] = it.image.slice;
      style += `border-style:solid;border-image:url(${url}) ${y0} ${512 - x1} ${512 - y1} ${x0} fill;border-width:${y0 * k}px ${(512 - x1) * k}px ${(512 - y1) * k}px ${x0 * k}px;box-sizing:border-box;`;
    } else {
      style += `background:url(${url}) center/${fit} no-repeat;`;
    }
    img.style.cssText = style;
    el.appendChild(img);
    window.__imgLoads.push(new Promise((r) => { const p = new Image(); p.onload = p.onerror = r; p.src = url; }));
  } else if (it.image) {
    const img = document.createElement('div');
    img.style.cssText = `left:0;top:0;width:100%;height:100%;border-radius:inherit;background:repeating-linear-gradient(45deg, ${css(it.image.color, 0.55)} 0 6px, ${css(it.image.color, 0.35)} 6px 12px);outline:1px dashed ${css(it.image.color, 0.8)};outline-offset:-1px;`;
    el.appendChild(img);
  }
  if (it.viewport && viewportImages[it.viewport]) {
    const v = viewportImages[it.viewport];
    const img = document.createElement('img');
    img.src = v.url;
    img.style.cssText = `position:absolute;left:0;top:0;width:${it.w}px;height:${it.h}px;opacity:${v.alpha}`;
    el.appendChild(img);
  }
  if (it.scrollbars) {
    for (const b of it.scrollbars.bars) {
      const bar = document.createElement('div');
      bar.style.cssText = `left:${b.x}px;top:${b.y}px;width:${b.w}px;height:${b.h}px;background:${css(it.scrollbars.color)};border-radius:${Math.min(b.w, b.h) / 2}px;`;
      el.appendChild(bar);
    }
  }
  if (it.text) paintText(el, it.text);
  host.appendChild(el);
}

function paintText(el, t) {
  const box = document.createElement('div');
  box.style.cssText = `left:${t.x}px;top:${t.y}px;width:${t.w}px;height:${t.h}px;overflow:visible;`;
  for (const line of t.lines) {
    for (const s of line.segs) {
      const span = document.createElement('div');
      span.className = 'seg';
      span.textContent = s.t;
      span.style.left = s.x + 'px';
      span.style.top = line.y + 'px';
      span.style.height = line.h + 'px';
      span.style.lineHeight = line.h + 'px';
      span.style.fontFamily = `"${s.font}"`;
      span.style.fontWeight = String(s.weight);
      span.style.fontStyle = s.synth ? 'italic' : s.style;
      if (s.synth) span.style.fontSynthesis = 'style';
      span.style.fontSize = s.size + 'px';
      span.style.color = css(s.color);
      // glyphs sit on the line box like Roblox: vertically centred on the line height
      const deco = [];
      if (s.u) deco.push('underline');
      if (s.s) deco.push('line-through');
      if (deco.length) span.style.textDecoration = deco.join(' ');
      if (s.mark) span.style.background = css(s.mark);
      const stroke = s.stroke || t.stroke || t.legacyStroke;
      if (stroke && stroke.thickness > 0 && stroke.color[3] > 0) {
        span.style.webkitTextStroke = `${stroke.thickness * 2}px ${css(stroke.color)}`;
        span.style.paintOrder = 'stroke fill';
        span.style.strokeLinejoin = 'round';
      }
      if (t.gradient) {
        span.style.background = gradientCss(t.gradient, s.color);
        span.style.backgroundSize = `${t.w}px ${t.h}px`;
        span.style.backgroundPosition = `${-s.x}px ${-line.y}px`;
        span.style.webkitBackgroundClip = 'text';
        span.style.backgroundClip = 'text';
        span.style.color = 'transparent';
      }
      box.appendChild(span);
    }
  }
  el.appendChild(box);
}

function paintItems(container, items, viewportImages) {
  for (const it of items) {
    if (it.t === 'group') {
      const g = document.createElement('div');
      g.style.cssText = `left:0;top:0;width:100%;height:100%;opacity:${it.alpha};`;
      container.appendChild(g);
      paintItems(g, it.items, viewportImages);
    } else {
      paintItem(container, it, viewportImages);
    }
  }
}

// Ghost of Roblox's own top-bar buttons (menu, chat) so layouts can be checked against them.
function paintCoreUi(root, gui, device) {
  const top = gui.topbar.y;
  const left = (gui.safe.left || 0) + 16;
  const size = 44;
  const y = top + (gui.topbar.h - size) / 2;
  const buttons = ['menu'];
  if (!gui.coreGui || gui.coreGui.Chat !== false) buttons.push('chat');
  buttons.forEach((b, i) => {
    const el = document.createElement('div');
    el.style.cssText = `left:${left + i * (size + 12)}px;top:${y}px;width:${size}px;height:${size}px;border-radius:12px;background:rgba(18,21,27,0.55);box-shadow:0 0 0 1px rgba(255,255,255,0.15);`;
    const glyph = document.createElement('div');
    glyph.style.cssText = 'left:0;top:0;width:100%;height:100%;display:flex;align-items:center;justify-content:center;color:rgba(255,255,255,0.85);font:600 18px "Source Sans 3";';
    glyph.textContent = b === 'menu' ? '☰' : '✉';
    el.appendChild(glyph);
    root.appendChild(el);
  });
}

export function paintGui(root, gui, device, viewportImages, opts = {}) {
  root.innerHTML = '';
  for (const layer of gui.layers) {
    const layerEl = document.createElement('div');
    layerEl.style.cssText = 'left:0;top:0;width:100%;height:100%;';
    layerEl.dataset.layer = layer.name;
    root.appendChild(layerEl);
    paintItems(layerEl, layer.items, viewportImages);
  }
  if (!opts.hideCoreUi) paintCoreUi(root, gui, device);
}

export function paintOverlays(root, overlays, project) {
  if (!overlays || !overlays.length) return;
  const svg = document.createElementNS(SVGNS, 'svg');
  svg.setAttribute('width', String(window.innerWidth));
  svg.setAttribute('height', String(window.innerHeight));
  svg.style.cssText = 'position:absolute;left:0;top:0;';
  for (const o of overlays) {
    const y = o.y || 0;
    let pts;
    if (o.kind === 'circle') {
      pts = [];
      for (let i = 0; i < 48; i++) {
        const a = (i / 48) * Math.PI * 2;
        pts.push(project(o.x + Math.cos(a) * o.r, y, o.z + Math.sin(a) * o.r));
      }
    } else if (o.kind === 'box') {
      pts = [project(o.minX, y, o.minZ), project(o.maxX, y, o.minZ), project(o.maxX, y, o.maxZ), project(o.minX, y, o.maxZ)];
    } else if (o.kind === 'label') {
      const p = project(o.x, y, o.z);
      const t = document.createElementNS(SVGNS, 'text');
      t.setAttribute('x', String(p[0])); t.setAttribute('y', String(p[1]));
      t.setAttribute('fill', o.color || '#fff');
      t.style.fontFamily = '"Source Sans 3"'; t.setAttribute('font-size', String(o.size || 16)); t.setAttribute('font-weight', '700');
      t.setAttribute('text-anchor', 'middle');
      t.textContent = o.text;
      svg.appendChild(t);
      continue;
    } else continue;
    const poly = document.createElementNS(SVGNS, 'polygon');
    poly.setAttribute('points', pts.map((p) => p.join(',')).join(' '));
    poly.setAttribute('fill', o.fill || 'none');
    poly.setAttribute('stroke', o.color || 'red');
    poly.setAttribute('stroke-width', String(o.width || 1.5));
    if (o.dash) poly.setAttribute('stroke-dasharray', o.dash);
    svg.appendChild(poly);
  }
  root.appendChild(svg);
}
