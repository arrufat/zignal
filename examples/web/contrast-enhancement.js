(function () {
  const { createFileInput, enableDrop, createImageLoadHandler } = window.ZignalUtils;

  const originalCanvas = document.getElementById("canvas-original");
  const processedCanvas = document.getElementById("canvas-processed");
  const ctxOriginal = originalCanvas.getContext("2d", { willReadFrequently: true });
  const ctxProcessed = processedCanvas.getContext("2d", { willReadFrequently: true });

  const cutoffRange = document.getElementById("cutoff-range");
  const cutoffValue = document.getElementById("cutoff-value");

  const sampleButton = document.getElementById("sample-button");
  const resetButton = document.getElementById("reset-button");
  const downloadButton = document.getElementById("download-button");
  const autocontrastButton = document.getElementById("autocontrast-button");
  const equalizeButton = document.getElementById("equalize-button");

  const statsOriginalEl = document.getElementById("stats-original");
  const statsProcessedEl = document.getElementById("stats-processed");
  const statusLine = document.getElementById("status");

  const textDecoder = new TextDecoder();
  let wasmExports = null;
  let wasmMemory = null;

  let width = 0;
  let height = 0;
  let originalPixels = null;
  let currentPixels = null;

  function updateStatus(message) {
    statusLine.textContent = message;
  }

  function clamp(value, min, max) {
    return Math.min(Math.max(value, min), max);
  }

  function updateCutoffLabel() {
    cutoffValue.textContent = `${Number(cutoffRange.value).toFixed(1)}%`;
  }

  function updateButtons() {
    const hasImage = currentPixels !== null && width > 0 && height > 0;
    const ready = hasImage && wasmExports !== null;

    autocontrastButton.disabled = !ready;
    equalizeButton.disabled = !ready;
    resetButton.disabled = !hasImage;
    downloadButton.disabled = !hasImage;
  }

  function computeStats(pixels) {
    if (!pixels || width === 0 || height === 0) return null;
    const pixelCount = width * height;
    const channels = [
      { label: "R", min: 255, max: 0, sum: 0 },
      { label: "G", min: 255, max: 0, sum: 0 },
      { label: "B", min: 255, max: 0, sum: 0 },
    ];
    const luma = { label: "Luma", min: 255, max: 0, sum: 0 };

    for (let i = 0; i < pixels.length; i += 4) {
      const r = pixels[i];
      const g = pixels[i + 1];
      const b = pixels[i + 2];

      channels[0].min = Math.min(channels[0].min, r);
      channels[0].max = Math.max(channels[0].max, r);
      channels[0].sum += r;

      channels[1].min = Math.min(channels[1].min, g);
      channels[1].max = Math.max(channels[1].max, g);
      channels[1].sum += g;

      channels[2].min = Math.min(channels[2].min, b);
      channels[2].max = Math.max(channels[2].max, b);
      channels[2].sum += b;

      const y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
      luma.min = Math.min(luma.min, y);
      luma.max = Math.max(luma.max, y);
      luma.sum += y;
    }

    channels.forEach((ch) => {
      ch.mean = ch.sum / pixelCount;
      ch.range = ch.max - ch.min;
    });
    luma.mean = luma.sum / pixelCount;
    luma.range = luma.max - luma.min;

    return { channels, luma };
  }

  function renderStats(stats, element) {
    const title = element.dataset.title ? `<h3>${element.dataset.title}</h3>` : "";
    if (!stats) {
      element.innerHTML = `${title}<div class="stat-row">Load an image to view statistics.</div>`;
      return;
    }
    const channelRows = stats.channels
      .map((ch) => {
        return `<div class="stat-row"><code>${ch.label}</code> min ${ch.min.toFixed(0)}, max ${ch.max.toFixed(
          0,
        )}, range ${ch.range.toFixed(0)}, mean ${ch.mean.toFixed(1)}</div>`;
      })
      .join("");

    const luma = stats.luma;
    const lumaRow = `<div class="stat-row"><code>${luma.label}</code> min ${luma.min.toFixed(1)}, max ${luma.max.toFixed(
      1,
    )}, range ${luma.range.toFixed(1)}, mean ${luma.mean.toFixed(1)}</div>`;

    element.innerHTML = `${title}${channelRows}${lumaRow}`;
  }

  function updateStats() {
    renderStats(computeStats(originalPixels), statsOriginalEl);
    renderStats(computeStats(currentPixels), statsProcessedEl);
  }

  function syncCanvases() {
    if (!currentPixels) return;
    ctxProcessed.putImageData(new ImageData(currentPixels, width, height), 0, 0);
  }

  function setImage(imageData) {
    width = imageData.width;
    height = imageData.height;
    originalPixels = new Uint8ClampedArray(imageData.data);
    currentPixels = new Uint8ClampedArray(imageData.data);

    originalCanvas.width = width;
    originalCanvas.height = height;
    ctxOriginal.putImageData(new ImageData(originalPixels, width, height), 0, 0);

    processedCanvas.width = width;
    processedCanvas.height = height;
    syncCanvases();

    updateStats();
    updateButtons();
    updateStatus(`Ready (${width}×${height}). Choose an operation.`);
  }

  function generateSample() {
    const sampleWidth = 512;
    const sampleHeight = 320;
    const canvas = document.createElement("canvas");
    canvas.width = sampleWidth;
    canvas.height = sampleHeight;
    const ctx = canvas.getContext("2d");
    const imageData = ctx.createImageData(sampleWidth, sampleHeight);
    const data = imageData.data;
    const cx = (sampleWidth - 1) / 2;
    const cy = (sampleHeight - 1) / 2;

    for (let y = 0; y < sampleHeight; y++) {
      for (let x = 0; x < sampleWidth; x++) {
        const dx = (x - cx) / sampleWidth;
        const dy = (y - cy) / sampleHeight;
        const radial = Math.sqrt(dx * dx + dy * dy);
        const base = 110 + 35 * Math.sin(x * 0.04) + 25 * Math.sin(y * 0.05);
        const vignette = 50 * radial;
        const wave = 15 * Math.sin((x + y) * 0.06);

        const r = clamp(base - vignette + wave + 8 * Math.sin(y * 0.11), 40, 210);
        const g = clamp(base - vignette - wave + 6 * Math.cos(x * 0.09), 35, 205);
        const b = clamp(base - vignette + 12 * Math.cos((x - y) * 0.07), 30, 200);

        const idx = (y * sampleWidth + x) * 4;
        data[idx] = r;
        data[idx + 1] = g;
        data[idx + 2] = b;
        data[idx + 3] = 255;
      }
    }
    setImage(imageData);
    updateStatus("Synthetic low-contrast sample generated.");
  }

  function loadImageFromFile(file) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = function (event) {
        const img = new Image();
        img.onload = function () {
          let targetWidth = img.width;
          let targetHeight = img.height;
          const maxDim = 2048;
          if (targetWidth > maxDim || targetHeight > maxDim) {
            const scale = Math.min(maxDim / targetWidth, maxDim / targetHeight);
            targetWidth = Math.round(targetWidth * scale);
            targetHeight = Math.round(targetHeight * scale);
          }
          const tempCanvas = document.createElement("canvas");
          tempCanvas.width = targetWidth;
          tempCanvas.height = targetHeight;
          const tempCtx = tempCanvas.getContext("2d");
          tempCtx.drawImage(img, 0, 0, targetWidth, targetHeight);
          const imageData = tempCtx.getImageData(0, 0, targetWidth, targetHeight);
          setImage(imageData);
          updateStatus(`Loaded ${file.name} (${targetWidth}×${targetHeight}).`);
          resolve();
        };
        img.onerror = function () {
          reject(new Error("Failed to decode image."));
        };
        img.src = event.target.result;
      };
      reader.onerror = function () {
        reject(new Error("Failed to read file."));
      };
      reader.readAsDataURL(file);
    });
  }

  function decodeString(ptr, len) {
    if (!wasmMemory || len === 0) return "";
    return textDecoder.decode(new Uint8Array(wasmMemory.buffer, ptr, len));
  }

  function runWithWasm(transform, sourcePixels) {
    if (!wasmExports || !(sourcePixels || currentPixels)) {
      updateStatus("Load an image first.");
      return;
    }
    const size = width * height * 4;
    const ptr = wasmExports.alloc(size) >>> 0;
    const wasmSlice = new Uint8ClampedArray(wasmMemory.buffer, ptr, size);
    const source = sourcePixels || currentPixels;
    wasmSlice.set(source);
    const start = performance.now();
    let success = false;
    try {
      transform(ptr);
      success = true;
    } catch (error) {
      console.error("Processing failed", error);
      updateStatus(error?.message ? `Processing failed: ${error.message}` : "Processing failed.");
    } finally {
      const elapsed = performance.now() - start;
      if (success) {
        currentPixels = new Uint8ClampedArray(wasmSlice);
        syncCanvases();
        updateStats();
        updateButtons();
        updateStatus(`Processed in ${elapsed.toFixed(1)} ms.`);
      }
      wasmExports.free(ptr, size);
    }
  }

  function applyAutocontrast() {
    if (!originalPixels) {
      updateStatus("Load or generate an image first.");
      return;
    }
    const cutoff = Number(cutoffRange.value) / 100;
    runWithWasm(
      function (ptr) {
        wasmExports.autocontrast_inplace(ptr, height, width, cutoff);
      },
      originalPixels,
    );
  }

  function applyEqualize() {
    if (!originalPixels) {
      updateStatus("Load or generate an image first.");
      return;
    }
    runWithWasm(
      function (ptr) {
        wasmExports.equalize_inplace(ptr, height, width);
      },
      originalPixels,
    );
  }

  function resetImage() {
    if (!originalPixels) return;
    currentPixels = new Uint8ClampedArray(originalPixels);
    syncCanvases();
    updateStats();
    updateButtons();
    updateStatus("Reset to original image.");
  }

  function downloadProcessed() {
    if (!currentPixels) return;
    const offscreen = document.createElement("canvas");
    offscreen.width = width;
    offscreen.height = height;
    const offCtx = offscreen.getContext("2d");
    offCtx.putImageData(new ImageData(currentPixels, width, height), 0, 0);
    const link = document.createElement("a");
    link.download = "contrast-enhanced.png";
    link.href = offscreen.toDataURL("image/png");
    link.click();
  }

  const handleFile = createImageLoadHandler({
    load: loadImageFromFile,
    setLoaded(loaded) {
      if (!loaded) updateStatus("Loading image…");
      updateButtons();
    },
    onError(error) {
      console.error(error);
      updateStatus(error.message);
    },
  });

  const fileInput = createFileInput(handleFile);
  enableDrop(originalCanvas, {
    onClick: function () {
      fileInput.click();
    },
    onDrop: handleFile,
  });

  cutoffRange.addEventListener("input", updateCutoffLabel);

  sampleButton.addEventListener("click", generateSample);
  resetButton.addEventListener("click", resetImage);
  downloadButton.addEventListener("click", downloadProcessed);
  autocontrastButton.addEventListener("click", applyAutocontrast);
  equalizeButton.addEventListener("click", applyEqualize);
  updateCutoffLabel();
  updateButtons();

  function instantiateWasm() {
    const imports = {
      js: {
        log: function (ptr, len) {
          const message = decodeString(ptr, len);
          if (message) console.log(message);
        },
        now: function () {
          return performance.now();
        },
      },
    };

    return WebAssembly.instantiateStreaming(fetch("contrast_enhancement.wasm"), imports).catch(function (error) {
      console.warn("Streaming instantiate failed, retrying with ArrayBuffer. Reason:", error);
      return fetch("contrast_enhancement.wasm")
        .then((response) => response.arrayBuffer())
        .then((buffer) => WebAssembly.instantiate(buffer, imports));
    });
  }

  instantiateWasm()
    .then(function (obj) {
      wasmExports = obj.instance.exports;
      wasmMemory = wasmExports.memory;
      window.zignalContrast = obj;
      updateStatus("WASM ready. Generate a sample or drop an image.");
      updateButtons();
    })
    .catch(function (error) {
      console.error("Failed to initialize WebAssembly", error);
      updateStatus("Failed to initialize WebAssembly module.");
    });
})();
