(function () {
  const { createFileInput, enableDrop, createModeSelector } = window.ZignalUtils;

  const video = document.getElementById("video");
  const canvasWebcam = document.getElementById("scan-canvas");
  const canvasQr = document.getElementById("canvas-qr");
  const ctx1 = canvasWebcam.getContext("2d", { willReadFrequently: true });
  const ctx2 = canvasQr.getContext("2d");
  const scanHeader = document.getElementById("scan-header");
  const copyButton = document.getElementById("copy-button");
  const openLink = document.getElementById("open-link");
  const encodeText = document.getElementById("encode-text");
  const ecLevel = document.getElementById("ec-level");
  const placeholder = document.getElementById("scan-placeholder");
  const decodedElement = document.getElementById("decoded");
  const timeElement = document.getElementById("scan-status");
  const encodeStatus = document.getElementById("encode-status");
  let mediaStream = undefined;

  const maxTextLen = 8192;
  // Version 40 at one pixel per module with the quiet zone: (177 + 8)^2 RGBA.
  const maxQrSide = 185;

  let wasm_exports = null;
  const text_decoder = new TextDecoder();
  const text_encoder = new TextEncoder();
  // Scratch canvas for the 1-pixel-per-module blit in encode().
  const small = document.createElement("canvas");

  let rgbaPtr = null;
  let rgbaSize = 0;
  let textPtr = null;
  let cornersPtr = null;
  let qrPtr = null;

  function decodeString(ptr, len) {
    if (len === 0) return "";
    return text_decoder.decode(new Uint8Array(wasm_exports.memory.buffer, ptr, len));
  }

  function setStageActive(active) {
    placeholder.style.display = active ? "none" : "";
    canvasWebcam.classList.toggle("live", active);
  }

  function showDecoded(text) {
    decodedElement.textContent = text;
    decodedElement.classList.remove("empty");
    copyButton.style.display = "";
    let url = null;
    try {
      url = new URL(text);
    } catch (_) {}
    if (url && (url.protocol === "http:" || url.protocol === "https:")) {
      openLink.href = url.href;
      openLink.style.display = "";
    } else {
      openLink.style.display = "none";
    }
  }

  function ensureFrameBuffer(size) {
    if (size !== rgbaSize) {
      if (rgbaPtr !== null) wasm_exports.free(rgbaPtr, rgbaSize);
      rgbaPtr = wasm_exports.alloc(size) >>> 0;
      rgbaSize = size;
    }
  }

  function decodeCanvas() {
    const rows = canvasWebcam.height;
    const cols = canvasWebcam.width;
    const size = rows * cols * 4;
    ensureFrameBuffer(size);
    const rgba = new Uint8ClampedArray(wasm_exports.memory.buffer, rgbaPtr, size);
    const image = ctx1.getImageData(0, 0, cols, rows);
    rgba.set(image.data);

    const startTime = performance.now();
    const len = wasm_exports.qr_decode(rgbaPtr, rows, cols, textPtr, maxTextLen, cornersPtr);
    const timeMs = performance.now() - startTime;

    if (len > 0) {
      timeElement.textContent = "decoded in " + timeMs.toFixed(0) + " ms";
      showDecoded(decodeString(textPtr, len));
      // Outline the detected symbol: corners are TL, TR, BL, BR. Skip the
      // outline on still images that are just a QR code file: the corners
      // exclude the quiet zone, so a bare symbol with the standard 4-module
      // margin covers ~0.5-0.65 of its image by area; anything above 0.45
      // is a crop, not a scene.
      const corners = new Float32Array(wasm_exports.memory.buffer, cornersPtr, 8);
      const quad = [0, 1, 3, 2].map((i) => [corners[2 * i], corners[2 * i + 1]]);
      let area = 0;
      for (let i = 0; i < 4; i++) {
        const [x1, y1] = quad[i];
        const [x2, y2] = quad[(i + 1) % 4];
        area += x1 * y2 - x2 * y1;
      }
      area = Math.abs(area) / 2;
      if (mediaStream || area / (cols * rows) < 0.45) {
        ctx1.strokeStyle = "#00c853";
        ctx1.lineWidth = Math.max(3, cols / 200);
        ctx1.beginPath();
        for (const [x, y] of quad) {
          ctx1.lineTo(x, y);
        }
        ctx1.closePath();
        ctx1.stroke();
      }
    } else if (mediaStream) {
      timeElement.textContent = "scanning… (" + timeMs.toFixed(0) + " ms/frame)";
    } else {
      timeElement.textContent = "no QR code found (" + timeMs.toFixed(0) + " ms)";
    }
  }

  function encode() {
    const bytes = text_encoder.encode(encodeText.value);
    ctx2.fillStyle = "white";
    ctx2.fillRect(0, 0, canvasQr.width, canvasQr.height);
    if (bytes.length === 0) {
      encodeStatus.textContent = "";
      return;
    }
    const inputPtr = wasm_exports.alloc(bytes.length) >>> 0;
    new Uint8Array(wasm_exports.memory.buffer, inputPtr, bytes.length).set(bytes);
    const startTime = performance.now();
    const side = wasm_exports.qr_encode(inputPtr, bytes.length, Number(ecLevel.value), qrPtr, maxQrSide * maxQrSide * 4);
    const timeMs = performance.now() - startTime;
    wasm_exports.free(inputPtr, bytes.length);

    if (side <= 0) {
      encodeStatus.textContent = side === 0 ? "text is too long for a QR code" : "encoding failed";
      return;
    }
    // Blit the 1-pixel-per-module image and scale it up without smoothing.
    const image = new ImageData(new Uint8ClampedArray(wasm_exports.memory.buffer, qrPtr, side * side * 4), side, side);
    small.width = side;
    small.height = side;
    small.getContext("2d").putImageData(image, 0, 0);
    const scale = Math.max(1, Math.floor(canvasQr.width / side));
    const offset = Math.floor((canvasQr.width - side * scale) / 2);
    ctx2.imageSmoothingEnabled = false;
    ctx2.drawImage(small, offset, offset, side * scale, side * scale);
    const dim = side - 8; // strip the quiet zone
    const version = (dim - 17) / 4;
    encodeStatus.textContent = "version " + version + ", " + dim + "×" + dim + " modules, " + timeMs.toFixed(1) + " ms";
  }

  function displayImage(file) {
    const reader = new FileReader();
    reader.onload = function (e) {
      const img = document.createElement("img");
      img.src = e.target.result;
      img.onload = function () {
        canvasWebcam.width = img.width;
        canvasWebcam.height = img.height;
        ctx1.drawImage(img, 0, 0);
        setStageActive(true);
        decodeCanvas();
      };
    };
    reader.readAsDataURL(file);
  }

  const fileInput = createFileInput(function (file) {
    stopMediaStream();
    displayImage(file);
  });

  enableDrop(canvasWebcam, {
    onClick: function () {
      if (!mediaStream) fileInput.click();
    },
    onDrop: function (file) {
      stopMediaStream();
      displayImage(file);
    },
  });

  function startMediaStream() {
    function loop() {
      if (!mediaStream) return;
      ctx1.drawImage(video, 0, 0, canvasWebcam.width, canvasWebcam.height);
      decodeCanvas();
      requestAnimationFrame(loop);
    }

    navigator.mediaDevices
      // Prefer the rear camera on phones; desktops fall back gracefully.
      .getUserMedia({ video: { facingMode: { ideal: "environment" } } })
      .then((stream) => {
        mediaStream = stream;
        video.srcObject = stream;
        video.play();
        video.onloadedmetadata = () => {
          canvasWebcam.width = video.videoWidth;
          canvasWebcam.height = video.videoHeight;
          setStageActive(true);
          loop();
        };
      })
      .catch((error) => {
        mode.selectImage();
        timeElement.textContent = "could not access the camera";
        console.error("Error accessing webcam:", error);
      });
  }

  function stopMediaStream() {
    if (mediaStream) {
      mediaStream.getTracks().forEach((track) => track.stop());
      mediaStream = null;
      video.srcObject = null;
      ctx1.clearRect(0, 0, canvasWebcam.width, canvasWebcam.height);
      setStageActive(false);
      timeElement.textContent = "";
      mode.selectImage();
    }
  }

  const mode = createModeSelector({ onImage: stopMediaStream, onCamera: startMediaStream });
  scanHeader.appendChild(mode.element);

  encodeText.addEventListener("input", () => {
    if (wasm_exports) encode();
  });
  ecLevel.addEventListener("change", () => {
    if (wasm_exports) encode();
  });

  copyButton.addEventListener("click", () => {
    navigator.clipboard.writeText(decodedElement.textContent).then(() => {
      copyButton.textContent = "Copied!";
      setTimeout(() => {
        copyButton.textContent = "Copy";
      }, 1200);
    });
  });

  WebAssembly.instantiateStreaming(fetch("qrcode.wasm"), {
    js: {
      log: function (ptr, len) {
        console.log(decodeString(ptr, len));
      },
      now: function () {
        return performance.now();
      },
    },
  }).then(function (obj) {
    wasm_exports = obj.instance.exports;
    window.wasm = obj;
    textPtr = wasm_exports.alloc(maxTextLen) >>> 0;
    cornersPtr = wasm_exports.alloc(8 * 4) >>> 0;
    qrPtr = wasm_exports.alloc(maxQrSide * maxQrSide * 4) >>> 0;
    mode.setDisabled(false);
    encode();
  });
})();
