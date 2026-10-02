// world.js - builds a three.js scene from the exported Roblox world.
//
// Approximations (docs/PREVIEW.md): materials are flat colours (SmoothPlastic / Plastic
// roughness 0.65, Metal metalness 0.6 roughness 0.4, Neon emissive, Glass transparent,
// every other material roughness 0.9 with no texture); sun from Lighting.ClockTime and
// GeographicLatitude; hemisphere ambient from OutdoorAmbient / Ambient; PCF soft shadow
// map for CastShadow parts; Atmosphere → exponential fog + gradient sky.
import * as THREE from 'three';
import { pieceGeometry } from './meshes.js';

const warnings = [];
export function worldWarnings() { return warnings; }

export function srgb(c) {
  return new THREE.Color().setRGB(c[0], c[1], c[2], THREE.SRGBColorSpace);
}

export function cframeMatrix(cf) {
  const [x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22] = cf;
  const m = new THREE.Matrix4();
  m.set(r00, r01, r02, x, r10, r11, r12, y, r20, r21, r22, z, 0, 0, 0, 1);
  return m;
}

// --- geometries -------------------------------------------------------------------------

const unitBox = new THREE.BoxGeometry(1, 1, 1);
const unitSphere = new THREE.SphereGeometry(0.5, 32, 20);
const unitCylinderX = (() => { const g = new THREE.CylinderGeometry(0.5, 0.5, 1, 32); g.rotateZ(Math.PI / 2); return g; })();
const unitCylinderY = new THREE.CylinderGeometry(0.5, 0.5, 1, 32);

function polyGeometry(verts, faces) {
  const pos = [];
  for (const f of faces) for (let i = 1; i < f.length - 1; i++) for (const k of [f[0], f[i], f[i + 1]]) pos.push(...verts[k]);
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
  g.computeVertexNormals();
  return g;
}

// WedgePart: full bottom and back (+Z) faces, slope rising from the front-bottom edge.
const unitWedge = polyGeometry(
  [[-0.5, -0.5, -0.5], [0.5, -0.5, -0.5], [0.5, -0.5, 0.5], [-0.5, -0.5, 0.5], [-0.5, 0.5, 0.5], [0.5, 0.5, 0.5]],
  [[0, 1, 2, 3], [3, 2, 5, 4], [0, 4, 5, 1], [0, 3, 4], [1, 5, 2]].map((f) => f.slice().reverse()),
);
// CornerWedgePart: peak above the (+X, -Z) corner (approximation).
const unitCorner = polyGeometry(
  [[-0.5, -0.5, -0.5], [0.5, -0.5, -0.5], [0.5, -0.5, 0.5], [-0.5, -0.5, 0.5], [0.5, 0.5, -0.5]],
  [[0, 1, 2, 3].reverse(), [0, 4, 1].reverse(), [1, 4, 2].reverse(), [2, 4, 3].reverse(), [3, 4, 0].reverse()],
);
const unitTorso = polyGeometry(
  [[-0.5, -0.5, -0.4], [0.5, -0.5, -0.4], [0.5, -0.5, 0.4], [-0.5, -0.5, 0.4], [-0.5, 0.5, -0.5], [0.5, 0.5, -0.5], [0.5, 0.5, 0.5], [-0.5, 0.5, 0.5]],
  [[0, 1, 2, 3].reverse(), [4, 5, 6, 7], [0, 4, 5, 1].reverse(), [1, 5, 6, 2].reverse(), [2, 6, 7, 3].reverse(), [3, 7, 4, 0].reverse()],
);

function shapeGeometry(p) {
  switch (p.shape) {
    case 'Ball': return { geo: unitSphere, key: 'ball', uniform: 'min' };
    case 'Cylinder': return { geo: unitCylinderX, key: 'cylx', uniform: 'yz' };
    case 'Wedge': return { geo: unitWedge, key: 'wedge' };
    case 'CornerWedge': return { geo: unitCorner, key: 'corner' };
    case 'Special':
      switch (p.special) {
        case 'Sphere': return { geo: unitSphere, key: 'ball', special: true };
        case 'Cylinder': return { geo: unitCylinderX, key: 'cylx', special: true };
        case 'Head': return { geo: unitCylinderY, key: 'cyly', special: true };
        case 'Wedge': return { geo: unitWedge, key: 'wedge', special: true };
        case 'Torso': return { geo: unitTorso, key: 'torso', special: true };
        default: return { geo: unitBox, key: 'box', special: true };
      }
    default: return { geo: unitBox, key: 'box' };
  }
}

