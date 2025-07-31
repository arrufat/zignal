(function () {
  const canvasSrc = document.getElementById("canvas-src");
  const canvasRef = document.getElementById("canvas-ref");
  const canvasRes = document.getElementById("canvas-res");
  const ctxSrc = canvasSrc.getContext("2d", { willReadFrequently: true });
  const ctxRef = canvasRef.getContext("2d", { willReadFrequently: true });
  const ctxRes = canvasRes.getContext("2d", { willReadFrequently: true });
  const matchButton = document.getElementById("match-button");

  let srcImage = null;
  let refImage = null;
  let srcImageObj = null;
  let refImageObj = null;
  let wasm_exports = null;

  const text_decoder = new TextDecoder();

  function decodeString(ptr, len) {
    if (len === 0) return "";
    return text_decoder.decode(new Uint8Array(wasm_exports.memory.buffer, ptr, len));
  }

  // Removed resizeCanvases function - using CSS scaling instead

  function displayImage(canvas, ctx, file, isSource) {
    const reader = new FileReader();
    reader.onload = function (e) {
      const img = new Image();
      img.onload = function () {
        // Limit image size to max 2048 on longest side
        const maxSize = 2048;
        let width = img.width;
        let height = img.height;
        let wasResized = false;

        if (width > maxSize || height > maxSize) {
          const scale = Math.min(maxSize / width, maxSize / height);
          width = Math.floor(width * scale);
          height = Math.floor(height * scale);
          wasResized = true;
          console.log(`Image resized from ${img.width}x${img.height} to ${width}x${height}`);
        }

        if (isSource) {
          srcImageObj = img;
          srcImage = file;
        } else {
          refImageObj = img;
          refImage = file;
        }

        // Set canvas to resized dimensions
        canvas.width = width;
        canvas.height = height;

        // Draw resized image
        ctx.drawImage(img, 0, 0, width, height);
      };
      img.src = e.target.result;
    };
    reader.readAsDataURL(file);
  }

  // File input for source image
  const fileInput1 = document.createElement("input");
  fileInput1.type = "file";
  fileInput1.style.display = "none";
  fileInput1.addEventListener("change", function (e) {
    const file = e.target.files[0];
    displayImage(canvasSrc, ctxSrc, file, true);
  });

  // File input for target image
  const fileInput2 = document.createElement("input");
  fileInput2.type = "file";
  fileInput2.style.display = "none";
  fileInput2.addEventListener("change", function (e) {
    const file = e.target.files[0];
    displayImage(canvasRef, ctxRef, file, false);
  });

  canvasSrc.addEventListener("click", function () {
    fileInput1.click();
  });

  canvasRef.addEventListener("click", function () {
    fileInput2.click();
  });

  // Drag and drop for source image
  canvasSrc.ondragover = function (event) {
    event.preventDefault();
  };

  canvasSrc.ondrop = function (event) {
    event.preventDefault();
    const file = event.dataTransfer.files[0];
    displayImage(canvasSrc, ctxSrc, file, true);
  };

  // Drag and drop for target image
  canvasRef.ondragover = function (event) {
    event.preventDefault();
  };

  canvasRef.ondrop = function (event) {
    event.preventDefault();
    const file = event.dataTransfer.files[0];
    displayImage(canvasRef, ctxRef, file, false);
  };

  matchButton.addEventListener("click", function () {
    if (!srcImage || !refImage) {
      alert("Please load both source and target images first");
      return;
    }

    const srcImageData = ctxSrc.getImageData(0, 0, canvasSrc.width, canvasSrc.height);
    const refImageData = ctxRef.getImageData(0, 0, canvasRef.width, canvasRef.height);

    const srcRows = canvasSrc.height;
    const srcCols = canvasSrc.width;
    const refRows = canvasRef.height;
    const refCols = canvasRef.width;

    const srcSize = srcRows * srcCols * 4;
    const refSize = refRows * refCols * 4;
    // FDM needs extra memory for matrix operations (must match Zig expectation)
    const extraSize = (srcRows * srcCols + refRows * refCols) * 8 * 50;

    // Allocate memory in WASM
    // Use >>> 0 to ensure pointers are treated as unsigned 32-bit integers
    const srcPtr = wasm_exports.alloc(srcSize) >>> 0;
    const refPtr = wasm_exports.alloc(refSize) >>> 0;
    const extraPtr = wasm_exports.alloc(extraSize) >>> 0;

    // Copy image data to WASM memory
    const srcArray = new Uint8ClampedArray(wasm_exports.memory.buffer, srcPtr, srcSize);
    const refArray = new Uint8ClampedArray(wasm_exports.memory.buffer, refPtr, refSize);

    srcArray.set(srcImageData.data);
    refArray.set(refImageData.data);

    const startTime = performance.now();

    // Call FDM function
    wasm_exports.fdm(srcPtr, srcRows, srcCols, refPtr, refRows, refCols, extraPtr, extraSize);

    const timeMs = performance.now() - startTime;
    document.getElementById("time").textContent = `time: ${timeMs.toFixed(0)} ms`;

    // Get result and display
    const resultArray = new Uint8ClampedArray(wasm_exports.memory.buffer, srcPtr, srcSize);
    const resultImageData = new ImageData(resultArray, srcCols, srcRows);

    canvasRes.width = srcCols;
    canvasRes.height = srcRows;
    ctxRes.putImageData(resultImageData, 0, 0);

    // Free memory
    wasm_exports.free(srcPtr, srcSize);
    wasm_exports.free(refPtr, refSize);
    wasm_exports.free(extraPtr, extraSize);
  });

  // Load WASM module
  fetch("fdm.wasm")
    .then((response) =>
      WebAssembly.instantiateStreaming(response, {
        js: {
          log: function (ptr, len) {
            const msg = decodeString(ptr, len);
            console.log(msg);
          },
          now: function () {
            return performance.now();
          },
        },
      }),
    )
    .then(function (obj) {
      window.wasm = obj;
      wasm_exports = obj.instance.exports;
      matchButton.disabled = false;
    });
})();
