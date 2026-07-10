(function () {
  const { loadWasm } = window.ZignalUtils;
  let wasm = null;
  let decodeString;

  // ---- DOM ----
  const presetSel = document.getElementById("preset");
  const fnInput = document.getElementById("fn-input");
  const fnError = document.getElementById("fn-error");
  const boundsBody = document.getElementById("bounds-body");
  const addVarBtn = document.getElementById("add-var");
  const policySel = document.getElementById("policy");
  const maxEvalsInput = document.getElementById("max-evals");
  const seedInput = document.getElementById("seed");
  const samplesInput = document.getElementById("samples");
  const colormapSel = document.getElementById("colormap");
  const animateChk = document.getElementById("animate");
  const runBtn = document.getElementById("run-button");
  const stepBtn = document.getElementById("step-button");
  const canvas = document.getElementById("opt-canvas");
  const ctx = canvas.getContext("2d");
  const legendEl = document.getElementById("opt-legend");
  const expectedEl = document.getElementById("opt-expected");
  const resultsEl = document.getElementById("opt-results");
  const statusEl = document.getElementById("status");

  // Each preset pre-fills the objective, its bounds, the goal, and a sensible eval budget.
  const PRESETS = [
    {
      name: "Holder table (2-D)",
      expected: "≈ -19.2085 (4 minima, e.g. (8.06, 9.66))",
      policy: "0",
      evals: 250,
      vars: [{ lo: -10, hi: 10 }, { lo: -10, hi: 10 }],
      code: `// Holder table: four global minima amid many local ones.
const r = Math.sqrt(x[0] * x[0] + x[1] * x[1]);
return -Math.abs(Math.sin(x[0]) * Math.cos(x[1]) * Math.exp(Math.abs(1 - r / Math.PI)));
`,
    },
    {
      name: "Rastrigin (2-D)",
      expected: "= 0 at the origin",
      policy: "0",
      evals: 300,
      vars: [{ lo: -5.12, hi: 5.12 }, { lo: -5.12, hi: 5.12 }],
      code: `// Rastrigin: a regular egg-carton of minima. Global min 0 at the origin.
let s = 10 * x.length;
for (let i = 0; i < x.length; i++) s += x[i] * x[i] - 10 * Math.cos(2 * Math.PI * x[i]);
return s;
`,
    },
    {
      name: "Ackley (2-D)",
      expected: "= 0 at the origin",
      policy: "0",
      evals: 200,
      vars: [{ lo: -5, hi: 5 }, { lo: -5, hi: 5 }],
      code: `// Ackley: a deep central funnel pitted with shallow local minima. Min 0 at the origin.
const d = x.length;
let s1 = 0, s2 = 0;
for (let i = 0; i < d; i++) { s1 += x[i] * x[i]; s2 += Math.cos(2 * Math.PI * x[i]); }
return -20 * Math.exp(-0.2 * Math.sqrt(s1 / d)) - Math.exp(s2 / d) + 20 + Math.E;
`,
    },
    {
      name: "Rosenbrock (2-D)",
      expected: "= 0 at (1, 1)",
      policy: "0",
      evals: 300,
      vars: [{ lo: -2, hi: 2 }, { lo: -1, hi: 3 }],
      code: `// Rosenbrock 'banana' valley. Global min 0 at (1, 1).
const a = 1 - x[0];
const b = x[1] - x[0] * x[0];
return a * a + 100 * b * b;
`,
    },
    {
      name: "Himmelblau (2-D)",
      expected: "= 0 (4 minima, e.g. (3, 2))",
      policy: "0",
      evals: 200,
      vars: [{ lo: -5, hi: 5 }, { lo: -5, hi: 5 }],
      code: `// Himmelblau: four equal global minima (value 0).
const a = x[0] * x[0] + x[1] - 11;
const b = x[0] + x[1] * x[1] - 7;
return a * a + b * b;
`,
    },
    {
      name: "Eggholder (2-D, hard)",
      expected: "≈ -959.64 at (512, 404.23)",
      policy: "0",
      evals: 500,
      samples: 5000,
      vars: [{ lo: -512, hi: 512 }, { lo: -512, hi: 512 }],
      code: `// Eggholder: famously hard, wildly multimodal. Global min ≈ -959.64 at (512, 404.23).
const a = x[1] + 47;
return -a * Math.sin(Math.sqrt(Math.abs(x[0] / 2 + a)))
       - x[0] * Math.sin(Math.sqrt(Math.abs(x[0] - a)));
`,
    },
    {
      name: "Twin peaks — maximize (2-D)",
      expected: "≈ 1.60 at (1.80, 0.99)",
      policy: "1",
      evals: 200,
      vars: [{ lo: -4, hi: 4 }, { lo: -4, hi: 4 }],
      code: `// Maximize: a few Gaussian bumps — find the tallest peak.
function bump(cx, cy, h) {
  return h * Math.exp(-((x[0] - cx) ** 2 + (x[1] - cy) ** 2) / 2);
}
return bump(-1.5, -1.5, 1) + bump(1.8, 1.0, 1.6) + bump(0.5, -2.2, 1.2);
`,
    },
    {
      name: "Gramacy & Lee (1-D)",
      expected: "≈ -0.869 at x ≈ 0.548",
      policy: "0",
      evals: 150,
      vars: [{ lo: 0.5, hi: 2.5 }],
      code: `// Gramacy & Lee (2012), 1-D. Global min ≈ -0.869 at x ≈ 0.548.
return Math.sin(10 * Math.PI * x[0]) / (2 * x[0]) + Math.pow(x[0] - 1, 4);
`,
    },
    {
      name: "Sines (1-D)",
      expected: "≈ -1.90 at x ≈ 5.146",
      policy: "0",
      evals: 120,
      vars: [{ lo: 2.7, hi: 7.5 }],
      code: `// 1-D multimodal. Global min ≈ -1.9 at x ≈ 5.15.
return Math.sin(x[0]) + Math.sin((10 / 3) * x[0]);
`,
    },
    {
      name: "Wavy step bowl — discontinuous (1-D)",
      expected: "≈ -1.04 at x ≈ 2.0",
      policy: "0",
      evals: 300,
      samples: 4000,
      vars: [{ lo: -2, hi: 8 }],
      code: `// A bowl + an oscillating sine + sawtooth discontinuities (the value jumps down at every
// integer): multimodal AND non-smooth. Derivative-free MaxLIPO handles what gradients can't.
const saw = x[0] - Math.floor(x[0]);
return 0.4 * (x[0] - 3) * (x[0] - 3) + 1.5 * Math.sin(2.5 * x[0]) + 0.7 * saw;
`,
    },
    {
      name: "Spiky signal — maximize (1-D)",
      expected: "≈ 1.8 at x ≈ 9.0 (the tallest spike)",
      policy: "1",
      evals: 400,
      samples: 4000,
      vars: [{ lo: 0, hi: 11 }],
      code: `// A flat baseline studded with sharp peaks of different heights (a sum of Gaussian bumps).
// Maximize to hunt down the tallest spike among many decoys.
const peaks = [
  [0.6, 0.35, 0.18], [1.5, 0.9, 0.22], [2.2, 0.5, 0.15], [2.7, 0.7, 0.12],
  [3.1, 0.25, 0.1], [4.0, 1.0, 0.2], [5.0, 0.55, 0.15], [6.5, 0.3, 0.25],
  [8.2, 0.6, 0.15], [9.0, 1.8, 0.25], [9.8, 0.9, 0.18], [10.5, 0.4, 0.12],
];
let s = 0;
for (let i = 0; i < peaks.length; i++) {
  const d = (x[0] - peaks[i][0]) / peaks[i][2];
  s += peaks[i][1] * Math.exp(-d * d);
}
return s;
`,
    },
    {
      name: "Sphere (4-D)",
      expected: "= 0 at the origin",
      policy: "0",
      evals: 300,
      vars: [{ lo: -5, hi: 5 }, { lo: -5, hi: 5 }, { lo: -5, hi: 5 }, { lo: -5, hi: 5 }],
      code: `// Sphere in 4-D: sum of squares. Global min 0 at the origin (uses the N-D convergence plot).
let s = 0;
for (let i = 0; i < x.length; i++) s += x[i] * x[i];
return s;
`,
    },
  ];

  // GlobalOptimizer.Move: init / random / explore / exploit.
  const MOVE_NAMES = ["init", "random", "explore", "exploit"];
  const MOVE_COLORS = ["#ffffff", "#9aa0a6", "#22b3c9", "#ff7043"];
  const BEST_COLOR = "#ff2d95";

  // 256-entry RGB LUT from zignal's `colormap_lut` export; null until WASM loads (id matches <select>).
  let colormapId = 2; // turbo (matches the default <option>)
  let colormapLut = null;

  function loadColormapLut() {
    if (!wasm) return;
    const ptr = wasm.colormap_lut(colormapId);
    // Copy: the view aliases WASM memory, which the next call reuses (and which can move on growth).
    colormapLut = new Uint8Array(wasm.memory.buffer, ptr, 256 * 3).slice();
  }

  // ---- run state ----
  let objectiveFn = null; // compiled user function
  let evalError = null; // exception thrown by the objective during a step
  let dims = 0;
  let bounds = [];
  let maxEvals = 0;
  let evalsDone = 0;
  let computeMs = 0; // wall-clock spent inside step batches (excludes animation frame gaps)
  let animating = false;
  let running = false; // the continuous auto-run (rAF loop) is active
  let prepared = false; // a session (optimizer + counters) matching the current inputs exists
  let surfaceBuilt = false; // the heatmap/curve background has been drawn for this session
  let rafId = 0;
  let points = []; // { x:[..], y, move } for every evaluated point
  let bestHistory = []; // best-y-so-far per eval (convergence plot)
  let heatmap = null; // colored ImageData background for 2-D problems
  let heatmapKey = null; // fn + bounds + size + colormap: recolor only when this changes
  let heatField = null; // { vals, min, max } sampled objective, independent of the colormap
  let heatFieldKey = null; // fn + bounds + size: resample the objective only when this changes
  let curve = null; // { ys, min, max, pad } sampled function for 1-D problems
  let curveKey = null;
  let view = null; // { xlo, xhi, ylo, yhi } pixel <-> world mapping

  // The objective callback the WASM module imports. Reads the point straight out of WASM memory,
  // runs the user function, and captures any error to surface after the step (the Zig side has no
  // error channel — it just gets a number back).
  function evaluate(ptr, len) {
    if (evalError) return 0;
    const x = new Float64Array(wasm.memory.buffer, ptr, len);
    try {
      const y = objectiveFn(x);
      if (typeof y !== "number" || !isFinite(y)) {
        evalError = new Error("objective returned " + y + " (expected a finite number)");
        return 0;
      }
      return y;
    } catch (e) {
      evalError = e;
      return 0;
    }
  }

  // ---- variable rows ----
  function renumber() {
    Array.prototype.forEach.call(boundsBody.children, function (tr, i) {
      tr.querySelector(".idx").textContent = "x[" + i + "]";
    });
  }

  function addVariable(lo, hi, isInt) {
    const tr = document.createElement("tr");
    tr.innerHTML =
      '<td class="idx"></td>' +
      '<td><input class="lo" type="number" step="any" value="' + lo + '"></td>' +
      '<td><input class="hi" type="number" step="any" value="' + hi + '"></td>' +
      '<td style="text-align:center"><input class="int" type="checkbox"></td>' +
      '<td><button type="button" class="copy-button remove-var opt-small-btn">&times;</button></td>';
    if (isInt) tr.querySelector(".int").checked = true;
    tr.querySelector(".remove-var").addEventListener("click", function () {
      if (boundsBody.children.length > 1) {
        tr.remove();
        renumber();
        invalidateSession();
        drawPreview();
      }
    });
    boundsBody.appendChild(tr);
    renumber();
  }

  function clearVariables() {
    boundsBody.innerHTML = "";
  }

  function setVariables(vars) {
    clearVariables();
    for (let i = 0; i < vars.length; i++) {
      addVariable(vars[i].lo, vars[i].hi, !!vars[i].int);
    }
  }

  function populatePresets() {
    for (let i = 0; i < PRESETS.length; i++) {
      const o = document.createElement("option");
      o.value = String(i);
      o.textContent = PRESETS[i].name;
      presetSel.appendChild(o);
    }
    const custom = document.createElement("option");
    custom.value = "custom";
    custom.textContent = "Custom…";
    presetSel.appendChild(custom);
  }

  function applyPreset(i) {
    const p = PRESETS[i];
    fnInput.value = p.code;
    setVariables(p.vars);
    policySel.value = p.policy;
    if (p.evals) maxEvalsInput.value = p.evals;
    if (p.samples) samplesInput.value = p.samples;
    expectedEl.textContent = p.expected ? "Expected optimum " + p.expected : "";
  }

  function readBounds() {
    const b = [];
    const ints = [];
    Array.prototype.forEach.call(boundsBody.children, function (tr) {
      b.push([parseFloat(tr.querySelector(".lo").value), parseFloat(tr.querySelector(".hi").value)]);
      ints.push(tr.querySelector(".int").checked);
    });
    for (let i = 0; i < b.length; i++) {
      const lo = b[i][0];
      const hi = b[i][1];
      if (!isFinite(lo) || !isFinite(hi)) throw new Error("Variable x[" + i + "]: bounds must be numbers.");
      if (!(hi > lo)) throw new Error("Variable x[" + i + "]: lower (" + lo + ") must be < upper (" + hi + ").");
      if (ints[i] && (Math.round(lo) !== lo || Math.round(hi) !== hi)) {
        throw new Error("Variable x[" + i + "]: integer bounds must be whole numbers.");
      }
    }
    return { bounds: b, ints: ints };
  }

  // ---- WASM bridge ----
  function wasmInit(b, ints, policy, seed, samples) {
    const n = b.length;
    const ptr = wasm.alloc_f64(2 * n);
    const buf = new Float64Array(wasm.memory.buffer, ptr, 2 * n);
    for (let i = 0; i < n; i++) {
      buf[2 * i] = b[i][0];
      buf[2 * i + 1] = b[i][1];
    }
    let mask = 0;
    for (let i = 0; i < n && i < 32; i++) {
      if (ints[i]) mask |= 1 << i;
    }
    const code = wasm.optimizer_init(ptr, n, mask >>> 0, policy, seed >>> 0, samples >>> 0, 0.02);
    wasm.free_f64(ptr, 2 * n);
    return code;
  }

  function initErrorMessage(code) {
    if (code === -2) return "Invalid bounds (each variable needs lower < upper).";
    if (code === -3) return "Integer variables need whole-number bounds.";
    return "Failed to initialize the optimizer.";
  }

  // Returns false on (and reports) an objective/step error.
  function doStep() {
    const idx = wasm.optimizer_step();
    if (evalError) {
      fnError.textContent = "Objective error: " + evalError.message;
      return false;
    }
    if (idx < 0) {
      fnError.textContent = "Optimizer step failed.";
      return false;
    }
    const lx = Array.from(new Float64Array(wasm.memory.buffer, wasm.get_last_x(), dims));
    points.push({ x: lx, y: wasm.get_last_y(), move: wasm.get_last_move() });
    bestHistory.push(wasm.get_best_y());
    evalsDone++;
    return true;
  }

  // ---- visualization ----
  function clearCanvas() {
    ctx.fillStyle = "#fff";
    ctx.fillRect(0, 0, canvas.width, canvas.height);
  }

  function toPixel(x, y) {
    const px = ((x - view.xlo) / (view.xhi - view.xlo)) * canvas.width;
    const py = (1 - (y - view.ylo) / (view.yhi - view.ylo)) * canvas.height; // flip y
    return [px, py];
  }

  // Sample the compiled objective at `count` points; `writeCoord(i, pt)` fills `pt` (length
  // `ndims`) with the i-th point's coordinates. Returns the values and their finite min/max
  // (non-finite results become NaN). Shared by the 1-D curve and 2-D heatmap builders.
  function sampleField(count, ndims, writeCoord) {
    const vals = new Float64Array(count);
    const pt = new Array(ndims);
    let min = Infinity;
    let max = -Infinity;
    for (let i = 0; i < count; i++) {
      writeCoord(i, pt);
      let v;
      try {
        v = objectiveFn(pt);
      } catch (e) {
        v = NaN;
      }
      if (typeof v !== "number") v = NaN;
      vals[i] = v;
      if (isFinite(v)) {
        if (v < min) min = v;
        if (v > max) max = v;
      }
    }
    return { vals: vals, min: min, max: max };
  }

  // The shared L-shaped plot axes (left + bottom), used by the 1-D and convergence views.
  function drawAxes(pad, color) {
    ctx.strokeStyle = color;
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(pad, pad);
    ctx.lineTo(pad, canvas.height - pad);
    ctx.lineTo(canvas.width - pad, canvas.height - pad);
    ctx.stroke();
  }

  // Draw the evaluated samples as move-coloured dots. `project(p)` maps a point to [px, py], or
  // returns null to skip it. (Invariant context state is set once, outside the loop.)
  function drawSamplePoints(project) {
    ctx.lineWidth = 0.5;
    ctx.strokeStyle = "rgba(0,0,0,0.5)";
    for (let k = 0; k < points.length; k++) {
      const p = points[k];
      const xy = project(p);
      if (!xy) continue;
      ctx.beginPath();
      ctx.arc(xy[0], xy[1], 3, 0, 2 * Math.PI);
      ctx.globalAlpha = 0.85;
      ctx.fillStyle = MOVE_COLORS[p.move] || "#fff";
      ctx.fill();
      ctx.globalAlpha = 1;
      ctx.stroke();
    }
  }

  function buildHeatmap() {
    const W = canvas.width;
    const H = canvas.height;
    const fkey = fnInput.value + "|" + view.xlo + "," + view.xhi + "," + view.ylo + "," + view.yhi + "|" + W + "x" + H;
    // Cache the sampled objective (the expensive, colormap-independent part) so a switch only recolors.
    if (!heatField || heatFieldKey !== fkey) {
      const sx = view.xhi - view.xlo;
      const sy = view.yhi - view.ylo;
      heatField = sampleField(W * H, 2, function (p, pt) {
        const i = p % W;
        pt[0] = view.xlo + ((i + 0.5) / W) * sx;
        pt[1] = view.ylo + (1 - ((p - i) / W + 0.5) / H) * sy;
      });
      heatFieldKey = fkey;
      heatmap = null; // field changed -> force a recolor
    }
    const hkey = fkey + "|cm" + colormapId;
    if (heatmap && heatmapKey === hkey) return;
    const range = heatField.max > heatField.min ? heatField.max - heatField.min : 1;
    const lut = colormapLut;
    const img = ctx.createImageData(W, H);
    const data = img.data;
    for (let p = 0; p < W * H; p++) {
      const v = heatField.vals[p];
      const o = p * 4;
      if (!isFinite(v)) {
        data[o] = data[o + 1] = data[o + 2] = 210;
      } else if (lut) {
        const i = Math.round(((v - heatField.min) / range) * 255) * 3;
        data[o] = lut[i];
        data[o + 1] = lut[i + 1];
        data[o + 2] = lut[i + 2];
      } else {
        data[o] = data[o + 1] = data[o + 2] = Math.round(40 + ((v - heatField.min) / range) * 180);
      }
      data[o + 3] = 255;
    }
    heatmap = img;
    heatmapKey = hkey;
  }

  function drawCrosshair(px, py) {
    ctx.save();
    ctx.strokeStyle = BEST_COLOR;
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.arc(px, py, 7, 0, 2 * Math.PI);
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(px - 11, py);
    ctx.lineTo(px + 11, py);
    ctx.moveTo(px, py - 11);
    ctx.lineTo(px, py + 11);
    ctx.stroke();
    ctx.restore();
  }

  function drawHeatmapView() {
    if (!heatmap) {
      clearCanvas();
      return;
    }
    ctx.putImageData(heatmap, 0, 0);
    drawSamplePoints(function (p) {
      return toPixel(p.x[0], p.x[1]);
    });
    if (wasm && points.length > 0) {
      const bx = new Float64Array(wasm.memory.buffer, wasm.get_best_x(), dims);
      const bp = toPixel(bx[0], bx[1]);
      drawCrosshair(bp[0], bp[1]);
    }
  }

  function drawConvergence() {
    const W = canvas.width;
    const H = canvas.height;
    const pad = 44;
    clearCanvas();
    if (bestHistory.length === 0) return;
    let ymin = Infinity;
    let ymax = -Infinity;
    for (let i = 0; i < bestHistory.length; i++) {
      const v = bestHistory[i];
      if (isFinite(v)) {
        if (v < ymin) ymin = v;
        if (v > ymax) ymax = v;
      }
    }
    if (!isFinite(ymin)) return;
    const yr = ymax > ymin ? ymax - ymin : 1;
    drawAxes(pad, "#888");
    const span = maxEvals > 1 ? maxEvals - 1 : 1;
    // Build the polyline and the per-eval dots in one pass; the dot keeps a single point (or a
    // flat history) visible.
    const line = new Path2D();
    const dots = new Path2D();
    for (let i = 0; i < bestHistory.length; i++) {
      const px = pad + (i / span) * (W - 2 * pad);
      const py = H - pad - ((bestHistory[i] - ymin) / yr) * (H - 2 * pad);
      if (i === 0) line.moveTo(px, py);
      else line.lineTo(px, py);
      dots.moveTo(px + 2.5, py);
      dots.arc(px, py, 2.5, 0, 2 * Math.PI);
    }
    ctx.strokeStyle = "#007bff";
    ctx.lineWidth = 2;
    ctx.stroke(line);
    ctx.fillStyle = "#007bff";
    ctx.fill(dots);
    ctx.fillStyle = "#333";
    ctx.font = "12px monospace";
    ctx.fillText("best y", pad + 4, pad - 10);
    ctx.fillText("evals →", W - pad - 48, H - pad + 22);
    ctx.fillText(ymax.toPrecision(4), 2, pad + 4);
    ctx.fillText(ymin.toPrecision(4), 2, H - pad);
  }

  function build1DCurve() {
    const W = canvas.width;
    const pad = 36;
    const cols = Math.max(2, W - 2 * pad);
    const key = fnInput.value + "|" + view.xlo + "," + view.xhi + "|" + cols;
    if (curve && curveKey === key) return; // unchanged function + bounds -> reuse
    const span = view.xhi - view.xlo;
    const field = sampleField(cols, 1, function (i, pt) {
      pt[0] = view.xlo + (i / (cols - 1)) * span;
    });
    let min = field.min;
    let max = field.max;
    if (!isFinite(min)) {
      min = 0;
      max = 1;
    }
    curve = { ys: field.vals, min: min, max: max, pad: pad };
    curveKey = key;
  }

  function draw1DView() {
    if (!curve) {
      clearCanvas();
      return;
    }
    const W = canvas.width;
    const H = canvas.height;
    const pad = curve.pad;
    const cols = curve.ys.length;
    const yr = curve.max > curve.min ? curve.max - curve.min : 1;
    clearCanvas();
    const xToPx = function (x) {
      return pad + ((x - view.xlo) / (view.xhi - view.xlo)) * (W - 2 * pad);
    };
    const yToPx = function (y) {
      return H - pad - ((y - curve.min) / yr) * (H - 2 * pad);
    };
    drawAxes(pad, "#bbb");
    // the function curve, breaking the path at any non-finite gap
    ctx.strokeStyle = "#444";
    ctx.lineWidth = 2;
    ctx.beginPath();
    let pen = false;
    for (let i = 0; i < cols; i++) {
      const v = curve.ys[i];
      if (!isFinite(v)) {
        pen = false;
        continue;
      }
      const px = pad + (i / (cols - 1)) * (W - 2 * pad);
      const py = yToPx(v);
      if (!pen) {
        ctx.moveTo(px, py);
        pen = true;
      } else {
        ctx.lineTo(px, py);
      }
    }
    ctx.stroke();
    // evaluated samples, sitting on the curve, coloured by move
    drawSamplePoints(function (p) {
      return isFinite(p.y) ? [xToPx(p.x[0]), yToPx(p.y)] : null;
    });
    if (wasm && points.length > 0) {
      const bx = new Float64Array(wasm.memory.buffer, wasm.get_best_x(), dims);
      const by = wasm.get_best_y();
      if (isFinite(by)) drawCrosshair(xToPx(bx[0]), yToPx(by));
    }
    ctx.fillStyle = "#333";
    ctx.font = "12px monospace";
    ctx.fillText("f(x)", pad + 4, pad - 6);
    ctx.fillText("x →", W - pad - 28, H - pad + 20);
  }

  function draw() {
    if (dims === 1) draw1DView();
    else if (dims === 2) drawHeatmapView();
    else drawConvergence();
  }

  function renderLegend() {
    if (dims <= 2) {
      let html = "";
      for (let i = 0; i < MOVE_NAMES.length; i++) {
        html +=
          '<span class="opt-legend-item"><span class="opt-legend-swatch" style="background:' +
          MOVE_COLORS[i] + '"></span>' + MOVE_NAMES[i] + "</span>";
      }
      html +=
        '<span class="opt-legend-item"><span class="opt-legend-swatch" style="background:' +
        BEST_COLOR + '"></span>best</span>';
      legendEl.innerHTML = html;
    } else {
      legendEl.textContent = dims + "-D problem — best value vs. evaluations";
    }
  }

  function updateResults() {
    const bx = Array.from(new Float64Array(wasm.memory.buffer, wasm.get_best_x(), dims));
    const by = wasm.get_best_y();
    const xStr = "[" + bx.map(function (v) { return v.toFixed(4); }).join(", ") + "]";
    const last = points.length ? MOVE_NAMES[points[points.length - 1].move] : "";
    resultsEl.innerHTML =
      "<div>eval " + evalsDone + " / " + maxEvals + (last ? " · " + last : "") + "</div>" +
      '<div class="best-line">best y = ' + by.toPrecision(6) + "</div>" +
      "<div>best x = " + xStr + "</div>";
  }

  // ---- run control ----
  function setInputsDisabled(d) {
    [presetSel, fnInput, policySel, maxEvalsInput, seedInput, samplesInput, animateChk, addVarBtn].forEach(function (el) {
      el.disabled = d;
    });
    boundsBody.querySelectorAll("input, button").forEach(function (el) {
      el.disabled = d;
    });
  }

  // Reflect the auto-run state in the buttons: the primary button toggles Optimize/Stop, and Step is
  // only available while the auto-run is paused.
  function setRunning(on) {
    running = on;
    runBtn.textContent = on ? "Stop" : "Optimize";
    stepBtn.disabled = on;
    setInputsDisabled(on);
  }

  // Invalidate the session so the next Optimize/Step rebuilds it from the current inputs.
  function invalidateSession() {
    prepared = false;
    surfaceBuilt = false;
  }

  // End the auto-run. `sessionDone` true (budget spent or objective failed) means the next
  // Optimize/Step starts fresh; false (a manual Stop) keeps the session so it can be resumed.
  function endContinuous(statusMsg, sessionDone) {
    if (rafId) cancelAnimationFrame(rafId);
    rafId = 0;
    setRunning(false);
    if (sessionDone) prepared = false;
    statusEl.textContent = statusMsg;
  }

  function tick(perFrame) {
    if (!running) return;
    let ok = true;
    const t0 = performance.now();
    for (let k = 0; k < perFrame && evalsDone < maxEvals; k++) {
      ok = doStep();
      if (!ok) break;
    }
    computeMs += performance.now() - t0;
    draw();
    updateResults();
    if (!ok) {
      endContinuous("Stopped — objective error.", true);
      return;
    }
    if (evalsDone >= maxEvals) {
      // The eval count just echoes the input budget; only the elapsed time (when not pacing
      // frames) adds information.
      endContinuous(animating ? "Done." : "Done in " + computeMs.toFixed(1) + " ms.", true);
      return;
    }
    rafId = requestAnimationFrame(function () { tick(perFrame); });
  }

  function tryCompileAndValidate() {
    let compiled;
    let parsed;
    try {
      compiled = new Function("x", fnInput.value);
    } catch (e) {
      fnError.textContent = "Could not compile function: " + e.message;
      return null;
    }
    try {
      parsed = readBounds();
    } catch (e) {
      fnError.textContent = e.message;
      return null;
    }

    // Validate the objective once at the box center before committing.
    const center = parsed.bounds.map(function (b) { return (b[0] + b[1]) / 2; });
    try {
      const y0 = compiled(center);
      if (typeof y0 !== "number" || !isFinite(y0)) {
        throw new Error("returned " + y0 + " at the center (expected a finite number)");
      }
    } catch (e) {
      fnError.textContent = "Objective error: " + e.message;
      return null;
    }

    return {
      compiled: compiled,
      bounds: parsed.bounds,
      ints: parsed.ints,
      dims: parsed.bounds.length
    };
  }

  // Compile + validate the objective and bounds, (re)initialize the optimizer, and reset the run
  // state for a fresh session. Returns false (and shows the error) on any invalid input.
  function prepareRun() {
    // Clear the prior session's visualization up front so a validation error below can't leave a
    // stale result on screen attributed to the new inputs.
    fnError.textContent = "";
    resultsEl.innerHTML = "";
    legendEl.textContent = "";
    clearCanvas();

    const info = tryCompileAndValidate();
    if (!info) return false;

    objectiveFn = info.compiled;
    bounds = info.bounds;
    dims = info.dims;
    maxEvals = Math.max(1, parseInt(maxEvalsInput.value, 10) || 1);
    const seed = Math.max(0, parseInt(seedInput.value, 10) || 0);
    const samples = Math.max(1, parseInt(samplesInput.value, 10) || 1);

    const code = wasmInit(bounds, info.ints, parseInt(policySel.value, 10), seed, samples);
    if (code !== 0) {
      fnError.textContent = initErrorMessage(code);
      return false;
    }

    points = [];
    bestHistory = [];
    evalsDone = 0;
    computeMs = 0;
    evalError = null;
    view =
      dims === 2 ? { xlo: bounds[0][0], xhi: bounds[0][1], ylo: bounds[1][0], yhi: bounds[1][1] }
      : dims === 1 ? { xlo: bounds[0][0], xhi: bounds[0][1] }
      : null;
    prepared = true;
    surfaceBuilt = false;
    renderLegend();
    return true;
  }

  function drawPreview() {
    if (running) return;

    points = [];
    bestHistory = [];
    evalsDone = 0;
    prepared = false;
    surfaceBuilt = false;

    fnError.textContent = "";
    resultsEl.innerHTML = "";
    if (wasm) {
      statusEl.textContent = "Ready.";
    }

    const info = tryCompileAndValidate();
    if (!info) {
      clearCanvas();
      return;
    }

    objectiveFn = info.compiled;
    bounds = info.bounds;
    dims = info.dims;
    view =
      dims === 2 ? { xlo: bounds[0][0], xhi: bounds[0][1], ylo: bounds[1][0], yhi: bounds[1][1] }
      : dims === 1 ? { xlo: bounds[0][0], xhi: bounds[0][1] }
      : null;

    renderLegend();
    ensureSurface();
  }

  // Build + draw the static background (heatmap / curve / blank) once per session.
  function ensureSurface() {
    if (surfaceBuilt) return;
    if (dims === 2) {
      buildHeatmap();
      ctx.putImageData(heatmap, 0, 0);
    } else if (dims === 1) {
      build1DCurve();
      draw1DView();
    } else {
      clearCanvas();
    }
    surfaceBuilt = true;
  }

  // A fresh session is needed when none is prepared or the previous one spent its whole budget.
  function ensureSession() {
    if (!prepared || evalsDone >= maxEvals) return prepareRun();
    return true;
  }

  // Primary button: start/resume the continuous auto-run, or stop it if already running.
  function onOptimize() {
    if (running) {
      endContinuous("Stopped.", false);
      return;
    }
    if (!ensureSession()) return;
    animating = animateChk.checked;
    // "Animate" just controls how many evals are batched per frame: a few for a visible search, a
    // big chunk (~4 frames total) to finish fast without freezing the tab.
    const perFrame = animating
      ? Math.max(1, Math.ceil(maxEvals / 240))
      : Math.max(1, Math.ceil(maxEvals / 4));
    setRunning(true);
    // Defer one frame so the status (and the possibly-heavy surface build) paints before ticking.
    if (!surfaceBuilt) {
      statusEl.textContent = dims === 2 ? "Rendering surface…" : dims === 1 ? "Rendering curve…" : "Optimizing…";
    } else {
      statusEl.textContent = "Optimizing…";
    }
    rafId = requestAnimationFrame(function () {
      if (!running) return;
      ensureSurface();
      statusEl.textContent = "Optimizing…";
      rafId = requestAnimationFrame(function () { tick(perFrame); });
    });
  }

  // Secondary button: advance the session exactly one evaluation.
  function onStep() {
    if (running) return;
    if (!ensureSession()) return;
    ensureSurface();
    if (!doStep()) {
      prepared = false; // doStep already populated fnError
      statusEl.textContent = "Stopped — objective error.";
      return;
    }
    draw();
    updateResults();
    if (evalsDone >= maxEvals) {
      prepared = false;
      statusEl.textContent = "Done.";
    } else {
      statusEl.textContent = "Step " + evalsDone + " / " + maxEvals;
    }
  }

  function init() {
    populatePresets();
    presetSel.addEventListener("change", function () {
      if (presetSel.value !== "custom") applyPreset(parseInt(presetSel.value, 10));
      invalidateSession();
      drawPreview();
    });
    // Hand-editing the objective no longer matches a named preset.
    fnInput.addEventListener("input", function () {
      presetSel.value = "custom";
      expectedEl.textContent = "";
      invalidateSession();
    });
    fnInput.addEventListener("change", function () {
      drawPreview();
    });
    // Any settings or bounds edit starts a fresh session on the next Optimize/Step.
    [policySel, maxEvalsInput, seedInput, samplesInput].forEach(function (el) {
      el.addEventListener("change", invalidateSession);
    });
    boundsBody.addEventListener("input", invalidateSession);
    boundsBody.addEventListener("change", function () {
      invalidateSession();
      drawPreview();
    });
    presetSel.value = "0";
    applyPreset(0);
    drawPreview();
    addVarBtn.addEventListener("click", function () {
      addVariable(-5, 5, false);
      invalidateSession();
      drawPreview();
    });
    // Changing the colormap only recolors the 2-D surface (the cached field is reused, not resampled).
    colormapSel.addEventListener("change", function () {
      colormapId = parseInt(colormapSel.value, 10);
      loadColormapLut();
      surfaceBuilt = false;
      if (dims === 2 && view) {
        ensureSurface();
        draw();
      }
    });
    runBtn.addEventListener("click", onOptimize);
    stepBtn.addEventListener("click", onStep);
  }

  loadWasm("global_optimization.wasm", { evaluate: evaluate }).then(function (api) {
    wasm = api.exports;
    decodeString = api.decodeString;
    console.log("wasm loaded");
    loadColormapLut();
    // Recolor the init() preview (built with the grayscale fallback) now that the real LUT is loaded.
    if (dims === 2 && view) {
      heatmap = null;
      surfaceBuilt = false;
      ensureSurface();
      draw();
    }
    runBtn.disabled = false;
    stepBtn.disabled = false;
    statusEl.textContent = "Ready.";
  });

  init();
})();