// Final local scale for a part (Roblox: Ball uses the smallest axis, cylinders the
// smaller of Y/Z for the diameter; SpecialMesh multiplies by Scale).
function partScale(p, info) {
  const [sx, sy, sz] = p.size;
  if (info.uniform === 'min') { const m = Math.min(sx, sy, sz); return [m, m, m]; }
  if (info.uniform === 'yz') { const d = Math.min(sy, sz); return [sx, d, d]; }
  if (info.special) {
    const s = p.meshScale || [1, 1, 1];
    return [sx * s[0], sy * s[1], sz * s[2]];
  }
  return [sx, sy, sz];
}

// --- materials ----------------------------------------------------------------------------

function materialFor(kind, transparency, opts = {}) {
  const transparent = transparency > 0.001;
  const opacity = 1 - transparency;
  const common = { transparent, opacity, depthWrite: !transparent || opacity > 0.85, side: opts.doubleSide ? THREE.DoubleSide : THREE.FrontSide, flatShading: !!opts.flat };
  if (opts.vertexColors) common.vertexColors = false;
  switch (kind) {
    case 'Neon': return new THREE.MeshStandardMaterial({ ...common, color: 0xffffff, emissive: 0xffffff, emissiveIntensity: 1.5, roughness: 1, metalness: 0 });
    case 'Metal': case 'DiamondPlate': case 'CorrodedMetal': case 'Foil':
      return new THREE.MeshStandardMaterial({ ...common, roughness: 0.4, metalness: 0.6 });
    case 'Glass': case 'ForceField':
      return new THREE.MeshStandardMaterial({ ...common, transparent: true, opacity: Math.min(opacity, 0.85), depthWrite: false, roughness: 0.1, metalness: 0.1 });
    case 'SmoothPlastic': case 'Plastic':
      return new THREE.MeshStandardMaterial({ ...common, roughness: 0.65, metalness: 0 });
    default:
      return new THREE.MeshStandardMaterial({ ...common, roughness: 0.9, metalness: 0 });
  }
}

const TEXTURED = new Set(['Grass', 'Slate', 'Cobblestone', 'Wood', 'WoodPlanks', 'Brick', 'Concrete', 'Fabric', 'Granite', 'Marble', 'Pebble', 'Sand', 'Ground', 'Rock', 'Asphalt', 'Basalt', 'Mud', 'Salt', 'Sandstone', 'Snow', 'Ice', 'LeafyGrass', 'Limestone', 'Pavement', 'CrackedLava', 'Cardboard', 'Carpet', 'CeramicTiles', 'ClayRoofTiles', 'RoofShingles', 'Leather', 'Plaster', 'Rubber']);

// --- parts ----------------------------------------------------------------------------------

