// meshes.js - catalog pieces from the Blender FBX exports.
//
// A MeshPart's PreviewMeshRef "World/Tree_Round.fbx#Leaves" names one mesh object in
// meshes/World/Tree_Round.fbx. Like Roblox, the piece geometry is centred on its bounding
// box and stretched so the box matches the part's Size (here: a unit box, scaled later).
// The FBX node transforms (Blender's Y-up export axes) are applied first, so the result is
// in Roblox model axes: x right, y up, front = -Z.
import * as THREE from 'three';
import { FBXLoader } from 'three/addons/loaders/FBXLoader.js';

const loader = new FBXLoader();
const files = new Map(); // file -> Promise<Map<pieceName, {geometry, center, size}>>

function cleanName(name) {
  return String(name || '').replace(/^Model::/, '').replace(/\.\d+$/, '');
}

export function loadFile(file) {
  if (!files.has(file)) {
    files.set(file, new Promise((resolve) => {
      loader.load('/meshes/' + file, (root) => {
        root.updateMatrixWorld(true);
        const pieces = new Map();
        root.traverse((o) => {
          if (!o.isMesh) return;
          const name = cleanName(o.name);
          if (pieces.has(name)) return;
          const g = o.geometry.clone();
          g.applyMatrix4(o.matrixWorld);
          g.computeBoundingBox();
          const box = g.boundingBox;
          const center = new THREE.Vector3();
          const size = new THREE.Vector3();
          box.getCenter(center);
          box.getSize(size);
          // unit geometry: centred, each axis scaled to 1 (Roblox stretches meshes to Size)
          g.translate(-center.x, -center.y, -center.z);
          g.scale(size.x > 1e-6 ? 1 / size.x : 1, size.y > 1e-6 ? 1 / size.y : 1, size.z > 1e-6 ? 1 / size.z : 1);
          g.deleteAttribute('color');
          g.deleteAttribute('uv');
          g.deleteAttribute('uv2');
          const flat = g.index ? g.toNonIndexed() : g;
          flat.computeVertexNormals();
          const tris = flat.attributes.position.count / 3;
          pieces.set(name, { geometry: flat, center, size, tris });
        });
        resolve(pieces);
      }, undefined, (err) => {
        console.warn('FBX load failed', file, err && err.message);
        resolve(new Map());
      });
    }));
  }
  return files.get(file);
}

// Resolves a "Category/Model.fbx#Piece" ref to its unit geometry (or null).
export async function pieceGeometry(ref) {
  const [file, piece] = ref.split('#');
  const pieces = await loadFile(file);
  return pieces.get(piece) || null;
}

// Orientation check: every catalog piece's FBX centre must equal its catalog Offset.
export async function checkCatalog() {
  const res = await fetch('/meshes/catalog.json');
  const catalog = await res.json();
  const lines = [];
  let mismatches = 0, checked = 0;
  for (const model of catalog) {
    const pieces = await loadFile(`${model.category}/${model.name}.fbx`);
    for (const p of model.pieces) {
      const got = pieces.get(p.name);
      checked++;
      if (!got) { mismatches++; lines.push(`MISSING  ${model.name}.${p.name}: not in ${model.category}/${model.name}.fbx`); continue; }
      const dc = Math.hypot(got.center.x - p.offset[0], got.center.y - p.offset[1], got.center.z - p.offset[2]);
      const ds = Math.hypot(got.size.x - p.size[0], got.size.y - p.size[1], got.size.z - p.size[2]);
      if (dc > 0.02 || ds > 0.02) {
        mismatches++;
        const f = (v) => v.map((x) => x.toFixed(3)).join(', ');
        lines.push(`MISMATCH ${model.name}.${p.name}: fbx centre (${f([got.center.x, got.center.y, got.center.z])}) size (${f([got.size.x, got.size.y, got.size.z])}) vs catalog offset (${f(p.offset)}) size (${f(p.size)})`);
      }
    }
  }
  lines.unshift(`mesh orientation check: ${checked} pieces in ${catalog.length} models, ${mismatches} problem(s)`);
  return { text: lines.join('\n'), mismatches };
}
