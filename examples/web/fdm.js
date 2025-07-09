(function () {
  const canvas1 = document.getElementById("canvas1");
  const canvas2 = document.getElementById("canvas2");
  const canvas3 = document.getElementById("canvas3");
  const ctx1 = canvas1.getContext("2d", { willReadFrequently: true });
  const ctx2 = canvas2.getContext("2d", { willReadFrequently: true });
  const ctx3 = canvas3.getContext("2d", { willReadFrequently: true });
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
        if (isSource) {
          srcImageObj = img;
          srcImage = file;
        } else {
          refImageObj = img;
          refImage = file;
        }

        // Set canvas to actual image dimensions
        canvas.width = img.width;
        canvas.height = img.height;
        ctx.drawImage(img, 0, 0);
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
    displayImage(canvas1, ctx1, file, true);
  });

  // File input for reference image
  const fileInput2 = document.createElement("input");
  fileInput2.type = "file";
  fileInput2.style.display = "none";
  fileInput2.addEventListener("change", function (e) {
    const file = e.target.files[0];
    displayImage(canvas2, ctx2, file, false);
  });

  canvas1.addEventListener("click", function () {
    fileInput1.click();
  });

  canvas2.addEventListener("click", function () {
    fileInput2.click();
  });

  // Drag and drop for source image
  canvas1.ondragover = function (event) {
    event.preventDefault();
  };

  canvas1.ondrop = function (event) {
    event.preventDefault();
    const file = event.dataTransfer.files[0];
    displayImage(canvas1, ctx1, file, true);
  };

  // Drag and drop for reference image
  canvas2.ondragover = function (event) {
    event.preventDefault();
  };

  canvas2.ondrop = function (event) {
    event.preventDefault();
    const file = event.dataTransfer.files[0];
    displayImage(canvas2, ctx2, file, false);
  };

  matchButton.addEventListener("click", function () {
    if (!srcImage || !refImage) {
      alert("Please load both source and reference images first");
      return;
    }

    const srcImageData = ctx1.getImageData(0, 0, canvas1.width, canvas1.height);
    const refImageData = ctx2.getImageData(0, 0, canvas2.width, canvas2.height);

    const srcRows = canvas1.height;
    const srcCols = canvas1.width;
    const refRows = canvas2.height;
    const refCols = canvas2.width;

    const srcSize = srcRows * srcCols * 4;
    const refSize = refRows * refCols * 4;
    // FDM needs a lot of memory for matrix operations
    // SVD and other operations require significant temporary storage
    // Increase multiplier from 20x to 50x for larger images
    const extraSize = (srcRows * srcCols + refRows * refCols) * 8 * 50;

    // Allocate memory in WASM
    const srcPtr = wasm_exports.alloc(srcSize);
    const refPtr = wasm_exports.alloc(refSize);
    const outPtr = wasm_exports.alloc(srcSize);
    const extraPtr = wasm_exports.alloc(extraSize);

    // Copy image data to WASM memory
    const srcArray = new Uint8ClampedArray(wasm_exports.memory.buffer, srcPtr, srcSize);
    const refArray = new Uint8ClampedArray(wasm_exports.memory.buffer, refPtr, refSize);

    srcArray.set(srcImageData.data);
    refArray.set(refImageData.data);

    const startTime = performance.now();

    // Call FDM function
    wasm_exports.fdm(srcPtr, srcRows, srcCols, refPtr, refRows, refCols, outPtr, extraPtr, extraSize);

    const timeMs = performance.now() - startTime;
    document.getElementById("time").textContent = `time: ${timeMs.toFixed(0)} ms`;

    // Get result and display
    const outArray = new Uint8ClampedArray(wasm_exports.memory.buffer, outPtr, srcSize);
    const resultImageData = new ImageData(outArray, srcCols, srcRows);

    canvas3.width = srcCols;
    canvas3.height = srcRows;
    ctx3.putImageData(resultImageData, 0, 0);

    // Free memory
    wasm_exports.free(srcPtr, srcSize);
    wasm_exports.free(refPtr, refSize);
    wasm_exports.free(outPtr, srcSize);
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