// Adds parts to `group`; opaque parts are instanced by (geometry, material, shadow).
export async function addParts(group, parts, opts = {}) {
  const batches = new Map();
  const meshRefs = new Map();
  let tris = 0;
  const usedTextured = new Set();
  for (const p of parts) if (p.shape === 'Mesh' && p.mesh && p.mesh.ref) meshRefs.set(p.mesh.ref, null);
  await Promise.all([...meshRefs.keys()].map(async (ref) => meshRefs.set(ref, await pieceGeometry(ref))));
  const tmpM = new THREE.Matrix4();
  for (const p of parts) {
    let geo, key, scale;
    let flat = false;
    if (p.shape === 'Mesh') {
      const piece = p.mesh && p.mesh.ref ? meshRefs.get(p.mesh.ref) : null;
      if (piece) { geo = piece.geometry; key = 'mesh:' + p.mesh.ref; scale = p.size; flat = true; }
      else { geo = unitBox; key = 'box'; scale = p.size; if (p.mesh && p.mesh.ref) warnings.push('missing FBX piece ' + p.mesh.ref + ' (box)'); }
    } else {
      const info = shapeGeometry(p);
      geo = info.geo; key = info.key; scale = partScale(p, info);
    }
    if (TEXTURED.has(p.material)) usedTextured.add(p.material);
    const m = cframeMatrix(p.cf);
    if (p.shape === 'Special' && p.meshOffset) m.multiply(tmpM.makeTranslation(p.meshOffset[0], p.meshOffset[1], p.meshOffset[2]));
    m.multiply(tmpM.makeScale(Math.max(scale[0], 1e-3), Math.max(scale[1], 1e-3), Math.max(scale[2], 1e-3)));
    tris += (geo.index ? geo.index.count : geo.attributes.position.count) / 3;
    const color = srgb(p.color);
    const transparent = p.transparency > 0.001 || p.material === 'Glass';
    if (transparent) {
      const mat = materialFor(p.material, p.transparency, { flat, doubleSide: p.transparency > 0.3 });
      mat.color = color.clone();
      if (p.material === 'Neon') mat.emissive = color.clone();
      const mesh = new THREE.Mesh(geo, mat);
      mesh.matrixAutoUpdate = false;
      mesh.matrix.copy(m);
      mesh.castShadow = false;
      mesh.receiveShadow = true;
      mesh.renderOrder = 1;
      mesh.userData.partId = p.id;
      group.add(mesh);
      continue;
    }
    const bkey = key + '|' + p.material + '|' + (p.shadow ? 1 : 0) + '|' + (flat ? 1 : 0);
    let b = batches.get(bkey);
    if (!b) { b = { geo, material: p.material, shadow: p.shadow, flat, items: [] }; batches.set(bkey, b); }
    b.items.push({ m, color, id: p.id });
  }
  for (const b of batches.values()) {
    const mat = materialFor(b.material, 0, { flat: b.flat });
    if (b.material === 'Neon') { mat.emissive = new THREE.Color(1, 1, 1); mat.color = new THREE.Color(0, 0, 0); }
    const mesh = new THREE.InstancedMesh(b.geo, mat, b.items.length);
    b.items.forEach((it, i) => {
      mesh.setMatrixAt(i, it.m);
      mesh.setColorAt(i, it.color);
    });
    if (b.material === 'Neon') {
      // neon glows in its own colour: emissive = instance colour (shader patch)
      mat.onBeforeCompile = (shader) => {
        shader.fragmentShader = shader.fragmentShader.replace('vec3 totalEmissiveRadiance = emissive;', 'vec3 totalEmissiveRadiance = emissive * vColor.rgb * 1.6;');
      };
    }
    mesh.instanceMatrix.needsUpdate = true;
    if (mesh.instanceColor) mesh.instanceColor.needsUpdate = true;
    mesh.castShadow = !!b.shadow;
    mesh.receiveShadow = true;
    mesh.userData.partIds = b.items.map((it) => it.id);
    mesh.computeBoundingSphere();
    group.add(mesh);
  }
  if (usedTextured.size && !opts.quiet) warnings.push('textured materials drawn as plain colour: ' + [...usedTextured].sort().join(', '));
  return { tris };
}

// --- lights, sky, fog ------------------------------------------------------------------------

export function addLights(scene, lights, focus, maxLights = 32) {
  const sorted = lights.slice().sort((a, b) => dist(a.pos, focus) - dist(b.pos, focus)).slice(0, maxLights);
  if (lights.length > maxLights) warnings.push(`${lights.length} lights; the ${maxLights} nearest the view are drawn`);
  for (const l of sorted) {
    const color = srgb(l.color);
    const intensity = l.brightness * 8;
    let light;
    if (l.type === 'point') {
      light = new THREE.PointLight(color, intensity, l.range, 1.2);
    } else {
      light = new THREE.SpotLight(color, intensity, l.range, THREE.MathUtils.degToRad(Math.min(l.angle || 90, 170) / 2), 0.5, 1.2);
      light.target.position.set(l.pos[0] + l.dir[0], l.pos[1] + l.dir[1], l.pos[2] + l.dir[2]);
      scene.add(light.target);
    }
    light.position.set(l.pos[0], l.pos[1], l.pos[2]);
    scene.add(light);
  }
}

