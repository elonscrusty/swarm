// main.js - preview page entry: renders /job.json (mode=render) or checks the mesh catalog
// (mode=check). Sets window.__done when the picture is final, window.__report for notes.
import * as THREE from 'three';
import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/addons/postprocessing/RenderPass.js';
import { UnrealBloomPass } from 'three/addons/postprocessing/UnrealBloomPass.js';
import { ShaderPass } from 'three/addons/postprocessing/ShaderPass.js';
import { OutputPass } from 'three/addons/postprocessing/OutputPass.js';
import { checkCatalog } from './meshes.js';
import { addParts, addLights, addSunAndAmbient, fitShadow, skyMesh, addSprites, addBeams, addHighlights, cframeMatrix, srgb, worldWarnings } from './world.js';
import { paintGui, paintOverlays, usedFonts } from './gui.js';

const mode = new URLSearchParams(location.search).get('mode');

// Roblox ColorCorrectionEffect, applied to display (sRGB) colours.
const ColorCorrectionShader = {
  uniforms: { tDiffuse: { value: null }, brightness: { value: 0 }, contrast: { value: 0 }, saturation: { value: 0 }, tint: { value: new THREE.Vector3(1, 1, 1) } },
  vertexShader: 'varying vec2 vUv; void main(){ vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }',
  fragmentShader: `uniform sampler2D tDiffuse; uniform float brightness; uniform float contrast; uniform float saturation; uniform vec3 tint; varying vec2 vUv;
    void main(){ vec4 c = texture2D(tDiffuse, vUv); vec3 col = c.rgb * tint; col += brightness;
      col = (col - 0.5) * (1.0 + contrast) + 0.5; float l = dot(col, vec3(0.2126, 0.7152, 0.0722));
      col = mix(vec3(l), col, 1.0 + saturation); gl_FragColor = vec4(clamp(col, 0.0, 1.0), c.a); }`,
};

function makeCamera(camData, w, h) {
  const m = cframeMatrix(camData.cf);
  let cam;
  if (camData.ortho) {
    const hh = camData.ortho.height / 2;
    const hw = hh * (w / h);
    cam = new THREE.OrthographicCamera(-hw, hw, hh, -hh, camData.near || 0.5, camData.far || 4000);
  } else {
    cam = new THREE.PerspectiveCamera(camData.fov, w / h, camData.near || 0.3, camData.far || 6000);
  }
  m.decompose(cam.position, cam.quaternion, cam.scale);
  cam.scale.set(1, 1, 1);
  cam.updateMatrixWorld(true);
  return cam;
}

// Where the camera looks at the ground (shadow / light focus).
function focusPoint(cam) {
  const dir = new THREE.Vector3();
  cam.getWorldDirection(dir);
  if (dir.y < -0.05) {
    const t = (0 - cam.position.y) / dir.y;
    if (t > 0 && t < 2000) return { point: cam.position.clone().addScaledVector(dir, t), dist: t };
  }
  return { point: cam.position.clone().addScaledVector(dir, 40), dist: 40 };
}

async function loadFonts(families) {
  const meta = await (await fetch('/fonts/metrics.json')).json();
  const loads = [];
  const declared = new Set();
  const add = (family, weight, style) => {
    const file = (meta.families[family] || {})[`${weight}-${style}`];
    if (!file || declared.has(file)) return;
    declared.add(file);
    const face = new FontFace(family, `url(/fonts/${file})`, { weight: String(weight), style });
    document.fonts.add(face);
    loads.push(face.load().catch((e) => console.warn('font', file, e.message)));
  };
  for (const key of families) {
    const [family, weight, style] = key.split('|');
    add(family, weight, style);
  }
  add('Source Sans 3', 600, 'normal'); // core-ui ghost and overlay labels
  add('Source Sans 3', 700, 'normal');
  await Promise.all(loads);
  await document.fonts.ready;
}

async function renderViewports(viewports, dpr) {
  const out = {};
  if (!viewports || !viewports.length) return out;
  const canvas = document.createElement('canvas');
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true, preserveDrawingBuffer: true });
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.toneMapping = THREE.NeutralToneMapping;
  renderer.setPixelRatio(dpr);
  for (const vp of viewports) {
    const [, , w, h] = vp.rect;
    if (w < 1 || h < 1 || !vp.camera || !vp.parts.length) continue;
    renderer.setSize(Math.round(w), Math.round(h), false);
    renderer.setClearColor(0x000000, 0);
    const scene = new THREE.Scene();
    await addParts(scene, vp.parts, { quiet: true });
    // ViewportFrame lighting: Ambient + one directional LightColor / LightDirection
    scene.add(new THREE.AmbientLight(srgb(vp.ambient), 1.4));
    const light = new THREE.DirectionalLight(srgb(vp.lightColor), 2.0);
    light.position.set(-vp.lightDir[0], -vp.lightDir[1], -vp.lightDir[2]).normalize().multiplyScalar(100);
    scene.add(light);
    const cam = makeCamera(vp.camera, w, h);
    renderer.render(scene, cam);
    out[vp.id] = { url: canvas.toDataURL('image/png'), alpha: vp.alpha };
  }
  renderer.dispose();
  return out;
}

