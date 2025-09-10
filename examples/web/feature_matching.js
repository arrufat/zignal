(function () {
  const upload1 = document.getElementById("upload1");
  const upload2 = document.getElementById("upload2");
  const preview1 = document.getElementById("preview1");
  const preview2 = document.getElementById("preview2");
  const file1 = document.getElementById("file1");
  const file2 = document.getElementById("file2");
  const matchButton = document.getElementById("match-button");
  const clearButton = document.getElementById("clear-button");
  const resultCanvas = document.getElementById("result-canvas");
  const ctx = resultCanvas.getContext("2d");

  let image1Data = null;
  let image2Data = null;
  let wasm_exports = null;

  const text_decoder = new TextDecoder();

  function decodeString(ptr, len) {
    if (len === 0) return "";
    return text_decoder.decode(new Uint8Array(wasm_exports.memory.buffer, ptr, len));
  }

  function loadImage(file, imageNum) {
    const reader = new FileReader();
    reader.onload = function (e) {
      const img = new Image();
      img.onload = function () {
        // Store preview
        const preview = imageNum === 1 ? preview1 : preview2;
        const upload = imageNum === 1 ? upload1 : upload2;
        preview.src = img.src;
        preview.style.display = "block";
        upload.classList.add("has-image");

        // Create canvas to get image data
        const canvas = document.createElement("canvas");
        const ctx = canvas.getContext("2d");
        
        // Limit size for performance
        const maxSize = 800;
        let width = img.width;
        let height = img.height;
        if (width > maxSize || height > maxSize) {
          const scale = Math.min(maxSize / width, maxSize / height);
          width = Math.floor(width * scale);
          height = Math.floor(height * scale);
        }
        
        canvas.width = width;
        canvas.height = height;
        ctx.drawImage(img, 0, 0, width, height);
        
        const imageData = ctx.getImageData(0, 0, width, height);
        if (imageNum === 1) {
          image1Data = { data: imageData, width, height };
        } else {
          image2Data = { data: imageData, width, height };
        }

        // Enable match button if both images loaded
        if (image1Data && image2Data && wasm_exports) {
          matchButton.disabled = false;
        }
      };
      img.src = e.target.result;
    };
    reader.readAsDataURL(file);
  }

  // Click handlers
  upload1.addEventListener("click", () => file1.click());
  upload2.addEventListener("click", () => file2.click());

  file1.addEventListener("change", (e) => {
    if (e.target.files[0]) loadImage(e.target.files[0], 1);
  });

  file2.addEventListener("change", (e) => {
    if (e.target.files[0]) loadImage(e.target.files[0], 2);
  });

  // Drag and drop
  function setupDragDrop(element, imageNum) {
    element.addEventListener("dragover", (e) => e.preventDefault());
    element.addEventListener("drop", (e) => {
      e.preventDefault();
      if (e.dataTransfer.files[0]) {
        loadImage(e.dataTransfer.files[0], imageNum);
      }
    });
  }

  setupDragDrop(upload1, 1);
  setupDragDrop(upload2, 2);

  // Clear button
  clearButton.addEventListener("click", () => {
    image1Data = null;
    image2Data = null;
    preview1.style.display = "none";
    preview2.style.display = "none";
    upload1.classList.remove("has-image");
    upload2.classList.remove("has-image");
    resultCanvas.classList.remove("visible");
    matchButton.disabled = true;
    
    document.getElementById("features1").textContent = "-";
    document.getElementById("features2").textContent = "-";
    document.getElementById("matches").textContent = "-";
    document.getElementById("avg-distance").textContent = "-";
    document.getElementById("time").textContent = "-";
  });

  // Match button
  matchButton.addEventListener("click", () => {
    const startTime = performance.now();

    // Calculate result dimensions (side by side with gap)
    const gap = 10;
    const resultWidth = image1Data.width + gap + image2Data.width;
    const resultHeight = Math.max(image1Data.height, image2Data.height);

    // Allocate memory for images
    const size1 = image1Data.height * image1Data.width * 4;
    const size2 = image2Data.height * image2Data.width * 4;
    const resultSize = resultHeight * resultWidth * 4;
    
    const img1Ptr = wasm_exports.alloc(size1) >>> 0;
    const img2Ptr = wasm_exports.alloc(size2) >>> 0;
    const resultPtr = wasm_exports.alloc(resultSize) >>> 0;

    // Allocate memory for stats
    const statsPtr = wasm_exports.alloc(6 * 4) >>> 0; // 6 floats

    // Copy image data to WASM
    const img1Array = new Uint8ClampedArray(wasm_exports.memory.buffer, img1Ptr, size1);
    const img2Array = new Uint8ClampedArray(wasm_exports.memory.buffer, img2Ptr, size2);
    img1Array.set(image1Data.data.data);
    img2Array.set(image2Data.data.data);

    // Call WASM to create visualization
    wasm_exports.matchAndVisualize(
      img1Ptr,
      image1Data.height,
      image1Data.width,
      img2Ptr,
      image2Data.height,
      image2Data.width,
      resultPtr,
      resultHeight,
      resultWidth
    );

    // Get result pixels
    const resultData = new Uint8ClampedArray(wasm_exports.memory.buffer, resultPtr, resultSize);
    
    // Display result
    resultCanvas.width = resultWidth;
    resultCanvas.height = resultHeight;
    const imageData = new ImageData(resultData, resultWidth, resultHeight);
    ctx.putImageData(imageData, 0, 0);
    resultCanvas.classList.add("visible");

    // Get statistics
    wasm_exports.getMatchStats(
      img1Ptr,
      image1Data.height,
      image1Data.width,
      img2Ptr,
      image2Data.height,
      image2Data.width,
      statsPtr
    );

    const stats = new Float32Array(wasm_exports.memory.buffer, statsPtr, 6);
    document.getElementById("features1").textContent = Math.floor(stats[0]);
    document.getElementById("features2").textContent = Math.floor(stats[1]);
    document.getElementById("matches").textContent = Math.floor(stats[2]);
    document.getElementById("avg-distance").textContent = stats[2] > 0 ? stats[3].toFixed(2) : "-";

    const timeMs = performance.now() - startTime;
    document.getElementById("time").textContent = timeMs.toFixed(0);

    // Free memory
    wasm_exports.free(img1Ptr, size1);
    wasm_exports.free(img2Ptr, size2);
    wasm_exports.free(resultPtr, resultSize);
    wasm_exports.free(statsPtr, 6 * 4);
  });

  // Load WASM
  fetch("feature_matching.wasm")
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
      })
    )
    .then((obj) => {
      wasm_exports = obj.instance.exports;
      console.log("WASM module loaded successfully");
      
      // Enable match button if images already loaded
      if (image1Data && image2Data) {
        matchButton.disabled = false;
      }
    })
    .catch((err) => {
      console.error("Failed to load WASM module:", err);
      alert("Failed to load WASM module. Check the console for details.");
    });
})();