(function() {
  const { loadWasm } = window.ZignalUtils;
  var wasm_exports = null;

  loadWasm("perlin_noise.wasm").then(function(api) {
    wasm_exports = api.exports;
    console.log("wasm loaded");
    const canvas = document.getElementById("canvas-perlin");
    const ctx = canvas.getContext("2d", { willReadFrequently: true });
    const rows = 512;
    const cols = 512;
    const rgbaSize = rows * cols * 4;

    const amplitudeRange = document.getElementById("amplitude-range");
    amplitudeRange.oninput = function() {
      document.getElementById("amplitude").innerHTML = amplitudeRange.value;
      generateNoise();
    }
    const frequencyRange = document.getElementById("frequency-range");
    frequencyRange.oninput = function() {
      document.getElementById("frequency").innerHTML = frequencyRange.value;
      generateNoise();
    }
    const octavesRange = document.getElementById("octaves-range");
    octavesRange.oninput = function() {
      document.getElementById("octaves").innerHTML = octavesRange.value;
      generateNoise();
    }
    const persistenceRange = document.getElementById("persistence-range");
    persistenceRange.oninput = function() {
      document.getElementById("persistence").innerHTML = persistenceRange.value;
      generateNoise();
    }
    const lacunarityRange = document.getElementById("lacunarity-range");
    lacunarityRange.oninput = function() {
      document.getElementById("lacunarity").innerHTML = lacunarityRange.value;
      generateNoise();
    }

    function generateNoise() {
      document.getElementById("amplitude").innerHTML = amplitudeRange.value;
      wasm_exports.set_amplitude(amplitudeRange.value);
      document.getElementById("frequency").innerHTML = frequencyRange.value;
      wasm_exports.set_frequency(frequencyRange.value);
      document.getElementById("octaves").innerHTML = octavesRange.value;
      wasm_exports.set_octaves(octavesRange.value);
      document.getElementById("persistence").innerHTML = persistenceRange.value;
      wasm_exports.set_persistence(persistenceRange.value);
      document.getElementById("lacunarity").innerHTML = lacunarityRange.value;
      wasm_exports.set_lacunarity(lacunarityRange.value);

      const rgbaPtr = wasm_exports.alloc(rgbaSize);
      const rgba = new Uint8ClampedArray(wasm_exports.memory.buffer, rgbaPtr, rgbaSize);
      wasm_exports.generate(rgbaPtr, rows, cols);
      let image = ctx.getImageData(0, 0, cols, rows);
      image.data.set(rgba);
      ctx.putImageData(image, 0, 0);
      wasm_exports.free(rgbaPtr, rgbaSize);
    }
    generateNoise();
  });
})();
