(function () {
  const { createFileInput, enableDrop, createRadioGroup, loadWasm } = window.ZignalUtils;

  const SIZE = 256;
  const BYTES = SIZE * SIZE * 4;

  // The six Porter-Duff weights, keyed by how the formula is written.
  const FACTOR = {
    "0": () => 0,
    "1": () => 1,
    "αs": (sa) => sa,
    "1 − αs": (sa) => 1 - sa,
    "αb": (sa, da) => da,
    "1 − αb": (sa, da) => 1 - da,
  };

  // Porter-Duff operators: out = Fa·(αs·Cs) + Fb·(αb·Cb), in premultiplied color.
  const COMPOSITING = {
    clear: { fa: "0", fb: "0", desc: "Erases everything. The result is fully transparent." },
    src: { fa: "1", fb: "0", desc: "Keeps only the overlay. The base is thrown away, even where the overlay is transparent." },
    dst: { fa: "0", fb: "1", desc: "Keeps only the base. The overlay is ignored." },
    src_over: { fa: "1", fb: "1 − αs",
      desc: "Places the overlay on top of the base. This is ordinary alpha compositing, what you get when you stack layers.",
      tip: "Lower the overlay opacity: the base shows through in proportion to 1 − αs." },
    dst_over: { fa: "1 − αb", fb: "1",
      desc: "Keeps the base on top. The overlay only shows where the base is transparent, as if it were drawn behind." },
    src_in: { fa: "αb", fb: "0",
      desc: "The overlay, but only where the base is. The base works as a mask and its color is discarded.",
      tip: "Use a photo as the overlay to fill the disc with it." },
    dst_in: { fa: "0", fb: "αs",
      desc: "The base, but only where the overlay is. The overlay works as a mask.",
      tip: "Pick the Glow overlay: it becomes a soft vignette mask for the base." },
    src_out: { fa: "1 − αb", fb: "0", desc: "The overlay where the base is not: the base's shape is cut out of the overlay." },
    dst_out: { fa: "0", fb: "1 − αs",
      desc: "The base where the overlay is not: the overlay erases the base, like an eraser brush.",
      tip: "Pick the Glow overlay to see a soft eraser." },
    src_atop: { fa: "αb", fb: "1 − αs",
      desc: "The overlay drawn on top of the base but clipped to it, so the result keeps the base's shape. Useful for shading or texturing a shape." },
    dst_atop: { fa: "1 − αb", fb: "αs", desc: "The base drawn on top of the overlay, clipped to the overlay's shape." },
    xor: { fa: "1 − αb", fb: "1 − αs", desc: "Each image where the other is not. Where both are opaque, nothing is left." },
    plus: { fa: "1", fb: "1", capped: true,
      desc: "Adds premultiplied colors and alphas, capped at 1. Overlaps get brighter, like light from two projectors." },
  };

  // Blend functions B(Cb, Cs) on channels in [0, 1], as written in src/blending.zig.
  const BLENDING = {
    none: { formula: "result = overlay pixel",
      desc: "No blending: the overlay pixel replaces the base pixel outright, alpha included. It is the default for Image.insert and Canvas drawing." },
    normal: { formula: "B = Cs", desc: "The overlay color as is. Only its alpha mixes it with the base.",
      tip: "Same as the src_over compositing operator." },
    multiply: { formula: "B = Cb · Cs",
      desc: "Multiplies the channels, like stacking two slides on a light table. White leaves the base unchanged and black gives black; the result is never lighter." },
    screen: { formula: "B = Cb + Cs − Cb · Cs = 1 − (1 − Cb)(1 − Cs)",
      desc: "The inverse of multiply, like projecting two slides on the same screen. Black leaves the base unchanged; the result is never darker." },
    overlay: { formula: "B = Cb < ½ ? 2·Cb·Cs : 1 − 2·(1 − Cb)(1 − Cs)",
      desc: "Multiply in the base's shadows, screen in its highlights. It boosts contrast while keeping the base's light and dark areas." },
    soft_light: { formula: "B = Cs ≤ ½ ? Cb − (1 − 2·Cs)·Cb·(1 − Cb) : Cb + (2·Cs − 1)(√Cb − Cb)",
      desc: "A gentle overlay driven by the overlay color: dark overlays darken slightly, light ones lighten slightly, and 50% gray does nothing." },
    hard_light: { formula: "B = Cs < ½ ? 2·Cs·Cb : 1 − 2·(1 − Cs)(1 − Cb)",
      desc: "Overlay with the roles swapped: the overlay decides between multiply and screen, like a harsh spotlight." },
    color_dodge: { formula: "B = Cb = 0 ? 0 : Cs = 1 ? 1 : min(1, Cb / (1 − Cs))",
      desc: "Brightens the base by dividing it by the inverted overlay. Bright overlays blow the highlights out." },
    color_burn: { formula: "B = Cb = 1 ? 1 : Cs = 0 ? 0 : max(0, 1 − (1 − Cb) / Cs)",
      desc: "Darkens the base by dividing its inverse by the overlay. Dark overlays crush the shadows." },
    darken: { formula: "B = min(Cb, Cs)", desc: "Keeps the darker value of each channel separately, so it can mix channels of both colors." },
    lighten: { formula: "B = max(Cb, Cs)", desc: "Keeps the lighter value of each channel separately." },
    difference: { formula: "B = |Cb − Cs|", desc: "Identical colors give black, so it is handy for spotting where two images differ." },
    exclusion: { formula: "B = Cb + Cs − 2·Cb·Cs", desc: "Like difference with lower contrast: 50% gray stays 50% gray." },
  };

  // Each family keeps its own layer choice and selected variant.
  const FAMILIES = {
    blend: { title: "Blend modes", type: "Blending", pixels: "any pixel type", table: BLENDING,
      base: "oklch", overlay: "ramp", selected: "multiply" },
    composite: { title: "Compositing operators", type: "Compositing", pixels: "Image(Rgba)", table: COMPOSITING,
      base: "disc", overlay: "square", selected: "src_atop" },
  };

  const PRESETS = {
    base: { disc: "Orange disc", oklch: "Oklch hue sweep", hue: "HSV hue sweep" },
    overlay: { square: "Blue square", ramp: "Gray ramp", glow: "Yellow glow" },
  };

  // Why a preset is useful, shown under its layer.
  const PRESET_NOTES = {
    oklch: "Fixed Oklch lightness and chroma: only the hue changes, so columns differ by hue alone.",
    hue: "Full-saturation HSV: lightness jumps (yellow is bright, blue is dark) along with the hue.",
    ramp: "Each row is one overlay value Cs, from white at the top to black at the bottom.",
  };

  function drawPreset(ctx, name) {
    ctx.clearRect(0, 0, SIZE, SIZE);
    if (name === "disc") {
      ctx.fillStyle = "#f07020";
      ctx.beginPath();
      ctx.arc(105, 105, 78, 0, 2 * Math.PI);
      ctx.fill();
      return;
    }
    if (name === "square") {
      ctx.fillStyle = "#2060e0";
      ctx.fillRect(110, 110, 120, 120);
      return;
    }
    let g;
    if (name === "hue") {
      g = ctx.createLinearGradient(0, 0, SIZE, 0);
      ["#ff0000", "#ffff00", "#00ff00", "#00ffff", "#0000ff", "#ff00ff", "#ff0000"].forEach((c, i) => g.addColorStop(i / 6, c));
    } else if (name === "ramp") {
      g = ctx.createLinearGradient(0, 0, 0, SIZE);
      g.addColorStop(0, "#ffffff");
      g.addColorStop(1, "#000000");
    } else {
      g = ctx.createRadialGradient(150, 150, 0, 150, 150, 110);
      g.addColorStop(0, "rgba(255, 210, 60, 1)");
      g.addColorStop(1, "rgba(255, 210, 60, 0)");
    }
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, SIZE, SIZE);
  }

  const $ = (id) => document.getElementById(id);
  const els = {
    status: $("status"), gridTitle: $("grid-title"), grid: $("variant-grid"), resultName: $("result-name"),
    name: $("explain-name"), desc: $("explain-desc"), formula: $("explain-formula"), regions: $("regions"),
    blendMap: $("blend-map"), note: $("explain-note"), tip: $("explain-tip"), inspector: $("inspector"),
    code: $("code"), result: $("canvas-result"),
  };
  const inspectorHint = els.inspector.textContent;

  const layers = {};
  ["base", "overlay"].forEach((w) => {
    layers[w] = { canvas: $("canvas-" + w), select: $(w + "-preset"), opacity: $(w + "-opacity"),
      opacityValue: $(w + "-opacity-value"), note: $(w + "-note"), upload: null, pixels: null };
  });

  let wasm = null;
  let decodeString = null;
  let family = "blend";
  const names = {};
  const ptr = {};
  const resultPixels = new Uint8ClampedArray(BYTES);

  const scratch = document.createElement("canvas");
  scratch.width = scratch.height = SIZE;
  const scratchCtx = scratch.getContext("2d", { willReadFrequently: true });

  const view = (p) => new Uint8ClampedArray(wasm.memory.buffer, p, BYTES);
  const imageAt = (p) => new ImageData(view(p), SIZE, SIZE);

  // Canvas gradients only interpolate in sRGB, so the colorspaces demo's zignal module converts
  // one Oklch row (fixed lightness and chroma, in gamut for every hue); it is stretched to the layer.
  const oklchSweep = document.createElement("canvas");
  async function buildOklchSweep() {
    const colors = (await loadWasm("colorspaces.wasm")).exports;
    const rgb = colors.alloc(3);
    const row = new ImageData(SIZE, 1);
    for (let x = 0; x < SIZE; x++) {
      colors.oklch2rgb(0.75, 0.12, (360 * x) / SIZE, rgb);
      row.data.set(new Uint8Array(colors.memory.buffer, rgb, 3), x * 4);
      row.data[x * 4 + 3] = 255;
    }
    oklchSweep.width = SIZE;
    oklchSweep.height = 1;
    oklchSweep.getContext("2d").putImageData(row, 0, 0);
  }

  function readNames(p) {
    return decodeString(p, new Uint8Array(wasm.memory.buffer, p).indexOf(0)).split(" ");
  }

  // Renders a layer's preset (or upload), applies its opacity, and stores the pixels.
  function renderLayer(which) {
    const layer = layers[which];
    if (layer.select.value === "upload") {
      scratchCtx.clearRect(0, 0, SIZE, SIZE);
      scratchCtx.drawImage(layer.upload, 0, 0);
    } else if (layer.select.value === "oklch") {
      scratchCtx.drawImage(oklchSweep, 0, 0, SIZE, SIZE);
    } else {
      drawPreset(scratchCtx, layer.select.value);
    }
    const data = scratchCtx.getImageData(0, 0, SIZE, SIZE);
    const opacity = layer.opacity.value / 100;
    for (let i = 3; i < data.data.length; i += 4) data.data[i] = Math.round(data.data[i] * opacity);
    layer.canvas.getContext("2d").putImageData(data, 0, 0);
    layer.pixels = data.data;
    layer.opacityValue.textContent = layer.opacity.value + "%";
    layer.note.textContent = PRESET_NOTES[layer.select.value] ?? "";
  }

  function runVariant(index) {
    wasm[family](ptr.base, ptr.overlay, ptr.out, SIZE, SIZE, index);
  }

  function showSelected() {
    runVariant(names[family].indexOf(FAMILIES[family].selected));
    resultPixels.set(view(ptr.out));
    els.result.getContext("2d").putImageData(imageAt(ptr.out), 0, 0);
  }

  // Runs every variant on the current layers for the thumbnails, then the selected one.
  function update() {
    view(ptr.base).set(layers.base.pixels);
    view(ptr.overlay).set(layers.overlay.pixels);
    els.grid.querySelectorAll("canvas").forEach((canvas, i) => {
      runVariant(i);
      canvas.getContext("2d").putImageData(imageAt(ptr.out), 0, 0);
    });
    showSelected();
  }

  function buildGrid() {
    const fam = FAMILIES[family];
    els.gridTitle.textContent = "All " + names[family].length + " " + fam.title.toLowerCase() + " at once. Click one to inspect it.";
    els.grid.replaceChildren(...names[family].map((name) => {
      const card = document.createElement("button");
      card.type = "button";
      card.className = "copy-button variant" + (name === fam.selected ? " selected" : "");
      const canvas = document.createElement("canvas");
      canvas.width = canvas.height = SIZE;
      canvas.className = "checker";
      const label = document.createElement("span");
      label.textContent = name;
      card.append(canvas, label);
      card.addEventListener("click", () => {
        fam.selected = name;
        els.grid.querySelectorAll(".variant").forEach((v) => v.classList.toggle("selected", v === card));
        explain();
        showSelected();
      });
      return card;
    }));
  }

  // A swatch for what one region of two opaque shapes shows.
  function chip(label, overlay, base) {
    const fill = overlay && base ? "linear-gradient(135deg, #2060e0 50%, #f07020 50%)" : overlay ? "#2060e0" : base ? "#f07020" : "transparent";
    const text = overlay && base ? "overlay + base" : overlay ? "overlay" : base ? "base" : "nothing";
    return '<div class="region"><span class="region-chip checker"><span style="background:' + fill + '"></span></span>' +
      "<strong>" + label + "</strong>" + text + "</div>";
  }

  function explain() {
    const fam = FAMILIES[family];
    const name = fam.selected;
    const entry = fam.table[name];
    els.resultName.textContent = name;
    els.name.textContent = name;
    els.desc.textContent = entry.desc;
    els.inspector.textContent = inspectorHint;
    els.tip.textContent = entry.tip ? "Try it: " + entry.tip : "";
    els.regions.hidden = family !== "composite";
    els.blendMap.hidden = family !== "blend" || name === "none";
    if (family === "composite") {
      const fa = FACTOR[entry.fa];
      const fb = FACTOR[entry.fb];
      els.formula.innerHTML = "Fa = " + entry.fa + "<br>Fb = " + entry.fb +
        "<br>αo = Fa·αs + Fb·αb<br>Co·αo = Fa·αs·Cs + Fb·αb·Cb" + (entry.capped ? "<br>(both capped at 1)" : "");
      els.regions.querySelector(".regions").innerHTML =
        chip("Overlay only", fa(1, 0) > 0, false) + chip("Overlap", fa(1, 1) > 0, fb(1, 1) > 0) + chip("Base only", false, fb(0, 1) > 0);
      els.note.textContent = "Operators never mix colors: they only weight each layer by the other's coverage. Fa and Fb are those weights.";
    } else {
      els.formula.innerHTML = entry.formula + (name === "none" ? "" : "<br>αo = αs + αb·(1 − αs)<br>Co = (αs·B + αb·(1 − αs)·Cb) / αo");
      els.note.textContent = name === "none" ? "" :
        "Each map pixel is B(Cb, Cs) for one pair of gray levels. Blend modes only decide the color; the result's coverage is always source-over, so they all share the same alpha.";
      if (name !== "none") {
        wasm.blendMap(ptr.map, SIZE, names.blend.indexOf(name));
        els.blendMap.querySelector("canvas").getContext("2d").putImageData(imageAt(ptr.map), 0, 0);
      }
    }
    els.code.textContent =
      "// Zig: whole image, in place (" + fam.pixels + ")\n" +
      "base." + family + "(overlay, ." + name + ");\n" +
      "// Zig: one color\n" +
      "const c = base_color." + family + "(overlay_color, ." + name + ");\n\n" +
      "# Python\n" +
      "base." + family + "(overlay, zignal." + fam.type + "." + name.toUpperCase() + ")";
  }

  const fmt = (v) => v.toFixed(2);
  const rgbaText = (p) => "(" + p.join(", ") + ")";
  const swatch = (p) => '<span class="swatch checker"><span style="background:rgba(' + p[0] + "," + p[1] + "," + p[2] + "," + p[3] / 255 + ')"></span></span>';
  const hex = (p) => (p[0] << 16) | (p[1] << 8) | p[2];

  function inspect(event) {
    const rect = els.result.getBoundingClientRect();
    const x = Math.min(SIZE - 1, Math.floor((event.clientX - rect.left) / rect.width * SIZE));
    const y = Math.min(SIZE - 1, Math.floor((event.clientY - rect.top) / rect.height * SIZE));
    const i = (y * SIZE + x) * 4;
    const at = (a) => Array.from(a.subarray(i, i + 4));
    const b = at(layers.base.pixels);
    const s = at(layers.overlay.pixels);
    const r = at(resultPixels);
    const sa = s[3] / 255;
    const da = b[3] / 255;
    const name = FAMILIES[family].selected;
    let math;
    if (family === "composite") {
      const op = COMPOSITING[name];
      const fa = FACTOR[op.fa](sa, da);
      const fb = FACTOR[op.fb](sa, da);
      math = "αs = " + fmt(sa) + ", αb = " + fmt(da) + "<br>Fa = " + op.fa + " = " + fmt(fa) + ", Fb = " + op.fb + " = " + fmt(fb) +
        "<br>αo = " + fmt(fa) + "·" + fmt(sa) + " + " + fmt(fb) + "·" + fmt(da) + " = " + fmt(Math.min(1, fa * sa + fb * da));
    } else if (name === "none") {
      math = "The overlay pixel is copied as is.";
    } else {
      const v = wasm.blendValue(hex(b), hex(s), names.blend.indexOf(name));
      math = "B(Cb, Cs) = " + rgbaText([(v >> 16) & 255, (v >> 8) & 255, v & 255]) + "<br>αs = " + fmt(sa) + ", αb = " + fmt(da) +
        "<br>αo = " + fmt(sa) + " + " + fmt(da) + "·(1 − " + fmt(sa) + ") = " + fmt(sa + da * (1 - sa)) +
        (sa === 0 ? "<br>The overlay is transparent here, so the base is kept." :
          da === 0 ? "<br>The base is transparent here, so the overlay is kept." : "");
    }
    els.inspector.innerHTML = '<div class="pixel-row">' + swatch(b) + "Base " + rgbaText(b) + "</div>" +
      '<div class="pixel-row">' + swatch(s) + "Overlay " + rgbaText(s) + "</div>" +
      '<div class="pixel-row">' + swatch(r) + "<strong>Result " + rgbaText(r) + "</strong></div>" +
      '<div class="formula">' + math + "</div>" +
      '<div class="note">pixel (' + x + ", " + y + "); colors are 0–255, alphas 0–1</div>";
  }

  function fillPresets(which) {
    const layer = layers[which];
    const options = Object.entries(PRESETS[which]);
    if (layer.upload) options.push(["upload", "Your image"]);
    layer.select.replaceChildren(...options.map(([value, label]) => new Option(label, value)));
    layer.select.value = FAMILIES[family][which];
  }

  function setFamily(next) {
    family = next;
    ["base", "overlay"].forEach((w) => {
      fillPresets(w);
      renderLayer(w);
    });
    buildGrid();
    explain();
    update();
  }

  async function loadUpload(which, file) {
    const bitmap = await createImageBitmap(file);
    // Cover-fit into the square, keeping the image's own transparency.
    const scale = Math.max(SIZE / bitmap.width, SIZE / bitmap.height);
    const w = bitmap.width * scale;
    const h = bitmap.height * scale;
    const canvas = document.createElement("canvas");
    canvas.width = canvas.height = SIZE;
    canvas.getContext("2d").drawImage(bitmap, (SIZE - w) / 2, (SIZE - h) / 2, w, h);
    layers[which].upload = canvas;
    FAMILIES[family][which] = "upload";
    fillPresets(which);
    renderLayer(which);
    update();
  }

  Object.entries(layers).forEach(([which, layer]) => {
    const onFile = (file) => loadUpload(which, file).catch(console.error);
    const input = createFileInput(onFile);
    enableDrop(layer.canvas, { onClick: () => input.click(), onDrop: onFile });
    layer.select.addEventListener("change", () => {
      FAMILIES[family][which] = layer.select.value;
      renderLayer(which);
      update();
    });
    layer.opacity.addEventListener("input", () => {
      renderLayer(which);
      update();
    });
  });

  els.result.addEventListener("mousemove", inspect);

  $("family-slot").appendChild(createRadioGroup({
    label: "Explore",
    name: "family",
    value: family,
    disabled: false,
    options: Object.entries(FAMILIES).map(([value, f]) => ({ value, label: f.title })),
    onChange: setFamily,
  }).element);

  Promise.all([loadWasm("blending_playground.wasm"), buildOklchSweep()]).then(([api]) => {
    wasm = api.exports;
    decodeString = api.decodeString;
    names.composite = readNames(wasm.compositingNames());
    names.blend = readNames(wasm.blendModeNames());
    const missing = names.composite.filter((n) => !COMPOSITING[n]).concat(names.blend.filter((n) => !BLENDING[n]));
    if (missing.length) console.warn("No description for:", missing);
    ["base", "overlay", "out", "map"].forEach((k) => (ptr[k] = wasm.alloc(BYTES)));
    setFamily(family);
    els.status.textContent = "";
  });
})();
