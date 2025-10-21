(function () {
  const { createFileInput, enableDrop, createImageLoadHandler } = window.ZignalUtils;

  const upload1 = document.getElementById("upload1");
  const upload2 = document.getElementById("upload2");
  const preview1 = document.getElementById("preview1");
  const preview2 = document.getElementById("preview2");
  const matchButton = document.getElementById("match-button");
  const clearButton = document.getElementById("clear-button");
  const toggleParamsButton = document.getElementById("toggle-params");
  const parametersDiv = document.getElementById("parameters");
  const resultCanvas = document.getElementById("result-canvas");
  const ctx = resultCanvas.getContext("2d");

  // Parameter controls
  const nFeaturesSlider = document.getElementById("n-features");
  const scaleFactorSlider = document.getElementById("scale-factor");
  const nLevelsSlider = document.getElementById("n-levels");
  const fastThresholdSlider = document.getElementById("fast-threshold");
  const maxDistanceSlider = document.getElementById("max-distance");
  const ratioThresholdSlider = document.getElementById("ratio-threshold");
  const crossCheckCheckbox = document.getElementById("cross-check");

  let image1Data = null;
  let image2Data = null;
  let wasm_exports = null;
  let image1Ready = false;
  let image2Ready = false;

  const text_decoder = new TextDecoder();

  function decodeString(ptr, len) {
    if (len === 0) return "";
    return text_decoder.decode(new Uint8Array(wasm_exports.memory.buffer, ptr, len));
  }

  function updateMatchButton() {
    matchButton.disabled = !(image1Ready && image2Ready && wasm_exports);
  }

  function loadImage(file, imageNum) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = function (e) {
        const img = new Image();
        img.onload = function () {
          const preview = imageNum === 1 ? preview1 : preview2;
          const upload = imageNum === 1 ? upload1 : upload2;
          preview.src = e.target.result;
          preview.style.display = "block";
          upload.classList.add("has-image");

          const canvas = document.createElement("canvas");
          const ctx = canvas.getContext("2d");

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

          resolve();
        };
        img.onerror = function () {
          reject(new Error("Failed to decode image."));
        };
        img.src = e.target.result;
      };
      reader.onerror = function () {
        reject(new Error("Failed to read file."));
      };
      reader.readAsDataURL(file);
    });
  }

  const handleImage1 = createImageLoadHandler({
    load: function (file) {
      return loadImage(file, 1);
    },
    setLoaded: function (loaded) {
      image1Ready = loaded;
      updateMatchButton();
    },
    onError: function (error) {
      console.error(error);
      image1Ready = !!image1Data;
      updateMatchButton();
    },
  });

  const handleImage2 = createImageLoadHandler({
    load: function (file) {
      return loadImage(file, 2);
    },
    setLoaded: function (loaded) {
      image2Ready = loaded;
      updateMatchButton();
    },
    onError: function (error) {
      console.error(error);
      image2Ready = !!image2Data;
      updateMatchButton();
    },
  });

  const fileInput1 = createFileInput(handleImage1);
  const fileInput2 = createFileInput(handleImage2);

  enableDrop(upload1, {
    onClick: function () {
      fileInput1.click();
    },
    onDrop: handleImage1,
  });

  enableDrop(upload2, {
    onClick: function () {
      fileInput2.click();
    },
    onDrop: handleImage2,
  });

  function resetState() {
    image1Data = null;
    image2Data = null;
    image1Ready = false;
    image2Ready = false;
    preview1.style.display = "none";
    preview2.style.display = "none";
    preview1.removeAttribute("src");
    preview2.removeAttribute("src");
    upload1.classList.remove("has-image");
    upload2.classList.remove("has-image");
    updateMatchButton();
  }

  function populateStatsPlaceholders() {
    document.getElementById("features1").textContent = "-";
    document.getElementById("features2").textContent = "-";
    document.getElementById("matches").textContent = "-";
    document.getElementById("avg-distance").textContent = "-";
    document.getElementById("time").textContent = "-";
  }

  populateStatsPlaceholders();
  updateMatchButton();

  // Toggle parameters visibility
  toggleParamsButton.addEventListener("click", () => {
    const isShown = parametersDiv.classList.toggle("show");
    toggleParamsButton.textContent = isShown ? "Parameters ▲" : "Parameters ▼";
  });

  // Update parameter value displays
  nFeaturesSlider.addEventListener("input", (e) => {
    document.getElementById("n-features-value").textContent = e.target.value;
  });
  scaleFactorSlider.addEventListener("input", (e) => {
    document.getElementById("scale-factor-value").textContent = e.target.value;
  });
  nLevelsSlider.addEventListener("input", (e) => {
    document.getElementById("n-levels-value").textContent = e.target.value;
  });
  fastThresholdSlider.addEventListener("input", (e) => {
    document.getElementById("fast-threshold-value").textContent = e.target.value;
  });
  maxDistanceSlider.addEventListener("input", (e) => {
    document.getElementById("max-distance-value").textContent = e.target.value;
  });
  ratioThresholdSlider.addEventListener("input", (e) => {
    document.getElementById("ratio-threshold-value").textContent = e.target.value;
  });

  clearButton.addEventListener("click", () => {
    resetState();
    resultCanvas.classList.remove("visible");
    matchButton.disabled = true;
    populateStatsPlaceholders();
  });

  // Match button
  matchButton.addEventListener("click", () => {
    const startTime = performance.now();

    const gap = 10;
    const resultWidth = image1Data.width + gap + image2Data.width;
    const resultHeight = Math.max(image1Data.height, image2Data.height);

    const size1 = image1Data.height * image1Data.width * 4;
    const size2 = image2Data.height * image2Data.width * 4;
    const resultSize = resultHeight * resultWidth * 4;

    const img1Ptr = wasm_exports.alloc(size1) >>> 0;
    const img2Ptr = wasm_exports.alloc(size2) >>> 0;
    const resultPtr = wasm_exports.alloc(resultSize) >>> 0;

    const statsPtr = wasm_exports.alloc(6 * 4) >>> 0;

    const img1Array = new Uint8ClampedArray(wasm_exports.memory.buffer, img1Ptr, size1);
    const img2Array = new Uint8ClampedArray(wasm_exports.memory.buffer, img2Ptr, size2);
    img1Array.set(image1Data.data.data);
    img2Array.set(image2Data.data.data);

    const nFeatures = parseInt(nFeaturesSlider.value);
    const scaleFactor = parseFloat(scaleFactorSlider.value);
    const nLevels = parseInt(nLevelsSlider.value);
    const fastThreshold = parseInt(fastThresholdSlider.value);
    const maxDistance = parseInt(maxDistanceSlider.value);
    const crossCheck = crossCheckCheckbox.checked;
    const ratioThreshold = parseFloat(ratioThresholdSlider.value);

    wasm_exports.matchAndVisualize(
      img1Ptr,
      image1Data.height,
      image1Data.width,
      img2Ptr,
      image2Data.height,
      image2Data.width,
      resultPtr,
      resultHeight,
      resultWidth,
      nFeatures,
      scaleFactor,
      nLevels,
      fastThreshold,
      maxDistance,
      crossCheck,
      ratioThreshold,
    );

    const resultData = new Uint8ClampedArray(wasm_exports.memory.buffer, resultPtr, resultSize);

    resultCanvas.width = resultWidth;
    resultCanvas.height = resultHeight;
    const imageData = new ImageData(resultData, resultWidth, resultHeight);
    ctx.putImageData(imageData, 0, 0);
    resultCanvas.classList.add("visible");

    wasm_exports.getMatchStats(
      img1Ptr,
      image1Data.height,
      image1Data.width,
      img2Ptr,
      image2Data.height,
      image2Data.width,
      statsPtr,
      nFeatures,
      scaleFactor,
      nLevels,
      fastThreshold,
      maxDistance,
      crossCheck,
      ratioThreshold,
    );

    const stats = new Float32Array(wasm_exports.memory.buffer, statsPtr, 6);
    document.getElementById("features1").textContent = Math.floor(stats[0]);
    document.getElementById("features2").textContent = Math.floor(stats[1]);
    document.getElementById("matches").textContent = Math.floor(stats[2]);
    document.getElementById("avg-distance").textContent = stats[2] > 0 ? stats[3].toFixed(2) : "-";

    const timeMs = performance.now() - startTime;
    document.getElementById("time").textContent = timeMs.toFixed(0);

    wasm_exports.free(img1Ptr, size1);
    wasm_exports.free(img2Ptr, size2);
    wasm_exports.free(resultPtr, resultSize);
    wasm_exports.free(statsPtr, 6 * 4);
  });

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
      }),
    )
    .then((obj) => {
      wasm_exports = obj.instance.exports;
      console.log("WASM module loaded successfully");
      updateMatchButton();
    })
    .catch((err) => {
      console.error("Failed to load WASM module:", err);
      alert("Failed to load WASM module. Check the console for details.");
    });
})();