// Luau's JSON encoder writes empty tables as {}; the renderer wants [] for lists.
function emptyToArrays(v) {
  if (Array.isArray(v)) return v.map(emptyToArrays);
  if (v && typeof v === 'object') {
    const keys = Object.keys(v);
    if (keys.length === 0) return [];
    for (const k of keys) v[k] = emptyToArrays(v[k]);
  }
  return v;
}

async function render() {
  const job = emptyToArrays(await (await fetch('/job.json')).json());
  const d = job.device;
  const W = d.width, H = d.height, dpr = d.dpr || 1;

  const fontsReady = loadFonts(usedFonts(job.gui.layers));

  const canvas = document.getElementById('stage');
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, preserveDrawingBuffer: true });
  renderer.setPixelRatio(dpr);
  renderer.setSize(W, H);
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.toneMapping = THREE.NeutralToneMapping;
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = THREE.PCFSoftShadowMap;

  const scene = new THREE.Scene();
  const cam = makeCamera(job.camera, W, H);
  const L = job.lighting;
  const { mesh: sky, horizon } = skyMesh(L);
  if (job.render && job.render.background) scene.background = srgb(job.render.background);
  else scene.add(sky);

  const world = new THREE.Group();
  scene.add(world);
  await addParts(world, job.world.parts);
  addHighlights(world, job.world.highlights);
  const focus = focusPoint(cam);
  if (L) {
    const { sun, sunDir } = addSunAndAmbient(scene, L);
    if (L.globalShadows !== false && sunDir.y > 0.02) {
      const ortho = job.camera.ortho;
      const radius = ortho ? ortho.height * 0.75 : THREE.MathUtils.clamp(focus.dist * 1.1, 40, 320);
      fitShadow(sun, sunDir, ortho ? new THREE.Vector3(cam.position.x, 0, cam.position.z) : focus.point, radius, L.shadowSoftness);
    }
    const atmo = L.effects && L.effects.atmosphere;
    if (atmo && !job.camera.ortho) {
      scene.fog = new THREE.FogExp2(horizon.clone(), 0.0072 * atmo.density * (0.6 + atmo.haze * 0.25));
    }
  }
  addLights(scene, job.world.lights, focus.point);
  addSprites(scene, job.world.sprites);
  addBeams(scene, job.world.beams, cam);

  // post: bloom (restrained), colour correction
  const target = new THREE.WebGLRenderTarget(W * dpr, H * dpr, { type: THREE.HalfFloatType, samples: 4 });
  const composer = new EffectComposer(renderer, target);
  composer.setPixelRatio(dpr);
  composer.setSize(W, H);
  composer.addPass(new RenderPass(scene, cam));
  const fx = (L && L.effects) || {};
  if (fx.bloom && fx.bloom.intensity > 0) {
    const b = fx.bloom;
    composer.addPass(new UnrealBloomPass(new THREE.Vector2(W, H), Math.min(b.intensity, 1.5) * 0.45, Math.min(b.size / 56, 1) * 0.5, Math.max(0.85, b.threshold * 0.8)));
  }
  composer.addPass(new OutputPass());
  for (const cc of fx.colorCorrection || []) {
    const pass = new ShaderPass(ColorCorrectionShader);
    pass.uniforms.brightness.value = cc.brightness;
    pass.uniforms.contrast.value = cc.contrast;
    pass.uniforms.saturation.value = cc.saturation;
    pass.uniforms.tint.value.set(cc.tint[0], cc.tint[1], cc.tint[2]);
    composer.addPass(pass);
  }
  composer.render();

  const viewportImages = await renderViewports(job.gui.viewports, dpr);
  await fontsReady;
  const gui = document.getElementById('gui');
  paintGui(gui, job.gui, d, viewportImages, { hideCoreUi: job.render && job.render.hideCoreUi });
  paintOverlays(gui, job.overlays, (x, y, z) => {
    const v = new THREE.Vector3(x, y, z).project(cam);
    return [((v.x + 1) / 2) * W, ((1 - v.y) / 2) * H];
  });
  await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  window.__report = { warnings: [...new Set(worldWarnings())] };
  window.__done = true;
}

if (mode === 'check') {
  window.__report = await checkCatalog();
  window.__done = true;
} else {
  try {
    await render();
  } catch (e) {
    console.error('render failed: ' + ((e && e.stack) || e));
    window.__report = { warnings: ['render failed: ' + e.message] };
    window.__done = true;
  }
}