function dist(p, f) { return Math.hypot(p[0] - f.x, p[1] - f.y, p[2] - f.z); }

export function skyMesh(lighting) {
  const atmo = lighting && lighting.effects && lighting.effects.atmosphere;
  const zenithBase = new THREE.Color().setRGB(0.36, 0.56, 0.86, THREE.SRGBColorSpace);
  let horizon = new THREE.Color().setRGB(0.72, 0.82, 0.93, THREE.SRGBColorSpace);
  let zenith = zenithBase.clone();
  if (atmo) {
    horizon = srgb(atmo.color);
    zenith = zenithBase.clone().lerp(srgb(atmo.decay), 0.35);
  }
  // darker at night / dusk
  const sunY = lighting ? lighting.sun[1] : 0.7;
  const day = THREE.MathUtils.clamp(sunY * 2.5 + 0.35, 0.15, 1);
  zenith.multiplyScalar(day);
  horizon.multiplyScalar(0.55 + 0.45 * day);
  const mat = new THREE.ShaderMaterial({
    side: THREE.BackSide, depthWrite: false, fog: false,
    uniforms: { zenith: { value: zenith }, horizon: { value: horizon } },
    vertexShader: 'varying vec3 vDir; void main(){ vDir = normalize(position); vec4 p = projectionMatrix * modelViewMatrix * vec4(position,1.0); gl_Position = p.xyww; }',
    fragmentShader: 'uniform vec3 zenith; uniform vec3 horizon; varying vec3 vDir; void main(){ float t = clamp(vDir.y * 1.6, 0.0, 1.0); vec3 c = mix(horizon, zenith, pow(t, 0.7)); if (vDir.y < 0.0) c = horizon * 0.85; gl_FragColor = vec4(c, 1.0); }',
  });
  const mesh = new THREE.Mesh(new THREE.SphereGeometry(5000, 32, 16), mat);
  mesh.frustumCulled = false;
  mesh.renderOrder = -10;
  return { mesh, horizon };
}

// Sun + ambient. Returns the directional light (shadows fitted later).
export function addSunAndAmbient(scene, lighting) {
  const L = lighting;
  const sunDir = new THREE.Vector3(L.sun[0], L.sun[1], L.sun[2]).normalize();
  const shift = L.colorShiftTop;
  let sunColor = (shift[0] + shift[1] + shift[2]) > 0.02 ? srgb(shift) : new THREE.Color(1, 0.97, 0.92);
  // low sun gets warmer and weaker, below the horizon it is off
  const elev = sunDir.y;
  const sunFactor = THREE.MathUtils.clamp(elev * 4, 0, 1);
  const sun = new THREE.DirectionalLight(sunColor, L.brightness * 1.05 * sunFactor);
  sun.position.copy(sunDir).multiplyScalar(500);
  scene.add(sun);
  scene.add(sun.target);
  const sky = srgb(L.outdoorAmbient);
  const ground = srgb(L.ambient);
  const hemi = new THREE.HemisphereLight(sky, ground, 1.25 + (L.envDiffuse || 0) * 0.4);
  scene.add(hemi);
  scene.add(new THREE.AmbientLight(ground, 0.35));
  return { sun, sunDir };
}

export function fitShadow(sun, sunDir, center, radius, softness) {
  sun.castShadow = true;
  sun.target.position.copy(center);
  sun.position.copy(center).addScaledVector(sunDir, radius * 3 + 200);
  const cam = sun.shadow.camera;
  cam.left = -radius; cam.right = radius; cam.top = radius; cam.bottom = -radius;
  cam.near = 1; cam.far = radius * 6 + 600;
  cam.updateProjectionMatrix();
  sun.shadow.mapSize.set(4096, 4096);
  sun.shadow.bias = -0.0004;
  sun.shadow.normalBias = 0.04;
  sun.shadow.radius = 1 + (softness || 0) * 6;
}

