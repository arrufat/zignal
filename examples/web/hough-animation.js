(function() {
  let wasm_promise = fetch("hough_animation.wasm");
  var wasm_exports = null;
  const text_decoder = new TextDecoder();

  function decodeString(ptr, len) {
    if (len === 0) return "";
    return text_decoder.decode(new Uint8Array(wasm_exports.memory.buffer, ptr, len));
  }

  const canvasImg = document.getElementById("canvas-image");
  const ctxImg = canvasImg.getContext("2d", { alpha: false });
  const canvasAcc = document.getElementById("canvas-accumulator");
  const ctxAcc = canvasAcc.getContext("2d", { alpha: false });
  
  const toggleButton = document.getElementById("toggleButton");
  const fpsCounter = document.getElementById("fps-counter");
  const computeTimeDisplay = document.getElementById("compute-time");

  let isPaused = false;
  let frameCount = 0;
  let lastTime = performance.now();
  let timeStep = 0;
  let totalComputeTime = 0;

  toggleButton.onclick = function() {
    isPaused = !isPaused;
    toggleButton.innerText = isPaused ? "Resume" : "Pause";
  };

  WebAssembly.instantiateStreaming(wasm_promise, {
    js: {
      log: function(ptr, len) {
        const msg = decodeString(ptr, len);
        console.log(msg);
      },
      now: function() {
        return performance.now();
      },
    },
  }).then(function(obj) {
    wasm_exports = obj.instance.exports;
    window.wasm = obj;
    console.log("wasm loaded");
    
    wasm_exports.init();

    const imgSize = 400 * 400 * 4;
    const accSize = 300 * 300 * 4;

    const imgPtr = wasm_exports.alloc(imgSize);
    const accPtr = wasm_exports.alloc(accSize);

    function loop(now) {
      if (!isPaused) {
        const t0 = performance.now();
        wasm_exports.render(imgPtr, accPtr, timeStep);
        const t1 = performance.now();
        totalComputeTime += (t1 - t0);

        timeStep += 0.05;

        // Recreate views in case memory grew (which detaches the old buffer)
        const imgData = new Uint8ClampedArray(wasm_exports.memory.buffer, imgPtr, imgSize);
        const accData = new Uint8ClampedArray(wasm_exports.memory.buffer, accPtr, accSize);

        const imgImageData = new ImageData(imgData, 400, 400);
        const accImageData = new ImageData(accData, 300, 300);

        ctxImg.putImageData(imgImageData, 0, 0);
        ctxAcc.putImageData(accImageData, 0, 0);
      }

      // FPS calculation
      frameCount++;
      if (now - lastTime >= 1000) {
        const avgCompute = totalComputeTime / frameCount;
        fpsCounter.innerText = `FPS: ${frameCount}`;
        if (computeTimeDisplay) computeTimeDisplay.innerText = `Compute: ${avgCompute.toFixed(2)} ms`;
        
        frameCount = 0;
        totalComputeTime = 0;
        lastTime = now;
      }

      requestAnimationFrame(loop);
    }

    requestAnimationFrame(loop);
  });
})();
