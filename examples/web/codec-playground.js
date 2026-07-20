(function () {
  const { createFileInput, enableDrop, loadWasm } = window.ZignalUtils;

  let exports = null;
  let decodeString = null;
  let currentFormat = "jpeg";
  let encodedFormat = null;
  let sourceLoaded = false;
  let sourceName = "image";
  let sourceSize = 0;
  let downloadUrl = null;
  let debounceTimer = null;
  // Infinity so the very first encode (unknown cost) shows the status.
  let lastEncodeMs = Infinity;

  const FORMATS = ["jpeg", "png", "bmp", "gif"];
  const MIME = { jpeg: "image/jpeg", png: "image/png", bmp: "image/bmp", gif: "image/gif" };
  const EXT = { jpeg: "jpg", png: "png", bmp: "bmp", gif: "gif" };
  const SUBSAMPLING = { yuv444: "4:4:4", yuv422: "4:2:2", yuv420: "4:2:0" };
  const textEncoder = new TextEncoder();

  const DETAIL_LABELS = {
    frame_type: "Frame type",
    num_components: "Components",
    precision: "Precision (bits)",
    subsampling: "Chroma subsampling",
    bit_depth: "Bit depth",
    color_type: "Color type",
    interlaced: "Interlaced (Adam7)",
    gamma: "Gamma",
    srgb_intent: "sRGB intent",
    compression: "Compression",
    dib_header: "DIB header",
    top_down: "Top-down rows",
    palette_entries: "Palette entries",
    has_alpha: "Alpha channel",
    version: "Version",
    frame_count: "Frames",
    loop_count: "Loop count",
    global_color_table_size: "Global palette size",
  };

  const sourceCanvas = document.getElementById("source-canvas");
  const outputCanvas = document.getElementById("output-canvas");
  const sourceInfoEl = document.getElementById("source-info");
  const outputInfoEl = document.getElementById("output-info");
  const outputStats = document.getElementById("output-stats");
  const statusEl = document.getElementById("status");
  const downloadButton = document.getElementById("download-button");
  const grayCheckbox = document.getElementById("opt-gray");
  const jpegQuality = document.getElementById("jpeg-quality");
  const jpegSubsampling = document.getElementById("jpeg-subsampling");
  const jpegDpi = document.getElementById("jpeg-dpi");
  const jpegComment = document.getElementById("jpeg-comment");
  const pngFilter = document.getElementById("png-filter");
  const pngCompression = document.getElementById("png-compression");
  const pngGamma = document.getElementById("png-gamma");
  const pngIntent = document.getElementById("png-intent");
  const bmpPalette = document.getElementById("bmp-palette");
  const bmpTopdown = document.getElementById("bmp-topdown");
  const gifColors = document.getElementById("gif-colors");
  const gifDither = document.getElementById("gif-dither");

  const formatRadios = document.querySelectorAll('input[name="format"]');
  formatRadios.forEach(function (radio) {
    radio.addEventListener("change", function () {
      if (!radio.checked) return;
      currentFormat = radio.value;
      updateControls();
      scheduleEncode();
    });
  });

  document.querySelectorAll(".codec-options input, .codec-options select, .codec-gray input").forEach(function (el) {
    el.addEventListener(el.type === "range" || el.type === "text" || el.type === "number" ? "input" : "change", scheduleEncode);
  });

  jpegQuality.addEventListener("input", function () {
    document.getElementById("jpeg-quality-value").textContent = this.value;
  });
  gifColors.addEventListener("input", function () {
    document.getElementById("gif-colors-value").textContent = this.value;
  });
  grayCheckbox.addEventListener("change", updateControls);
  pngIntent.addEventListener("change", updateControls);

  // Only the selected codec's options are enabled; the per-option graying is
  // cosmetic — the encoders already ignore ineffective settings.
  function updateControls() {
    const gray = grayCheckbox.checked;
    FORMATS.forEach(function (f) {
      const panel = document.getElementById("options-" + f);
      const active = f === currentFormat;
      panel.classList.toggle("inactive", !active);
      panel.querySelectorAll("input, select").forEach(function (el) {
        el.disabled = !sourceLoaded || !active;
      });
    });
    formatRadios.forEach(function (radio) {
      radio.disabled = !sourceLoaded;
    });
    grayCheckbox.disabled = !sourceLoaded;
    bmpPalette.disabled = !sourceLoaded || currentFormat !== "bmp" || !gray;
    jpegSubsampling.disabled = !sourceLoaded || currentFormat !== "jpeg" || gray;
    pngGamma.disabled = !sourceLoaded || currentFormat !== "png" || pngIntent.value !== "-1";
  }
  updateControls();

  function setStatus(text, isError) {
    statusEl.textContent = text;
    statusEl.classList.toggle("error", !!isError);
  }

  function humanSize(n) {
    if (n < 1024) return n + " B";
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + " KB";
    return (n / (1024 * 1024)).toFixed(2) + " MB";
  }

  function renderInfo(container, info, extraRows = []) {
    const rows = [
      ["Format", info.format.toUpperCase()],
      ["Dimensions", info.width + "×" + info.height + " px"],
      ["File size", humanSize(info.file_size)],
    ];
    for (const key in info.details) {
      let value = info.details[key];
      if (value === null) value = "—";
      else if (typeof value === "boolean") value = value ? "yes" : "no";
      else if (key === "loop_count" && value === 0) value = "infinite";
      else if (key === "subsampling") value = SUBSAMPLING[value] || value;
      rows.push([DETAIL_LABELS[key] || key, String(value)]);
    }
    rows.push(...extraRows);
    const table = document.createElement("table");
    rows.forEach(function (row) {
      const tr = document.createElement("tr");
      row.forEach(function (cell) {
        const td = document.createElement("td");
        td.textContent = cell;
        tr.appendChild(td);
      });
      table.appendChild(tr);
    });
    container.replaceChildren(table);
  }

  function readJson() {
    return JSON.parse(decodeString(exports.json_ptr(), exports.json_len()));
  }

  // Fresh view per call (memory growth detaches buffers); no copy needed since
  // no wasm call happens before putImageData consumes it.
  function drawPixels(canvas, ptr, width, height) {
    canvas.width = width;
    canvas.height = height;
    const data = new Uint8ClampedArray(exports.memory.buffer, ptr, width * height * 4);
    canvas.getContext("2d").putImageData(new ImageData(data, width, height), 0, 0);
  }

  function clearCanvas(canvas) {
    canvas.width = 320;
    canvas.height = 200;
    canvas.getContext("2d").clearRect(0, 0, canvas.width, canvas.height);
  }

  // A failed load clears all state describing the previous file.
  function resetSource() {
    sourceLoaded = false;
    encodedFormat = null;
    sourceInfoEl.replaceChildren();
    outputInfoEl.replaceChildren();
    outputStats.textContent = "";
    clearCanvas(sourceCanvas);
    clearCanvas(outputCanvas);
    updateControls();
    downloadButton.disabled = true;
  }

  function loadFile(file) {
    if (!exports) {
      setStatus("WebAssembly module is still loading, try again.");
      return;
    }
    file.arrayBuffer().then(function (buffer) {
      const bytes = new Uint8Array(buffer);
      const ptr = exports.alloc(bytes.length);
      new Uint8Array(exports.memory.buffer, ptr, bytes.length).set(bytes);
      const ok = exports.load_image(ptr, bytes.length);
      exports.free(ptr, bytes.length);
      const result = readJson();
      if (!ok) {
        resetSource();
        setStatus(result.message || "Failed to load image: " + result.error, true);
        return;
      }
      sourceLoaded = true;
      sourceName = file.name.replace(/\.[^.]+$/, "") || "image";
      sourceSize = result.file_size;
      updateControls();
      drawPixels(sourceCanvas, exports.source_pixels(), exports.source_width(), exports.source_height());
      const extra = [
        ["Grayscale content", result.grayscale ? "yes" : "no"],
        ["Decode time", result.decode_ms.toFixed(1) + " ms"],
      ];
      if (result.details.frame_count > 1) {
        extra.push(["Note", "showing frame 1 of " + result.details.frame_count + "; re-encoding produces a single-frame image"]);
      }
      renderInfo(sourceInfoEl, result, extra);
      setStatus("");
      scheduleEncode();
    }).catch(function (error) {
      resetSource();
      setStatus("Failed to read file: " + error, true);
    });
  }

  function scheduleEncode() {
    if (!sourceLoaded) return;
    clearTimeout(debounceTimer);
    debounceTimer = setTimeout(function () {
      // Skip the status flash when the last encode was fast.
      if (lastEncodeMs < 100) return runEncode();
      setStatus("Encoding…");
      // Give the status a frame to paint before the synchronous wasm call.
      requestAnimationFrame(function () {
        setTimeout(runEncode, 0);
      });
    }, 200);
  }

  function runEncode() {
    if (!sourceLoaded || !exports) return;
    const started = performance.now();
    const asGray = grayCheckbox.checked ? 1 : 0;
    const format = currentFormat;
    let ok;
    if (format === "jpeg") {
      const comment = textEncoder.encode(jpegComment.value);
      let commentPtr = 0;
      if (comment.length > 0) {
        commentPtr = exports.alloc(comment.length);
        new Uint8Array(exports.memory.buffer, commentPtr, comment.length).set(comment);
      }
      ok = exports.encode_jpeg(asGray, Number(jpegQuality.value), Number(jpegSubsampling.value), Number(jpegDpi.value) || 72, commentPtr, comment.length);
      if (comment.length > 0) exports.free(commentPtr, comment.length);
    } else if (format === "png") {
      const gamma = parseFloat(pngGamma.value);
      ok = exports.encode_png(asGray, Number(pngFilter.value), Number(pngCompression.value), isNaN(gamma) ? 0 : gamma, Number(pngIntent.value));
    } else if (format === "bmp") {
      ok = exports.encode_bmp(asGray, bmpPalette.checked ? 1 : 0, bmpTopdown.checked ? 1 : 0);
    } else {
      ok = exports.encode_gif(asGray, Number(gifColors.value), gifDither.checked ? 1 : 0);
    }
    const result = readJson();
    lastEncodeMs = performance.now() - started;
    if (!ok) {
      setStatus(result.message || "Encode failed: " + result.error, true);
      return;
    }
    encodedFormat = format;
    drawPixels(outputCanvas, exports.output_pixels(), exports.output_width(), exports.output_height());
    outputStats.textContent =
      humanSize(result.size) +
      " — " +
      Math.round((result.size / sourceSize) * 100) +
      "% of source (" +
      humanSize(sourceSize) +
      "), " +
      result.encode_ms.toFixed(1) +
      " ms";
    renderInfo(outputInfoEl, result.info);
    downloadButton.disabled = false;
    setStatus("");
  }

  // Encoded bytes stay valid until the next encode; read lazily instead of copying per re-encode.
  downloadButton.addEventListener("click", function () {
    if (!encodedFormat || exports.encoded_len() === 0) return;
    const bytes = new Uint8Array(exports.memory.buffer, exports.encoded_ptr(), exports.encoded_len());
    if (downloadUrl) URL.revokeObjectURL(downloadUrl);
    downloadUrl = URL.createObjectURL(new Blob([bytes], { type: MIME[encodedFormat] }));
    const link = document.createElement("a");
    link.href = downloadUrl;
    link.download = sourceName + "." + EXT[encodedFormat];
    link.click();
  });

  const fileInput = createFileInput(loadFile, { accept: ".png,.jpg,.jpeg,.bmp,.gif,image/*" });
  enableDrop(sourceCanvas, {
    onClick: function () {
      fileInput.click();
    },
    onDrop: loadFile,
  });

  loadWasm("codec_playground.wasm").then(function (loaded) {
    exports = loaded.exports;
    decodeString = loaded.decodeString;
    console.log("wasm loaded");
  });
})();
