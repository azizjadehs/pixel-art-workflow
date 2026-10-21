// server.js - local web app for the pixel-art workflow.
// Serves the UI, accepts an uploaded image, runs the 3 pipeline steps
// (generate -> pixelate -> slice) and hands back the resulting files.
//
// zero dependencies: Node's built-in http/fs/child_process only.
// binds to 127.0.0.1 so it is not exposed to the network.

const http = require('http');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');
const crypto = require('crypto');

const ROOT = path.resolve(__dirname, '..');
const INPUT = path.join(ROOT, 'input');
const OUTPUT = path.join(ROOT, 'output');
const PORT = Number(process.env.PORT || 7788);
const HOST = '127.0.0.1';

// Aseprite is not at a fixed path: look at ASEPRITE_EXE, a local (gitignored)
// .env / .env.txt, PATH, then the usual Windows install locations.
function findAseprite() {
  const fromEnv = process.env.ASEPRITE_EXE;
  if (fromEnv && fs.existsSync(fromEnv)) return fromEnv;

  for (const name of ['.env', '.env.txt']) {
    const file = path.join(ROOT, name);
    if (!fs.existsSync(file)) continue;
    for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
      const m = line.match(/^\s*ASEPRITE_EXE\s*=\s*(.+?)\s*$/);
      if (!m) continue;
      const p = m[1].trim().replace(/^["']|["']$/g, '');
      if (fs.existsSync(p)) return p;
    }
  }

  const bases = [process.env.ProgramFiles, process.env['ProgramFiles(x86)'], process.env.LOCALAPPDATA];
  for (const base of bases) {
    if (!base) continue;
    const p = path.join(base, 'Aseprite', 'Aseprite.exe');
    if (fs.existsSync(p)) return p;
  }

  return null;
}

const ASE = findAseprite();
const PS = 'powershell.exe';
const MAX_UPLOAD = 25 * 1024 * 1024;
const ALLOWED_EXT = new Set(['.png', '.jpg', '.jpeg', '.webp', '.gif']);

for (const d of [INPUT, OUTPUT]) fs.mkdirSync(d, { recursive: true });
const PREVIEW = path.join(OUTPUT, '.previews');
fs.mkdirSync(PREVIEW, { recursive: true });

// ------------------------------------------------------- .aseprite view
// browsers cannot read .aseprite files, so ask the local Aseprite CLI to
// export a PNG sheet + frame metadata (name, rect, duration) and serve that
function exportPreview(asePath) {
  return new Promise((resolve, reject) => {
    const png = path.join(PREVIEW, path.basename(asePath) + '.png');
    const jsonPath = png + '.json';
    let srcStat;
    try {
      srcStat = fs.statSync(asePath);
    } catch {
      return reject(new Error('file not found'));
    }
    if (
      fs.existsSync(png) &&
      fs.existsSync(jsonPath) &&
      fs.statSync(png).mtimeMs >= srcStat.mtimeMs
    ) {
      return resolve({ png, json: jsonPath });
    }
    if (!ASE) return reject(new Error('Aseprite not found - set ASEPRITE_EXE or add aseprite to PATH'));

    const child = spawn(
      ASE,
      ['-b', asePath, '--sheet', png, '--data', jsonPath, '--format', 'json-hash', '--sheet-type', 'horizontal'],
      { cwd: ROOT, windowsHide: true }
    );
    let err = '';
    child.stderr.on('data', (d) => (err += d.toString()));
    child.on('error', reject);
    child.on('close', (code) => {
      if (code !== 0 || !fs.existsSync(png)) {
        return reject(new Error('Aseprite export failed: ' + err.trim()));
      }
      resolve({ png, json: jsonPath });
    });
  });
}

const jobs = new Map();
let queue = Promise.resolve();

// ------------------------------------------------------------ helpers
function json(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(body);
}

function sendFile(res, file, type) {
  fs.readFile(file, (err, data) => {
    if (err) return json(res, 404, { error: 'not found' });
    res.writeHead(200, { 'Content-Type': type });
    res.end(data);
  });
}

function safeBaseName(name) {
  let base = path.basename(String(name || 'upload'));
  base = base.replace(/[^A-Za-z0-9 ._-]/g, '_').trim().replace(/\s+/g, ' ');
  if (!base) base = 'upload';
  return base;
}

function outputPath(name) {
  // only allow files that really live in output/
  const p = path.resolve(OUTPUT, path.basename(String(name || '')));
  if (!p.startsWith(OUTPUT + path.sep)) return null;
  return p;
}

function runStep(job, script, args) {
  return new Promise((resolve, reject) => {
    job.logs.push('> ' + script + ' ' + args.join(' '));
    const child = spawn(PS, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(ROOT, script), ...args], {
      cwd: ROOT,
      windowsHide: true,
    });
    let buf = '';
    const onData = (d) => {
      buf += d.toString();
      let i;
      while ((i = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, i).replace(/\r$/, '');
        buf = buf.slice(i + 1);
        if (line.trim()) job.logs.push(line);
      }
    };
    child.stdout.on('data', onData);
    child.stderr.on('data', onData);
    child.on('error', reject);
    child.on('close', (code) => {
      if (buf.trim()) job.logs.push(buf.trim());
      if (code === 0) resolve();
      else reject(new Error(script + ' exited with code ' + code));
    });
  });
}

