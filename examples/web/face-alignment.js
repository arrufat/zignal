(function () {
  const { createFileInput, enableDrop } = window.ZignalUtils;

  async function setupMediaPipeLandmarks(mode, delegate) {
    const mediapipeVersion = "0.10.15";
    const visionBundle = await import(`https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@${mediapipeVersion}`);
    const { FaceLandmarker, FilesetResolver } = visionBundle;
    const vision = await FilesetResolver.forVisionTasks(`https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@${mediapipeVersion}/wasm`);
    return await FaceLandmarker.createFromOptions(vision, {
      baseOptions: {
        modelAssetPath: "https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task",
        delegate: delegate,
      },
      runningMode: mode,
      numFaces: 2,
    });
  }

  const video = document.getElementById("video");
  const canvasWebcam = document.getElementById("canvas-webcam");
  const canvasFace = document.getElementById("canvas-face");
  const ctx1 = canvasWebcam.getContext("2d", { willReadFrequently: true });
  const ctx2 = canvasFace.getContext("2d", { willReadFrequently: true });
  const toggleButton = document.getElementById("toggle-button");
  const alignButton = document.getElementById("align-button");
  let mediaStream = undefined;
  let faceLandmarker = undefined;
  let processFn = undefined;
  let image = undefined;
  let original = undefined;
  let padding = 25;
  let blurring = 0;

  document.getElementsByName("padding")[0].innerHTML = padding + "%";
  document.getElementsByName("padding-range")[0].oninput = function () {
    padding = this.value;
    document.getElementsByName("padding")[0].innerHTML = padding + "%";
  };
  document.getElementsByName("blurring")[0].innerHTML = blurring + " px";
  document.getElementsByName("blurring-range")[0].oninput = function () {
    blurring = this.value;
    document.getElementsByName("blurring")[0].innerHTML = blurring + " px";
  };

  function displayImageSize() {
    let sizeElement = document.getElementById("size");
    sizeElement.textContent = "size: " + canvasWebcam.width + "×" + canvasWebcam.height + " px.";
  }

  toggleButton.disabled = true;
  toggleButton.addEventListener("click", () => {
    if (mediaStream) {
      stopMediaStream();
    } else {
      startMediaStream();
    }
  });

  alignButton.disabled = true;
  alignButton.addEventListener("click", () => {
    processFn();
  });

  function displayImage(file) {
    const reader = new FileReader();
    reader.onload = function (e) {
      const imageData = e.target.result;
      const img = document.createElement("img");
      img.src = imageData;
      img.onload = function () {
        canvasWebcam.width = img.width;
        canvasWebcam.height = img.height;
        ctx1.drawImage(img, 0, 0);
        image = ctx1.getImageData(0, 0, canvasWebcam.width, canvasWebcam.height);
        original = new ImageData(image.width, image.height);
        original.data.set(image.data);
        displayImageSize();
      };
    };
    reader.readAsDataURL(file);
  }

  const fileInput = createFileInput(function (file) {
    displayImage(file);
    alignButton.disabled = false;
  });

  enableDrop(canvasWebcam, {
    onClick: function () {
      fileInput.click();
    },
    onDrop: function (file) {
      displayImage(file);
      alignButton.disabled = false;
    },
  });

  function startMediaStream() {
    function loop() {
      if (!mediaStream) return;
      ctx1.save();
      ctx1.scale(-1, 1);
      ctx1.drawImage(video, 0, 0, -canvasWebcam.width, canvasWebcam.height);
      processFn();
      ctx1.restore();
      alignButton.disabled = true;
      requestAnimationFrame(loop);
    }

    toggleButton.textContent = "Stop";
    navigator.mediaDevices
      .getUserMedia({ video: true })
      .then((stream) => {
        mediaStream = stream;
        video.srcObject = stream;
        video.style.display = "none";
        video.play();
        video.onloadedmetadata = () => {
          canvasWebcam.width = video.videoWidth;
          canvasWebcam.height = video.videoHeight;
          loop(processFn);
        };
      })
      .catch((error) => {
        console.error("Error accessing webcam:", error);
      });
  }

  function stopMediaStream() {
    toggleButton.textContent = "Start";
    if (mediaStream) {
      mediaStream.getTracks().forEach((track) => track.stop());
      mediaStream = null;
      video.srcObject = null;
      ctx1.clearRect(0, 0, canvasWebcam.width, canvasWebcam.height);
      ctx2.clearRect(0, 0, canvasFace.width, canvasFace.height);
    }
  }

  let wasm_promise = fetch("face_alignment.wasm");
  var wasm_exports = null;
  const text_decoder = new TextDecoder();
  const text_encoder = new TextEncoder();

  function decodeString(ptr, len) {
    if (len === 0) return "";
    return text_decoder.decode(new Uint8Array(wasm_exports.memory.buffer, ptr, len));
  }

  function unwrapString(bigint) {
    const ptr = Number(bigint & 0xffffffffn);
    const len = Number(bigint >> 32n);
    return decodeString(ptr, len);
  }

  WebAssembly.instantiateStreaming(wasm_promise, {
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
    wasm_exports = obj.instance.exports;
    window.wasm = obj;
    setupMediaPipeLandmarks("IMAGE", "GPU").then(function (landmarker) {
      faceLandmarker = landmarker;
      toggleButton.disabled = false;

      let align = function () {
        displayImageSize();
        const rows = canvasWebcam.height;
        const cols = canvasWebcam.width;
        const landmarksCount = 478; // MediaPipe's landmarks
        const landmarksSize = landmarksCount * 2 * 4; // x, y, f32
        const rgbaSize = rows * cols * 4; // RGBA
        const extraSize = rgbaSize * 8; // For extra WASM
        const outRows = canvasFace.height;
        const outCols = canvasFace.width;
        const outSize = outRows * outCols * 4; // RGBA

        // We need to allocate all memory at once before mapping it
        const rgbaPtr = wasm_exports.alloc(rgbaSize);
        const outPtr = wasm_exports.alloc(outSize);
        const landmarksPtr = wasm_exports.alloc(landmarksSize);
        const extraPtr = wasm_exports.alloc(extraSize);
        // Now we can proceed to map all the memory to JavaScript
        let rgba = new Uint8ClampedArray(wasm_exports.memory.buffer, rgbaPtr, rgbaSize);
        let landmarks = new Float32Array(wasm_exports.memory.buffer, landmarksPtr, landmarksCount * 2);
        image = ctx1.getImageData(0, 0, cols, rows);
        rgba.set(image.data);

        const faceLandmarks = faceLandmarker.detect(image).faceLandmarks;
        if (faceLandmarks.length === 0) {
          ctx2.clearRect(0, 0, canvasFace.width, canvasFace.height);
          return;
        }

        // fill the landmarks
        for (let i = 0; i < faceLandmarks[0].length; ++i) {
          landmarks[i * 2 + 0] = faceLandmarks[0][i].x;
          landmarks[i * 2 + 1] = faceLandmarks[0][i].y;
        }

        const startTime = performance.now();
        wasm_exports.extract_aligned_face(rgbaPtr, rows, cols, outPtr, outRows, outCols, padding / 100, blurring, landmarksPtr, landmarksCount, extraPtr, extraSize);
        const timeMs = performance.now() - startTime;
        const fps = 1000.0 / timeMs;
        let timeElement = document.getElementById("time");
        timeElement.textContent = "time: " + timeMs.toFixed(0) + " ms (" + fps.toFixed(2) + " fps)";

        let outImg = new Uint8ClampedArray(wasm_exports.memory.buffer, outPtr, outSize);
        image.data.set(rgba);
        ctx1.putImageData(image, 0, 0);
        const out = ctx2.getImageData(0, 0, outCols, outRows);
        out.data.set(outImg);
        ctx2.putImageData(out, 0, 0);
        wasm_exports.free(rgbaPtr, rgbaSize);
        wasm_exports.free(outPtr, outSize);
        wasm_exports.free(landmarksPtr, landmarksSize);
        wasm_exports.free(extraPtr, extraSize);
      };
      processFn = align;
    });
  });
})();
