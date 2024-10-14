

(function() {

  let wasm_promise = fetch("colorspace.wasm");
  var wasm_exports = null;
  const text_decoder = new TextDecoder();

  function decodeString(ptr, len) {
    if (len === 0) return "";
    return text_decoder.decode(
      new Uint8Array(wasm_exports.memory.buffer, ptr, len),
    );
  }

  function hex2rgb(hex) {
    const m = hex.match(/^#?([\da-f]{2})([\da-f]{2})([\da-f]{2})$/i);
    if (!m) {
      return null;
    }

    return {
      r: Number.parseInt(m[1], 16),
      g: Number.parseInt(m[2], 16),
      b: Number.parseInt(m[3], 16),
    };
  }

  function rgb2hex(r, g, b) {
    const toHex = (c) => {
      const hex = Math.min(255, Math.max(0, c)).toString(16);
      return hex.length == 1 ? "0" + hex : hex;
    };
    return "#" + toHex(r) + toHex(g) + toHex(b);
  }

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
    // Event listeners for HEX
    document.getElementById('hex-str').addEventListener('input', updateHex);
    // Event listeners for RGB
    document.getElementById('rgb-r').addEventListener('input', updateRgb);
    document.getElementById('rgb-g').addEventListener('input', updateRgb);
    document.getElementById('rgb-b').addEventListener('input', updateRgb);
    // Event listeners for HSL
    document.getElementById('hsl-h').addEventListener('input', updateHsl);
    document.getElementById('hsl-s').addEventListener('input', updateHsl);
    document.getElementById('hsl-l').addEventListener('input', updateHsl);
    // Event listeners for HSV
    document.getElementById('hsv-h').addEventListener('input', updateHsv);
    document.getElementById('hsv-s').addEventListener('input', updateHsv);
    document.getElementById('hsv-v').addEventListener('input', updateHsv);
    // Event listeners for XYZ
    document.getElementById('xyz-x').addEventListener('input', updateXyz);
    document.getElementById('xyz-y').addEventListener('input', updateXyz);
    document.getElementById('xyz-z').addEventListener('input', updateXyz);
    // Event listeners for LAB
    document.getElementById('lab-l').addEventListener('input', updateLab);
    document.getElementById('lab-a').addEventListener('input', updateLab);
    document.getElementById('lab-b').addEventListener('input', updateLab);

    function updateHex() {
      const hex = document.getElementById('hex-str').value;
      console.log(hex)
      const rgb = hex2rgb(hex);
      console.log(rgb);
      if (rgb) {
        document.getElementById('rgb-r').value = rgb.r;
        document.getElementById('rgb-g').value = rgb.g;
        document.getElementById('rgb-b').value = rgb.b;
        updateRgb();
      }
    }

    // --- RGB ---
    function rgb2hsl(r, g, b) {
      const hslPtr = wasm_exports.alloc(3 * 4);
      const hsl = new Float32Array(wasm_exports.memory.buffer, hslPtr, 3);
      wasm_exports.rgb2hsl(r, g, b, hslPtr);
      document.getElementById('hsl-h').value = Math.round(hsl[0]);
      document.getElementById('hsl-s').value = Math.round(hsl[1]);
      document.getElementById('hsl-l').value = Math.round(hsl[2]);
    }

    function rgb2hsv(r, g, b) {
      const hsvPtr = wasm_exports.alloc(3 * 4);
      const hsv = new Float32Array(wasm_exports.memory.buffer, hsvPtr, 3);
      wasm_exports.rgb2hsv(r, g, b, hsvPtr);
      document.getElementById('hsv-h').value = Math.round(hsv[0]);
      document.getElementById('hsv-s').value = Math.round(hsv[1]);
      document.getElementById('hsv-v').value = Math.round(hsv[2]);
    }

    function rgb2xyz(r, g, b) {
      const xyzPtr = wasm_exports.alloc(3 * 4);
      const xyz = new Float32Array(wasm_exports.memory.buffer, xyzPtr, 3);
      wasm_exports.rgb2xyz(r, g, b, xyzPtr);
      document.getElementById('xyz-x').value = xyz[0];
      document.getElementById('xyz-y').value = xyz[1];
      document.getElementById('xyz-z').value = xyz[2];
    }

    function rgb2lab(r, g, b) {
      const labPtr = wasm_exports.alloc(3 * 4);
      const lab = new Float32Array(wasm_exports.memory.buffer, labPtr, 3);
      wasm_exports.rgb2lab(r, g, b, labPtr);
      document.getElementById('lab-l').value = lab[0];
      document.getElementById('lab-a').value = lab[1];
      document.getElementById('lab-b').value = lab[2];
    }

    function updateRgb() {
      const r = parseInt(document.getElementById('rgb-r').value);
      const g = parseInt(document.getElementById('rgb-g').value);
      const b = parseInt(document.getElementById('rgb-b').value);
      rgb2hsl(r, g, b);
      rgb2hsv(r, g, b);
      rgb2xyz(r, g, b);
      rgb2lab(r, g, b);
      document.getElementById('hex-str').value = rgb2hex(r, g, b);
    }

    // --- HSL ---

    function hsl2rgb(h, s, l) {
      const rgbPtr = wasm_exports.alloc(3);
      const rgb = new Uint8Array(wasm_exports.memory.buffer, rgbPtr, 3);
      wasm_exports.hsl2rgb(h, s, l, rgbPtr);
      document.getElementById('rgb-r').value = rgb[0];
      document.getElementById('rgb-g').value = rgb[1];
      document.getElementById('rgb-b').value = rgb[2];
    }

    function hsl2hsv(h, s, l) {
      const hsvPtr = wasm_exports.alloc(3 * 4);
      const hsv = new Float32Array(wasm_exports.memory.buffer, hsvPtr, 3);
      wasm_exports.hsl2hsv(h, s, l, hsvPtr);
      document.getElementById('hsv-h').value = Math.round(hsv[0]);
      document.getElementById('hsv-s').value = Math.round(hsv[1]);
      document.getElementById('hsv-v').value = Math.round(hsv[2]);
    }

    function hsl2xyz(h, s, l) {
      const xyzPtr = wasm_exports.alloc(3 * 4);
      const xyz = new Float32Array(wasm_exports.memory.buffer, xyzPtr, 3);
      wasm_exports.hsl2xyz(h, s, l, xyzPtr);
      document.getElementById('xyz-x').value = xyz[0];
      document.getElementById('xyz-y').value = xyz[1];
      document.getElementById('xyz-z').value = xyz[2];
    }

    function hsl2lab(h, s, l) {
      const labPtr = wasm_exports.alloc(3 * 4);
      const lab = new Float32Array(wasm_exports.memory.buffer, labPtr, 3);
      wasm_exports.hsl2lab(h, s, l, labPtr);
      document.getElementById('lab-l').value = lab[0];
      document.getElementById('lab-a').value = lab[1];
      document.getElementById('lab-b').value = lab[2];
    }

    function updateHsl() {
      const h = parseFloat(document.getElementById('hsl-h').value);
      const s = parseFloat(document.getElementById('hsl-s').value);
      const l = parseFloat(document.getElementById('hsl-l').value);
      hsl2rgb(h, s, l);
      hsl2hsv(h, s, l);
      hsl2xyz(h, s, l);
      hsl2lab(h, s, l);
      const red = parseInt(document.getElementById('rgb-r').value);
      const green = parseInt(document.getElementById('rgb-g').value);
      const blue = parseInt(document.getElementById('rgb-b').value);
      document.getElementById('hex-str').value = rgb2hex(red, green, blue);
    }

    // --- HSV ---

    function hsv2rgb(h, s, v) {
      const rgbPtr = wasm_exports.alloc(3);
      const rgb = new Uint8Array(wasm_exports.memory.buffer, rgbPtr, 3);
      wasm_exports.hsv2rgb(h, s, v, rgbPtr);
      document.getElementById('rgb-r').value = rgb[0];
      document.getElementById('rgb-g').value = rgb[1];
      document.getElementById('rgb-b').value = rgb[2];
    }

    function hsv2hsl(h, s, v) {
      const hslPtr = wasm_exports.alloc(3 * 4)
      const hsl = new Float32Array(wasm_exports.memory.buffer, hslPtr, 3);
      wasm_exports.hsv2hsl(h, s, v, hslPtr);
      document.getElementById('hsl-h').value = Math.round(hsl[0]);
      document.getElementById('hsl-s').value = Math.round(hsl[1]);
      document.getElementById('hsl-l').value = Math.round(hsl[2]);
    }

    function hsv2xyz(h, s, v) {
      const xyzPtr = wasm_exports.alloc(3 * 4)
      const xyz = new Float32Array(wasm_exports.memory.buffer, xyzPtr, 3);
      wasm_exports.hsv2xyz(h, s, v, xyzPtr);
      document.getElementById('xyz-x').value = xyz[0];
      document.getElementById('xyz-y').value = xyz[1];
      document.getElementById('xyz-z').value = xyz[2];
    }

    function hsv2lab(h, s, v) {
      const labPtr = wasm_exports.alloc(3 * 4)
      const lab = new Float32Array(wasm_exports.memory.buffer, labPtr, 3);
      wasm_exports.hsv2lab(h, s, v, labPtr);
      document.getElementById('lab-l').value = lab[0];
      document.getElementById('lab-a').value = lab[1];
      document.getElementById('lab-b').value = lab[2];
    }

    function updateHsv() {
      const h = parseFloat(document.getElementById('hsv-h').value);
      const s = parseFloat(document.getElementById('hsv-s').value);
      const v = parseFloat(document.getElementById('hsv-v').value);
      hsv2rgb(h, s, v);
      hsv2hsl(h, s, v);
      hsv2xyz(h, s, v);
      hsv2lab(h, s, v);
      const red = parseInt(document.getElementById('rgb-r').value);
      const green = parseInt(document.getElementById('rgb-g').value);
      const blue = parseInt(document.getElementById('rgb-b').value);
      document.getElementById('hex-str').value = rgb2hex(red, green, blue);
    }

    // --- XYZ ---

    function xyz2rgb(x, y, z) {
      const rgbPtr = wasm_exports.alloc(3);
      const rgb = new Uint8Array(wasm_exports.memory.buffer, rgbPtr, 3);
      wasm_exports.xyz2rgb(x, y, z, rgbPtr);
      document.getElementById('rgb-r').value = rgb[0];
      document.getElementById('rgb-g').value = rgb[1];
      document.getElementById('rgb-b').value = rgb[2];
    }

    function xyz2hsl(x, y, z) {
      const hslPtr = wasm_exports.alloc(3 * 4)
      const hsl = new Float32Array(wasm_exports.memory.buffer, hslPtr, 3);
      wasm_exports.xyz2hsl(x, y, z, hslPtr);
      document.getElementById('hsl-h').value = Math.round(hsl[0]);
      document.getElementById('hsl-s').value = Math.round(hsl[1]);
      document.getElementById('hsl-l').value = Math.round(hsl[2]);
    }

    function xyz2hsv(x, y, z) {
      const hsvPtr = wasm_exports.alloc(3 * 4)
      const hsv = new Float32Array(wasm_exports.memory.buffer, hsvPtr, 3);
      wasm_exports.xyz2hsv(x, y, z, hsvPtr);
      document.getElementById('hsl-h').value = Math.round(hsv[0]);
      document.getElementById('hsl-s').value = Math.round(hsv[1]);
      document.getElementById('hsl-l').value = Math.round(hsv[2]);
    }

    function xyz2lab(x, y, z) {
      const labPtr = wasm_exports.alloc(3 * 4)
      const lab = new Float32Array(wasm_exports.memory.buffer, labPtr, 3);
      wasm_exports.xyz2lab(x, y, z, labPtr);
      document.getElementById('lab-l').value = lab[0];
      document.getElementById('lab-a').value = lab[1];
      document.getElementById('lab-b').value = lab[2];
    }

    function updateXyz() {
      const x = parseFloat(document.getElementById('xyz-x').value);
      const y = parseFloat(document.getElementById('xyz-y').value);
      const z = parseFloat(document.getElementById('xyz-z').value);
      xyz2rgb(x, y, z);
      xyz2hsl(x, y, z);
      xyz2hsv(x, y, z);
      xyz2lab(x, y, z);
      const red = parseInt(document.getElementById('rgb-r').value);
      const green = parseInt(document.getElementById('rgb-g').value);
      const blue = parseInt(document.getElementById('rgb-b').value);
      document.getElementById('hex-str').value = rgb2hex(red, green, blue);
    }

    // --- LAB ---

    function lab2rgb(l, a, b) {
      const rgbPtr = wasm_exports.alloc(3);
      const rgb = new Uint8Array(wasm_exports.memory.buffer, rgbPtr, 3);
      wasm_exports.lab2rgb(l, a, b, rgbPtr);
      document.getElementById('rgb-r').value = rgb[0];
      document.getElementById('rgb-g').value = rgb[1];
      document.getElementById('rgb-b').value = rgb[2];
    }

    function lab2hsl(l, a, b) {
      const hslPtr = wasm_exports.alloc(3 * 4)
      const hsl = new Float32Array(wasm_exports.memory.buffer, hslPtr, 3);
      wasm_exports.lab2hsl(l, a, b, hslPtr);
      document.getElementById('hsl-h').value = Math.round(hsl[0]);
      document.getElementById('hsl-s').value = Math.round(hsl[1]);
      document.getElementById('hsl-l').value = Math.round(hsl[2]);
    }

    function lab2hsv(l, a, b) {
      const hsvPtr = wasm_exports.alloc(3 * 4)
      const hsv = new Float32Array(wasm_exports.memory.buffer, hsvPtr, 3);
      wasm_exports.lab2hsv(l, a, b, hsvPtr);
      document.getElementById('hsl-h').value = Math.round(hsv[0]);
      document.getElementById('hsl-s').value = Math.round(hsv[1]);
      document.getElementById('hsl-l').value = Math.round(hsv[2]);
    }

    function lab2xyz(l, a, b) {
      const xyzPtr = wasm_exports.alloc(3 * 4)
      const xyz = new Float32Array(wasm_exports.memory.buffer, xyzPtr, 3);
      wasm_exports.lab2lab(l, a, b, xyzPtr);
      document.getElementById('lab-l').value = xyz[0];
      document.getElementById('lab-a').value = xyz[1];
      document.getElementById('lab-b').value = xyz[2];
    }

    function updateLab() {
      const l = parseFloat(document.getElementById('lab-l').value);
      const a = parseFloat(document.getElementById('lab-a').value);
      const b = parseFloat(document.getElementById('lab-b').value);
      lab2rgb(l, a, b);
      lab2hsl(l, a, b);
      lab2hsv(l, a, b);
      lab2xyz(l, a, b);
      const red = parseInt(document.getElementById('rgb-r').value);
      const green = parseInt(document.getElementById('rgb-g').value);
      const blue = parseInt(document.getElementById('rgb-b').value);
      document.getElementById('hex-str').value = rgb2hex(red, green, blue);
    }

  });
})();