// --- sprites, beams, highlights --------------------------------------------------------------

let glowTex = null;
function glowTexture() {
  if (glowTex) return glowTex;
  const c = document.createElement('canvas');
  c.width = c.height = 64;
  const g = c.getContext('2d');
  const grad = g.createRadialGradient(32, 32, 0, 32, 32, 32);
  grad.addColorStop(0, 'rgba(255,255,255,1)');
  grad.addColorStop(0.4, 'rgba(255,255,255,0.6)');
  grad.addColorStop(1, 'rgba(255,255,255,0)');
  g.fillStyle = grad;
  g.fillRect(0, 0, 64, 64);
  glowTex = new THREE.CanvasTexture(c);
  glowTex.colorSpace = THREE.SRGBColorSpace;
  return glowTex;
}

export function addSprites(scene, sprites) {
  for (const s of sprites) {
    const mat = new THREE.SpriteMaterial({ map: glowTexture(), color: srgb(s.color), transparent: true, opacity: s.alpha, depthWrite: false, blending: s.additive ? THREE.AdditiveBlending : THREE.NormalBlending });
    const sp = new THREE.Sprite(mat);
    sp.position.set(s.pos[0], s.pos[1], s.pos[2]);
    sp.scale.setScalar(s.size * (s.kind === 'fire' ? 1.4 : 1.6));
    scene.add(sp);
  }
}

export function addBeams(scene, beams, camera) {
  for (const b of beams) {
    const p0 = new THREE.Vector3(...b.p0), p1 = new THREE.Vector3(...b.p1);
    const dir = p1.clone().sub(p0);
    const view = camera.position.clone().sub(p0.clone().add(p1).multiplyScalar(0.5));
    const side = dir.clone().cross(view).normalize();
    const v = [p0.clone().addScaledVector(side, b.w0 / 2), p0.clone().addScaledVector(side, -b.w0 / 2), p1.clone().addScaledVector(side, -b.w1 / 2), p1.clone().addScaledVector(side, b.w1 / 2)];
    const g = new THREE.BufferGeometry().setFromPoints([v[0], v[1], v[2], v[0], v[2], v[3]]);
    const mat = new THREE.MeshBasicMaterial({ color: srgb(b.color), transparent: true, opacity: b.alpha, side: THREE.DoubleSide, depthWrite: false, blending: b.additive ? THREE.AdditiveBlending : THREE.NormalBlending });
    scene.add(new THREE.Mesh(g, mat));
  }
}

// Highlight: fill tint + an inverted-hull outline, per highlighted part.
export function addHighlights(group, highlights) {
  if (!highlights || !highlights.length) return;
  const byId = new Map();
  group.traverse((o) => {
    if (o.isInstancedMesh && o.userData.partIds) o.userData.partIds.forEach((id, i) => byId.set(id, { mesh: o, index: i }));
    else if (o.isMesh && o.userData.partId) byId.set(o.userData.partId, { mesh: o });
  });
  const m = new THREE.Matrix4();
  for (const h of highlights) {
    const fill = new THREE.MeshBasicMaterial({ color: srgb(h.fill), transparent: true, opacity: h.fillAlpha, depthWrite: false, depthTest: !h.alwaysOnTop });
    const outline = new THREE.MeshBasicMaterial({ color: srgb(h.outline), transparent: true, opacity: h.outlineAlpha, side: THREE.BackSide, depthWrite: false });
    for (const id of h.parts) {
      const e = byId.get(id);
      if (!e) continue;
      if (e.index !== undefined) e.mesh.getMatrixAt(e.index, m); else m.copy(e.mesh.matrix);
      const geo = e.mesh.geometry;
      const f = new THREE.Mesh(geo, fill); f.matrixAutoUpdate = false; f.matrix.copy(m); f.renderOrder = 5; group.add(f);
      const o = new THREE.Mesh(geo, outline); o.matrixAutoUpdate = false; o.matrix.copy(m).multiply(new THREE.Matrix4().makeScale(1.06, 1.06, 1.06)); o.renderOrder = 4; group.add(o);
    }
  }
}