// ----------------------------------------------------------- job runner
function startJob(opts) {
  const job = {
    id: crypto.randomUUID(),
    status: 'running',
    logs: [],
    result: null,
    error: null,
    started: Date.now(),
  };
  jobs.set(job.id, job);

  queue = queue
    .then(async () => {
      try {
        await runStep(job, 'generate.ps1', ['-ImageFile', opts.filePath]);

        const genPng = path.join(INPUT, opts.base + '-generated.png');
        const runArgs = ['-InputFile', genPng, '-Colors', String(opts.colors), '-Filter', opts.filter];
        if (opts.percent > 0) runArgs.push('-Percent', String(opts.percent));
        else runArgs.push('-Size', String(opts.size));
        await runStep(job, 'run.ps1', runArgs);

        const pixelPng = path.join(OUTPUT, opts.base + '-generated.png');
        await runStep(job, 'slice.ps1', ['-InputFile', pixelPng]);

        const candidates = [
          { name: opts.base + '-generated-sprites.aseprite', label: 'Sprites (.aseprite, one frame per view)' },
          { name: opts.base + '-generated.aseprite', label: 'Whole sheet (.aseprite)' },
          { name: opts.base + '-generated.png', label: 'Pixel art (PNG)' },
          { name: opts.base + '-generated-sheet.png', label: 'Uniform sheet (PNG)' },
          { name: opts.base + '-generated-sheet.json', label: 'Sheet data (JSON)' },
        ];
        job.result = candidates.filter((f) => fs.existsSync(path.join(OUTPUT, f.name)));
        job.status = 'done';
        job.logs.push('DONE');
      } catch (e) {
        job.status = 'error';
        job.error = String((e && e.message) || e);
        job.logs.push('ERROR: ' + job.error);
      }
    })
    .catch((e) => {
      job.status = 'error';
      job.error = String((e && e.message) || e);
    });

  return job;
}

