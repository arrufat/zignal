(function () {
  const { createFileInput, enableDrop, createImageLoadHandler } = window.ZignalUtils;

  let wasmPromise = fetch("seam_carving.wasm");
  var wasmExports = null;
  const text_decoder = new TextDecoder();
  let image = null;
  let originalWidth = 0;
  let originalHeight = 0;
  let currentImageX = 0;
  let cleanImageData = null;
  let original = null;

  const removeButton = document.getElementById("remove-button");
  const canvas = document.getElementById("canvas-seam");
  const ctx = canvas.getContext("2d");
  const seamOverlay = document.getElementById("seam-overlay");

  // Disable button initially
  removeButton.disabled = true;

  function displayImageSize() {
    let sizeElement = document.getElementById("size");
    if (image) {
      sizeElement.textContent = "size: " + image.width + "×" + image.height + " px.";
    } else {
      sizeElement.textContent = "size: " + canvas.width + "×" + canvas.height + " px.";
    }
  }

  function clearSeamOverlay() {
    seamOverlay.innerHTML = "";
    seamOverlay.setAttribute("viewBox", `0 0 ${canvas.width} ${canvas.height}`);
  }

  function drawSeamOverlay(seam, offsetX) {
    clearSeamOverlay();

    const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
    let pathData = `M${seam[0] + offsetX},0`;

    for (let i = 1; i < seam.length; i++) {
      pathData += ` L${seam[i] + offsetX},${i}`;
    }

    path.setAttribute("d", pathData);
    path.setAttribute("stroke", "red");
    path.setAttribute("stroke-width", "1");
    path.setAttribute("fill", "none");
    seamOverlay.appendChild(path);
  }

  function displayImage(file) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = function (e) {
        const imageData = e.target.result;
        const img = document.createElement("img");
        img.onload = function () {
          originalWidth = img.width;
          originalHeight = img.height;
          canvas.width = originalWidth;
          canvas.height = originalHeight;
          currentImageX = 0;
          ctx.drawImage(img, 0, 0);
          image = ctx.getImageData(0, 0, canvas.width, canvas.height);
          cleanImageData = new ImageData(image.width, image.height);
          cleanImageData.data.set(image.data);
          original = new ImageData(image.width, image.height);
          original.data.set(image.data);
          clearSeamOverlay();
          displayImageSize();
          resolve();
        };
        img.onerror = function () {
          reject(new Error("Failed to decode image."));
        };
        img.src = imageData;
      };
      reader.onerror = function () {
        reject(new Error("Failed to read file."));
      };
      reader.readAsDataURL(file);
    });
  }

  const handleImageFile = createImageLoadHandler({
    load: displayImage,
    setLoaded: function (loaded) {
      removeButton.disabled = !loaded;
    },
    onError: function (error) {
      console.error(error);
      removeButton.disabled = image == null;
    },
  });

  const fileInput = createFileInput(handleImageFile);

  enableDrop(canvas, {
    onClick: function () {
      fileInput.click();
    },
    onDrop: handleImageFile,
  });

  function decodeString(ptr, len) {
    if (len === 0) return "";
    return text_decoder.decode(new Uint8Array(wasmExports.memory.buffer, ptr, len));
  }

  WebAssembly.instantiateStreaming(wasmPromise, {
    js: {
      log: function (ptr, len) {
        const msg = decodeString(ptr, len);
        console.log(msg);
      },
      now: function () {
        return performance.now();
      },
    },
  }).then(function (obj) {
    wasmExports = obj.instance.exports;
    window.wasm = obj;
    console.log("wasm loaded");

    function seamCarve() {
      // Clear all previous seams at the start
      clearSeamOverlay();

      const rows = cleanImageData.height;
      const cols = cleanImageData.width;
      const rgbaSize = rows * cols * 4;
      const rgbaPtr = wasmExports.alloc(rgbaSize);
      const seamSize = rows * 4;
      const seamPtr = wasmExports.alloc(seamSize);
      const extraSize = rows * cols * 15;
      const extraPtr = wasmExports.alloc(extraSize);
      var rgba = new Uint8ClampedArray(wasmExports.memory.buffer, rgbaPtr, rgbaSize);
      var seam = new Uint32Array(wasmExports.memory.buffer, seamPtr, cleanImageData.height);

      // Use clean image data (no seam lines)
      rgba.set(cleanImageData.data);

      wasmExports.seam_carve(rgbaPtr, rows, cols, extraPtr, extraSize, seamPtr, rows);

      // Recreate views after potential memory growth
      rgba = new Uint8ClampedArray(wasmExports.memory.buffer, rgbaPtr, rgbaSize);
      seam = new Uint32Array(wasmExports.memory.buffer, seamPtr, cleanImageData.height);

      // Create new clean image data after seam removal
      const newWidth = cols - 1;
      const newCleanImageData = new ImageData(newWidth, rows);
      const newRgba = new Uint8ClampedArray(wasmExports.memory.buffer, rgbaPtr, newWidth * rows * 4);
      newCleanImageData.data.set(newRgba);

      // Clear canvas and center the new image
      ctx.clearRect(0, 0, originalWidth, originalHeight);
      const newOffsetX = Math.floor((originalWidth - newWidth) / 2);
      ctx.putImageData(newCleanImageData, newOffsetX, 0);

      // Draw seam overlay using SVG (doesn't modify canvas pixels)
      drawSeamOverlay(seam, currentImageX);

      // Update tracking variables for next iteration
      currentImageX = newOffsetX;
      cleanImageData = newCleanImageData;
      image = newCleanImageData;
      displayImageSize();

      wasmExports.free(rgbaPtr, rgbaSize);
      wasmExports.free(extraPtr, extraSize);
    }
    removeButton.addEventListener("click", () => {
      seamCarve();
    });
  });
})();
