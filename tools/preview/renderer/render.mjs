// render.mjs - draws scene JSON files (from runtime/main.luau) to PNG in headless Chromium.
//
//   node tools/preview/renderer/render.mjs --job scene.json:out.png [--job ...] [--repo PATH]
//   node tools/preview/renderer/render.mjs --check-meshes [--repo PATH]
//
// The page (renderer/page/) is served from memory through Playwright request routing at
// http://preview.local/ : /page/*, /three/* (node_modules/three), /fonts/* (.cache/fonts),
// /meshes/* (the repo's meshes folder) and /job/<n>.json. One browser renders every job.
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.dirname(HERE); // tools/preview
const require = createRequire(import.meta.url);

function loadPlaywright() {
  const tries = ['playwright', 'playwright-core'];
  for (const name of tries) {
    try { return require(name); } catch {}
  }
  try {
    const globalRoot = execSync('npm root -g', { encoding: 'utf8' }).trim();
    return require(path.join(globalRoot, 'playwright'));
  } catch {}
  throw new Error('playwright not found (it is installed globally in the cloud image)');
}

function findChromium() {
  if (process.env.SWARM_CHROMIUM && fs.existsSync(process.env.SWARM_CHROMIUM)) return process.env.SWARM_CHROMIUM;
  const base = process.env.PLAYWRIGHT_BROWSERS_PATH || '/opt/pw-browsers';
  if (!fs.existsSync(base)) return undefined;
  const dirs = fs.readdirSync(base).filter((d) => /^chromium-\d+$/.test(d)).sort().reverse();
  for (const d of dirs) {
    const p = path.join(base, d, 'chrome-linux', 'chrome');
    if (fs.existsSync(p)) return p;
  }
  return undefined;
}

function parseArgs(argv) {
  const out = { jobs: [], repo: path.resolve(ROOT, '..', '..'), check: false, timeout: 120000 };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--job') {
      const v = argv[++i];
      const idx = v.lastIndexOf(':');
      out.jobs.push({ input: v.slice(0, idx), output: v.slice(idx + 1) });
    } else if (a === '--repo') out.repo = path.resolve(argv[++i]);
    else if (a === '--check-meshes') out.check = true;
    else if (a === '--timeout') out.timeout = Number(argv[++i]) * 1000;
  }
  return out;
}

const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json', '.ttf': 'font/ttf', '.fbx': 'application/octet-stream', '.png': 'image/png', '.css': 'text/css' };

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const { chromium } = loadPlaywright();
  const browser = await chromium.launch({
    headless: true,
    executablePath: findChromium(),
    args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--disable-gpu-sandbox'],
  });
  const files = {
    '/page/': path.join(HERE, 'page'),
    '/three/': path.join(ROOT, 'node_modules', 'three'),
    '/fonts/': path.join(ROOT, '.cache', 'fonts'),
    '/meshes/': path.join(args.repo, 'meshes'),
    '/art/': path.join(args.repo, 'art'),
  };
  let jobData = null;
  const serve = async (route) => {
    const url = new URL(route.request().url());
    const p = decodeURIComponent(url.pathname);
    if (p === '/job.json') return route.fulfill({ status: 200, contentType: 'application/json', body: jobData });
    if (p === '/artmap.json') {
      // uploaded owner art (art/uploaded_art.json: key -> id) as id -> key, so the page can
      // draw the real picture for an "rbxassetid://<id>" image instead of a placeholder
      const map = {};
      const f = path.join(args.repo, 'art', 'uploaded_art.json');
      try { for (const [k, v] of Object.entries(JSON.parse(fs.readFileSync(f, 'utf8')))) map[String(v)] = k; } catch (e) { /* no art */ }
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(map) });
    }
    for (const [prefix, dir] of Object.entries(files)) {
      if (p.startsWith(prefix)) {
        const file = path.join(dir, p.slice(prefix.length));
        if (file.startsWith(dir) && fs.existsSync(file) && fs.statSync(file).isFile()) {
          return route.fulfill({ status: 200, contentType: MIME[path.extname(file)] || 'application/octet-stream', body: fs.readFileSync(file) });
        }
      }
    }
    return route.fulfill({ status: 404, body: 'not found: ' + p });
  };

  let failures = 0;
  if (args.check) {
    const page = await browser.newPage({ viewport: { width: 400, height: 300 } });
    await page.route('http://preview.local/**', serve);
    page.on('console', (m) => { if (m.type() === 'error') console.log('[page]', m.text()); });
    await page.goto('http://preview.local/page/index.html?mode=check');
    await page.waitForFunction('window.__done === true', null, { timeout: args.timeout });
    const report = await page.evaluate('window.__report');
    console.log(report.text);
    failures = report.mismatches;
    await browser.close();
    process.exit(failures > 0 ? 1 : 0);
  }

  for (const job of args.jobs) {
    jobData = fs.readFileSync(job.input, 'utf8');
    const scene = JSON.parse(jobData);
    const d = scene.device;
    const page = await browser.newPage({ viewport: { width: d.width, height: d.height }, deviceScaleFactor: d.dpr || 1 });
    await page.route('http://preview.local/**', serve);
    const logs = [];
    page.on('console', (m) => logs.push(`[page:${m.type()}] ${m.text()}`));
    page.on('pageerror', (e) => logs.push(`[page:error] ${e.message}`));
    const t0 = Date.now();
    try {
      await page.goto('http://preview.local/page/index.html?mode=render');
      await page.waitForFunction('window.__done === true', null, { timeout: args.timeout });
      const report = await page.evaluate('window.__report');
      fs.mkdirSync(path.dirname(job.output), { recursive: true });
      await page.screenshot({ path: job.output, type: 'png' });
      const extra = report && report.warnings && report.warnings.length ? ` (${report.warnings.length} renderer notes)` : '';
      console.log(`[render] ${path.basename(job.output)} ${d.width}x${d.height}@${d.dpr || 1}x in ${((Date.now() - t0) / 1000).toFixed(1)}s${extra}`);
      if (report && report.warnings) for (const w of report.warnings.slice(0, 12)) console.log('  - ' + w);
    } catch (e) {
      failures++;
      console.log(`[render] FAILED ${job.output}: ${e.message}`);
      for (const l of logs.slice(-20)) console.log('  ' + l);
    }
    for (const l of logs) if (l.includes(':error]')) console.log('  ' + l);
    await page.close();
  }
  await browser.close();
  process.exit(failures > 0 ? 1 : 0);
}

main().catch((e) => { console.error(e); process.exit(1); });