// ---------------------------------------------------------------- server
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://' + (req.headers.host || 'localhost'));

  // ---- UI
  if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) {
    return sendFile(res, path.join(__dirname, 'index.html'), 'text/html; charset=utf-8');
  }

  // ---- job status
  if (req.method === 'GET' && url.pathname === '/api/job') {
    const job = jobs.get(url.searchParams.get('id') || '');
    if (!job) return json(res, 404, { error: 'no such job' });
    return json(res, 200, {
      id: job.id,
      status: job.status,
      logs: job.logs,
      result: job.result,
      error: job.error,
    });
  }

  // ---- list everything already in output/ (browse without running)
  if (req.method === 'GET' && url.pathname === '/api/outputs') {
    const files = fs
      .readdirSync(OUTPUT, { withFileTypes: true })
      .filter((e) => e.isFile() && /\.(png|aseprite)$/i.test(e.name))
      .map((e) => {
        const st = fs.statSync(path.join(OUTPUT, e.name));
        return { name: e.name, size: st.size, mtime: st.mtimeMs, kind: path.extname(e.name).slice(1).toLowerCase() };
      })
      .sort((a, b) => b.mtime - a.mtime);
    return json(res, 200, { files });
  }

  // ---- file download / inline preview
  if (req.method === 'GET' && url.pathname === '/api/file') {
    const p = outputPath(url.searchParams.get('name'));
    if (!p || !fs.existsSync(p)) return json(res, 404, { error: 'not found' });
    const ext = path.extname(p).toLowerCase();
    const types = { '.png': 'image/png', '.json': 'application/json', '.aseprite': 'application/octet-stream' };
    const dl = url.searchParams.get('dl') === '1';
    const headers = { 'Content-Type': types[ext] || 'application/octet-stream' };
    if (dl) headers['Content-Disposition'] = 'attachment; filename="' + path.basename(p) + '"';
    res.writeHead(200, headers);
    fs.createReadStream(p).pipe(res);
    return;
  }

  // ---- render an .aseprite file as a PNG preview
  if (req.method === 'GET' && url.pathname === '/api/view') {
    const p = outputPath(url.searchParams.get('name'));
    if (!p || !fs.existsSync(p)) return json(res, 404, { error: 'not found' });
    if (path.extname(p).toLowerCase() !== '.aseprite') {
      return json(res, 400, { error: 'not an .aseprite file' });
    }
    try {
      const { png } = await exportPreview(p);
      res.writeHead(200, { 'Content-Type': 'image/png', 'Cache-Control': 'no-store' });
      fs.createReadStream(png).pipe(res);
    } catch (e) {
      json(res, 500, { error: String((e && e.message) || e) });
    }
    return;
  }

  // ---- frame data for the in-browser player (real rects, durations, tags)
  if (req.method === 'GET' && url.pathname === '/api/sprite') {
    const p = outputPath(url.searchParams.get('name'));
    if (!p || !fs.existsSync(p)) return json(res, 404, { error: 'not found' });
    if (path.extname(p).toLowerCase() !== '.aseprite') {
      return json(res, 400, { error: 'not an .aseprite file' });
    }
    try {
      const { json: dataPath } = await exportPreview(p);
      const data = JSON.parse(fs.readFileSync(dataPath, 'utf8'));
      const frames = Object.values(data.frames || {}).map((fr) => ({
        x: fr.frame.x,
        y: fr.frame.y,
        w: fr.frame.w,
        h: fr.frame.h,
        duration: fr.duration || 100,
      }));
      const tags = (data.meta.frameTags || []).map((t) => ({
        name: t.name,
        from: t.from,
        to: t.to,
      }));
      json(res, 200, {
        sheet: '/api/view?name=' + encodeURIComponent(path.basename(p)),
        frames,
        tags,
        size: data.meta.size,
      });
    } catch (e) {
      json(res, 500, { error: String((e && e.message) || e) });
    }
    return;
  }

  // ---- run the pipeline on an uploaded image
  if (req.method === 'POST' && url.pathname === '/api/run') {
    const name = safeBaseName(url.searchParams.get('name') || 'upload.png');
    const ext = path.extname(name).toLowerCase();
    if (!ALLOWED_EXT.has(ext)) return json(res, 400, { error: 'unsupported image type: ' + ext });

    const base = path.basename(name, ext);
    const size = Math.max(1, Number(url.searchParams.get('size') || 256));
    const percent = Math.max(0, Number(url.searchParams.get('percent') || 0));
    const colors = Math.max(1, Number(url.searchParams.get('colors') || 26));
    const filter = url.searchParams.get('filter') === 'average' ? 'average' : 'nearest';

    const chunks = [];
    let total = 0;
    let aborted = false;
    req.on('data', (c) => {
      total += c.length;
      if (total > MAX_UPLOAD) {
        aborted = true;
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => {
      if (aborted) return;
      if (!total) return json(res, 400, { error: 'empty upload' });

      const filePath = path.join(INPUT, base + ext);
      fs.writeFileSync(filePath, Buffer.concat(chunks));

      const job = startJob({ filePath, base, size, percent, colors, filter });
      return json(res, 200, { jobId: job.id });
    });
    req.on('error', () => {});
    return;
  }

  // ---- open a result in the local Aseprite install
  if (req.method === 'POST' && url.pathname === '/api/open') {
    const p = outputPath(url.searchParams.get('name'));
    if (!p || !fs.existsSync(p)) return json(res, 404, { error: 'not found' });
    if (path.extname(p).toLowerCase() !== '.aseprite') return json(res, 400, { error: 'not an .aseprite file' });
    if (!ASE) return json(res, 500, { error: 'Aseprite not found - set ASEPRITE_EXE or add aseprite to PATH' });
    spawn(ASE, [p], { detached: true, stdio: 'ignore' }).unref();
    return json(res, 200, { opened: p });
  }

  return json(res, 404, { error: 'not found' });
});

server.listen(PORT, HOST, () => {
  console.log('pixel-art workflow web app: http://' + HOST + ':' + PORT);
});
