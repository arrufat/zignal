(function () {
  let wasmPromise = fetch("colorspaces.wasm");
  var wasmExports = null;
  const textDecoder = new TextDecoder();

  function decodeString(ptr, len) {
    if (len === 0) return "";
    return textDecoder.decode(new Uint8Array(wasmExports.memory.buffer, ptr, len));
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
    // Event listeners for HEX
    document.getElementById("hex-#").addEventListener("input", updateFromHex);
    document.getElementById("color").addEventListener("input", updateFromColor);
    // Event listeners for RGB
    document.getElementById("rgb-r").addEventListener("input", updateFromRgb);
    document.getElementById("rgb-g").addEventListener("input", updateFromRgb);
    document.getElementById("rgb-b").addEventListener("input", updateFromRgb);
    // Event listeners for HSL
    document.getElementById("hsl-h").addEventListener("input", updateFromHsl);
    document.getElementById("hsl-s").addEventListener("input", updateFromHsl);
    document.getElementById("hsl-l").addEventListener("input", updateFromHsl);
    // Event listeners for HSV
    document.getElementById("hsv-h").addEventListener("input", updateFromHsv);
    document.getElementById("hsv-s").addEventListener("input", updateFromHsv);
    document.getElementById("hsv-v").addEventListener("input", updateFromHsv);
    // Event listeners for XYZ
    document.getElementById("xyz-x").addEventListener("input", updateFromXyz);
    document.getElementById("xyz-y").addEventListener("input", updateFromXyz);
    document.getElementById("xyz-z").addEventListener("input", updateFromXyz);
    // Event listeners for LAB
    document.getElementById("lab-l").addEventListener("input", updateFromLab);
    document.getElementById("lab-a").addEventListener("input", updateFromLab);
    document.getElementById("lab-b").addEventListener("input", updateFromLab);
    // Event listeners for LMS
    document.getElementById("lms-l").addEventListener("input", updateFromLms);
    document.getElementById("lms-m").addEventListener("input", updateFromLms);
    document.getElementById("lms-s").addEventListener("input", updateFromLms);
    // Event listeners for Oklab
    document.getElementById("oklab-l").addEventListener("input", updateFromOklab);
    document.getElementById("oklab-a").addEventListener("input", updateFromOklab);
    document.getElementById("oklab-b").addEventListener("input", updateFromOklab);
    // Event listeners for XYB
    document.getElementById("xyb-x").addEventListener("input", updateFromXyb);
    document.getElementById("xyb-y").addEventListener("input", updateFromXyb);
    document.getElementById("xyb-b").addEventListener("input", updateFromXyb);

    function updateFromHex() {
      const hex = document.getElementById("hex-#").value;
      const rgb = hex2rgb(hex);
      if (rgb) {
        document.getElementById("validation-message").textContent = "";
        document.getElementById("rgb-r").value = rgb.r;
        document.getElementById("rgb-g").value = rgb.g;
        document.getElementById("rgb-b").value = rgb.b;
        updateColor();
        updateFromRgb();
      } else {
        document.getElementById("validation-message").textContent = "⚠️ Invalid HEX value.";
      }
    }

    function updateHex() {
      const r = document.getElementById("rgb-r").value;
      const g = document.getElementById("rgb-g").value;
      const b = document.getElementById("rgb-b").value;
      document.getElementById("hex-#").value = rgb2hex(r, g, b);
      updateColor();
    }

    function updateFromColor() {
      const hex = document.getElementById("color").value;
      document.getElementById("hex-#").value = hex;
      updateFromHex();
    }

    function updateColor() {
      const hex = document.getElementById("hex-#").value;
      document.getElementById("color").value = hex;
    }

    // --- RGB ---
    function rgb2hsl(r, g, b) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.rgb2hsl(r, g, b, outPtr);
      document.getElementById("hsl-h").value = out[0].toFixed(6);
      document.getElementById("hsl-s").value = out[1].toFixed(6);
      document.getElementById("hsl-l").value = out[2].toFixed(6);
    }

    function rgb2hsv(r, g, b) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.rgb2hsv(r, g, b, outPtr);
      document.getElementById("hsv-h").value = out[0].toFixed(6);
      document.getElementById("hsv-s").value = out[1].toFixed(6);
      document.getElementById("hsv-v").value = out[2].toFixed(6);
    }

    function rgb2xyz(r, g, b) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.rgb2xyz(r, g, b, outPtr);
      document.getElementById("xyz-x").value = out[0].toFixed(6);
      document.getElementById("xyz-y").value = out[1].toFixed(6);
      document.getElementById("xyz-z").value = out[2].toFixed(6);
    }

    function rgb2lab(r, g, b) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.rgb2lab(r, g, b, outPtr);
      document.getElementById("lab-l").value = out[0].toFixed(6);
      document.getElementById("lab-a").value = out[1].toFixed(6);
      document.getElementById("lab-b").value = out[2].toFixed(6);
    }

    function rgb2lms(r, g, b) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.rgb2lms(r, g, b, outPtr);
      document.getElementById("lms-l").value = out[0].toFixed(6);
      document.getElementById("lms-m").value = out[1].toFixed(6);
      document.getElementById("lms-s").value = out[2].toFixed(6);
    }

    function rgb2oklab(r, g, b) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.rgb2oklab(r, g, b, outPtr);
      document.getElementById("oklab-l").value = out[0].toFixed(6);
      document.getElementById("oklab-a").value = out[1].toFixed(6);
      document.getElementById("oklab-b").value = out[2].toFixed(6);
    }

    function rgb2xyb(r, g, b) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.rgb2xyb(r, g, b, outPtr);
      document.getElementById("xyb-x").value = out[0].toFixed(6);
      document.getElementById("xyb-y").value = out[1].toFixed(6);
      document.getElementById("xyb-b").value = out[2].toFixed(6);
    }

    function updateFromRgb() {
      const r = parseInt(document.getElementById("rgb-r").value);
      const g = parseInt(document.getElementById("rgb-g").value);
      const b = parseInt(document.getElementById("rgb-b").value);
      if (r < 0) document.getElementById("rgb-r").value = 0;
      if (g < 0) document.getElementById("rgb-g").value = 0;
      if (b < 0) document.getElementById("rgb-b").value = 0;
      if (r > 255) document.getElementById("rgb-r").value = 255;
      if (g > 255) document.getElementById("rgb-g").value = 255;
      if (b > 255) document.getElementById("rgb-b").value = 255;
      rgb2hsl(r, g, b);
      rgb2hsv(r, g, b);
      rgb2xyz(r, g, b);
      rgb2lab(r, g, b);
      rgb2lms(r, g, b);
      rgb2oklab(r, g, b);
      rgb2xyb(r, g, b);
      updateHex();
    }

    // --- HSL ---

    function hsl2rgb(h, s, l) {
      const outPtr = wasmExports.alloc(3);
      const out = new Uint8Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.hsl2rgb(h, s, l, outPtr);
      document.getElementById("rgb-r").value = out[0];
      document.getElementById("rgb-g").value = out[1];
      document.getElementById("rgb-b").value = out[2];
    }

    function hsl2hsv(h, s, l) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.hsl2hsv(h, s, l, outPtr);
      document.getElementById("hsv-h").value = out[0].toFixed(6);
      document.getElementById("hsv-s").value = out[1].toFixed(6);
      document.getElementById("hsv-v").value = out[2].toFixed(6);
    }

    function hsl2xyz(h, s, l) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.hsl2xyz(h, s, l, outPtr);
      document.getElementById("xyz-x").value = out[0].toFixed(6);
      document.getElementById("xyz-y").value = out[1].toFixed(6);
      document.getElementById("xyz-z").value = out[2].toFixed(6);
    }

    function hsl2lab(h, s, l) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.hsl2lab(h, s, l, outPtr);
      document.getElementById("lab-l").value = out[0].toFixed(6);
      document.getElementById("lab-a").value = out[1].toFixed(6);
      document.getElementById("lab-b").value = out[2].toFixed(6);
    }

    function hsl2lms(h, s, l) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.hsl2lms(h, s, l, outPtr);
      document.getElementById("lms-l").value = out[0].toFixed(6);
      document.getElementById("lms-m").value = out[1].toFixed(6);
      document.getElementById("lms-s").value = out[2].toFixed(6);
    }

    function hsl2oklab(h, s, l) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.hsl2oklab(h, s, l, outPtr);
      document.getElementById("oklab-l").value = out[0].toFixed(6);
      document.getElementById("oklab-a").value = out[1].toFixed(6);
      document.getElementById("oklab-b").value = out[2].toFixed(6);
    }
    function hsl2xyb(h, s, l) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.hsl2xyb(h, s, l, outPtr);
      document.getElementById("xyb-x").value = out[0].toFixed(6);
      document.getElementById("xyb-y").value = out[1].toFixed(6);
      document.getElementById("xyb-b").value = out[2].toFixed(6);
    }

    function updateFromHsl() {
      const h = parseFloat(document.getElementById("hsl-h").value);
      const s = parseFloat(document.getElementById("hsl-s").value);
      const l = parseFloat(document.getElementById("hsl-l").value);
      if (h < 0) document.getElementById("hsl-h").value = 0;
      if (s < 0) document.getElementById("hsl-s").value = 0;
      if (l < 0) document.getElementById("hsl-l").value = 0;
      if (h >= 360) document.getElementById("hsl-h").value = 0;
      if (s > 100) document.getElementById("hsl-s").value = 100;
      if (l > 100) document.getElementById("hsl-l").value = 100;
      hsl2rgb(h, s, l);
      hsl2hsv(h, s, l);
      hsl2xyz(h, s, l);
      hsl2lab(h, s, l);
      hsl2lms(h, s, l);
      hsl2oklab(h, s, l);
      hsl2xyb(h, s, l);
      updateHex();
    }

    // --- HSV ---

    function hsv2rgb(h, s, v) {
      const outPtr = wasmExports.alloc(3);
      const out = new Uint8Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.hsv2rgb(h, s, v, outPtr);
      document.getElementById("rgb-r").value = out[0];
      document.getElementById("rgb-g").value = out[1];
      document.getElementById("rgb-b").value = out[2];
    }

    function hsv2hsl(h, s, v) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.hsv2hsl(h, s, v, outPtr);
      document.getElementById("hsl-h").value = out[0].toFixed(6);
      document.getElementById("hsl-s").value = out[1].toFixed(6);
      document.getElementById("hsl-l").value = out[2].toFixed(6);
    }

    function hsv2xyz(h, s, v) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.hsv2xyz(h, s, v, outPtr);
      document.getElementById("xyz-x").value = out[0].toFixed(6);
      document.getElementById("xyz-y").value = out[1].toFixed(6);
      document.getElementById("xyz-z").value = out[2].toFixed(6);
    }

    function hsv2lab(h, s, v) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.hsv2lab(h, s, v, outPtr);
      document.getElementById("lab-l").value = out[0].toFixed(6);
      document.getElementById("lab-a").value = out[1].toFixed(6);
      document.getElementById("lab-b").value = out[2].toFixed(6);
    }

    function hsv2lms(h, s, v) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.hsv2lms(h, s, v, outPtr);
      document.getElementById("lms-l").value = out[0].toFixed(6);
      document.getElementById("lms-m").value = out[1].toFixed(6);
      document.getElementById("lms-s").value = out[2].toFixed(6);
    }

    function hsv2oklab(h, s, v) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.hsv2oklab(h, s, v, outPtr);
      document.getElementById("oklab-l").value = out[0].toFixed(6);
      document.getElementById("oklab-a").value = out[1].toFixed(6);
      document.getElementById("oklab-b").value = out[2].toFixed(6);
    }

    function hsv2xyb(h, s, v) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.hsv2xyb(h, s, v, outPtr);
      document.getElementById("xyb-x").value = out[0].toFixed(6);
      document.getElementById("xyb-y").value = out[1].toFixed(6);
      document.getElementById("xyb-b").value = out[2].toFixed(6);
    }

    function updateFromHsv() {
      const h = parseFloat(document.getElementById("hsv-h").value);
      const s = parseFloat(document.getElementById("hsv-s").value);
      const v = parseFloat(document.getElementById("hsv-v").value);
      if (h < 0) document.getElementById("hsv-h").value = 0;
      if (s < 0) document.getElementById("hsv-s").value = 0;
      if (v < 0) document.getElementById("hsv-v").value = 0;
      if (h >= 360) document.getElementById("hsv-h").value = 0;
      if (s > 100) document.getElementById("hsv-s").value = 100;
      if (v > 100) document.getElementById("hsv-v").value = 100;
      hsv2rgb(h, s, v);
      hsv2hsl(h, s, v);
      hsv2xyz(h, s, v);
      hsv2lab(h, s, v);
      hsv2lms(h, s, v);
      hsv2oklab(h, s, v);
      hsv2xyb(h, s, v);
      updateHex();
    }

    // --- XYZ ---

    function xyz2rgb(x, y, z) {
      const outPtr = wasmExports.alloc(3);
      const out = new Uint8Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.xyz2rgb(x, y, z, outPtr);
      document.getElementById("rgb-r").value = out[0];
      document.getElementById("rgb-g").value = out[1];
      document.getElementById("rgb-b").value = out[2];
    }

    function xyz2hsl(x, y, z) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.xyz2hsl(x, y, z, outPtr);
      document.getElementById("hsl-h").value = out[0].toFixed(6);
      document.getElementById("hsl-s").value = out[1].toFixed(6);
      document.getElementById("hsl-l").value = out[2].toFixed(6);
    }

    function xyz2hsv(x, y, z) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.xyz2hsv(x, y, z, outPtr);
      document.getElementById("hsv-h").value = out[0].toFixed(6);
      document.getElementById("hsv-s").value = out[1].toFixed(6);
      document.getElementById("hsv-v").value = out[2].toFixed(6);
    }

    function xyz2lab(x, y, z) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.xyz2lab(x, y, z, outPtr);
      document.getElementById("lab-l").value = out[0].toFixed(6);
      document.getElementById("lab-a").value = out[1].toFixed(6);
      document.getElementById("lab-b").value = out[2].toFixed(6);
    }

    function xyz2lms(x, y, z) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.xyz2lms(x, y, z, outPtr);
      document.getElementById("lms-l").value = out[0].toFixed(6);
      document.getElementById("lms-m").value = out[1].toFixed(6);
      document.getElementById("lms-s").value = out[2].toFixed(6);
    }

    function xyz2oklab(x, y, z) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.xyz2oklab(x, y, z, outPtr);
      document.getElementById("oklab-l").value = out[0].toFixed(6);
      document.getElementById("oklab-a").value = out[1].toFixed(6);
      document.getElementById("oklab-b").value = out[2].toFixed(6);
    }

    function xyz2xyb(x, y, z) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.xyz2xyb(x, y, z, outPtr);
      document.getElementById("xyb-x").value = out[0].toFixed(6);
      document.getElementById("xyb-y").value = out[1].toFixed(6);
      document.getElementById("xyb-b").value = out[2].toFixed(6);
    }

    function updateFromXyz() {
      const x = parseFloat(document.getElementById("xyz-x").value);
      const y = parseFloat(document.getElementById("xyz-y").value);
      const z = parseFloat(document.getElementById("xyz-z").value);
      if (x < 0) document.getElementById("xyz-x").value = 0;
      if (y < 0) document.getElementById("xyz-y").value = 0;
      if (z < 0) document.getElementById("xyz-z").value = 0;
      if (x > 95.05) document.getElementById("xyz-x").value = 95.05;
      if (y > 100) document.getElementById("xyz-y").value = 100;
      if (z > 108.9) document.getElementById("xyz-z").value = 108.9;
      xyz2rgb(x, y, z);
      xyz2hsl(x, y, z);
      xyz2hsv(x, y, z);
      xyz2lab(x, y, z);
      xyz2lms(x, y, z);
      xyz2oklab(x, y, z);
      xyz2xyb(x, y, z);
      updateHex();
    }

    // --- LAB ---

    function lab2rgb(l, a, b) {
      const outPtr = wasmExports.alloc(3);
      const out = new Uint8Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.lab2rgb(l, a, b, outPtr);
      document.getElementById("rgb-r").value = out[0];
      document.getElementById("rgb-g").value = out[1];
      document.getElementById("rgb-b").value = out[2];
    }

    function lab2hsl(l, a, b) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.lab2hsl(l, a, b, outPtr);
      document.getElementById("hsl-h").value = out[0].toFixed(6);
      document.getElementById("hsl-s").value = out[1].toFixed(6);
      document.getElementById("hsl-l").value = out[2].toFixed(6);
    }

    function lab2hsv(l, a, b) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.lab2hsv(l, a, b, outPtr);
      document.getElementById("hsv-h").value = out[0].toFixed(6);
      document.getElementById("hsv-s").value = out[1].toFixed(6);
      document.getElementById("hsv-v").value = out[2].toFixed(6);
    }

    function lab2xyz(l, a, b) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.lab2xyz(l, a, b, outPtr);
      document.getElementById("xyz-x").value = out[0].toFixed(6);
      document.getElementById("xyz-y").value = out[1].toFixed(6);
      document.getElementById("xyz-z").value = out[2].toFixed(6);
    }

    function lab2lms(l, a, b) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.lab2lms(l, a, b, outPtr);
      document.getElementById("lms-l").value = out[0].toFixed(6);
      document.getElementById("lms-m").value = out[1].toFixed(6);
      document.getElementById("lms-s").value = out[2].toFixed(6);
    }

    function lab2oklab(l, a, b) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.lab2oklab(l, a, b, outPtr);
      document.getElementById("oklab-l").value = out[0].toFixed(6);
      document.getElementById("oklab-a").value = out[1].toFixed(6);
      document.getElementById("oklab-b").value = out[2].toFixed(6);
    }

    function lab2xyb(l, a, b) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.lab2xyb(l, a, b, outPtr);
      document.getElementById("xyb-x").value = out[0].toFixed(6);
      document.getElementById("xyb-y").value = out[1].toFixed(6);
      document.getElementById("xyb-b").value = out[2].toFixed(6);
    }

    function updateFromLab() {
      const l = parseFloat(document.getElementById("lab-l").value);
      const a = parseFloat(document.getElementById("lab-a").value);
      const b = parseFloat(document.getElementById("lab-b").value);
      if (l < 0) document.getElementById("lab-l").value = 0;
      if (a < -128) document.getElementById("lab-a").value = -128;
      if (b < -128) document.getElementById("lab-b").value = -128;
      if (l > 100) document.getElementById("lab-l").value = 100;
      if (a > 127) document.getElementById("lab-a").value = 127;
      if (b > 127) document.getElementById("lab-b").value = 127;
      lab2rgb(l, a, b);
      lab2hsl(l, a, b);
      lab2hsv(l, a, b);
      lab2xyz(l, a, b);
      lab2lms(l, a, b);
      lab2oklab(l, a, b);
      lab2xyb(l, a, b);
      updateHex();
    }

    // --- LMS ---

    function lms2rgb(l, m, s) {
      const outPtr = wasmExports.alloc(3);
      const out = new Uint8Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.lms2rgb(l, m, s, outPtr);
      document.getElementById("rgb-r").value = out[0];
      document.getElementById("rgb-g").value = out[1];
      document.getElementById("rgb-b").value = out[2];
    }

    function lms2hsl(l, m, s) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.lms2hsl(l, m, s, outPtr);
      document.getElementById("hsl-h").value = out[0].toFixed(6);
      document.getElementById("hsl-s").value = out[1].toFixed(6);
      document.getElementById("hsl-l").value = out[2].toFixed(6);
    }

    function lms2hsv(l, m, s) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.lms2hsv(l, m, s, outPtr);
      document.getElementById("hsv-h").value = out[0].toFixed(6);
      document.getElementById("hsv-s").value = out[1].toFixed(6);
      document.getElementById("hsv-v").value = out[2].toFixed(6);
    }

    function lms2xyz(l, m, s) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.lms2xyz(l, m, s, outPtr);
      document.getElementById("xyz-x").value = out[0].toFixed(6);
      document.getElementById("xyz-y").value = out[1].toFixed(6);
      document.getElementById("xyz-z").value = out[2].toFixed(6);
    }

    function lms2lab(l, m, s) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.lms2lab(l, m, s, outPtr);
      document.getElementById("lab-l").value = out[0].toFixed(6);
      document.getElementById("lab-a").value = out[1].toFixed(6);
      document.getElementById("lab-b").value = out[2].toFixed(6);
    }

    function lms2oklab(l, m, s) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.lms2oklab(l, m, s, outPtr);
      document.getElementById("oklab-l").value = out[0].toFixed(6);
      document.getElementById("oklab-a").value = out[1].toFixed(6);
      document.getElementById("oklab-b").value = out[2].toFixed(6);
    }

    function lms2xyb(l, m, s) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.lms2xyb(l, m, s, outPtr);
      document.getElementById("xyb-x").value = out[0].toFixed(6);
      document.getElementById("xyb-y").value = out[1].toFixed(6);
      document.getElementById("xyb-b").value = out[2].toFixed(6);
    }

    function updateFromLms() {
      const l = parseFloat(document.getElementById("lms-l").value);
      const a = parseFloat(document.getElementById("lms-m").value);
      const b = parseFloat(document.getElementById("lms-s").value);
      if (l < 0) document.getElementById("lms-l").value = 0;
      if (a < 0) document.getElementById("lms-m").value = 0;
      if (b < 0) document.getElementById("lms-s").value = 0;
      lms2rgb(l, a, b);
      lms2hsl(l, a, b);
      lms2hsv(l, a, b);
      lms2xyz(l, a, b);
      lms2lab(l, a, b);
      lms2oklab(l, a, b);
      lms2xyb(l, a, b);
      updateHex();
    }

    // --- Oklab---

    function oklab2rgb(l, a, b) {
      const outPtr = wasmExports.alloc(3);
      const out = new Uint8Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.oklab2rgb(l, a, b, outPtr);
      document.getElementById("rgb-r").value = out[0];
      document.getElementById("rgb-g").value = out[1];
      document.getElementById("rgb-b").value = out[2];
    }

    function oklab2hsl(l, a, b) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.oklab2hsl(l, a, b, outPtr);
      document.getElementById("hsl-h").value = out[0].toFixed(6);
      document.getElementById("hsl-s").value = out[1].toFixed(6);
      document.getElementById("hsl-l").value = out[2].toFixed(6);
    }

    function oklab2hsv(l, a, b) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.oklab2hsv(l, a, b, outPtr);
      document.getElementById("hsv-h").value = out[0].toFixed(6);
      document.getElementById("hsv-s").value = out[1].toFixed(6);
      document.getElementById("hsv-v").value = out[2].toFixed(6);
    }

    function oklab2xyz(l, a, b) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.oklab2xyz(l, a, b, outPtr);
      document.getElementById("xyz-x").value = out[0].toFixed(6);
      document.getElementById("xyz-y").value = out[1].toFixed(6);
      document.getElementById("xyz-z").value = out[2].toFixed(6);
    }

    function oklab2lab(l, a, b) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.oklab2lab(l, a, b, outPtr);
      document.getElementById("lab-l").value = out[0].toFixed(6);
      document.getElementById("lab-a").value = out[1].toFixed(6);
      document.getElementById("lab-b").value = out[2].toFixed(6);
    }

    function oklab2lms(l, a, b) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.oklab2lms(l, a, b, outPtr);
      document.getElementById("lms-l").value = out[0].toFixed(6);
      document.getElementById("lms-m").value = out[1].toFixed(6);
      document.getElementById("lms-s").value = out[2].toFixed(6);
    }

    function oklab2xyb(l, a, b) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.oklab2xyb(l, a, b, outPtr);
      document.getElementById("xyb-x").value = out[0].toFixed(6);
      document.getElementById("xyb-y").value = out[1].toFixed(6);
      document.getElementById("xyb-b").value = out[2].toFixed(6);
    }

    function updateFromOklab() {
      const l = parseFloat(document.getElementById("oklab-l").value);
      const a = parseFloat(document.getElementById("oklab-a").value);
      const b = parseFloat(document.getElementById("oklab-b").value);
      if (l < 0) document.getElementById("oklab-l").value = 0;
      if (a < -0.5) document.getElementById("oklab-a").value = -0.5;
      if (b < -0.5) document.getElementById("oklab-b").value = -0.5;
      if (l > 1) document.getElementById("oklab-l").value = 1;
      if (a > 0.5) document.getElementById("oklab-a").value = 0.5;
      if (b > 0.5) document.getElementById("oklab-b").value = 0.5;
      oklab2rgb(l, a, b);
      oklab2hsl(l, a, b);
      oklab2hsv(l, a, b);
      oklab2xyz(l, a, b);
      oklab2lms(l, a, b);
      oklab2lab(l, a, b);
      oklab2xyb(l, a, b);
      updateHex();
    }

    function xyb2rgb(x, y, b) {
      const outPtr = wasmExports.alloc(3);
      const out = new Uint8Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.xyb2rgb(x, y, b, outPtr);
      document.getElementById("rgb-r").value = out[0];
      document.getElementById("rgb-g").value = out[1];
      document.getElementById("rgb-b").value = out[2];
    }

    function xyb2hsl(x, y, b) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.xyb2hsl(x, y, b, outPtr);
      document.getElementById("hsl-h").value = out[0].toFixed(6);
      document.getElementById("hsl-s").value = out[1].toFixed(6);
      document.getElementById("hsl-l").value = out[2].toFixed(6);
    }

    function xyb2hsv(x, y, b) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.xyb2hsv(x, y, b, outPtr);
      document.getElementById("hsv-h").value = out[0].toFixed(6);
      document.getElementById("hsv-s").value = out[1].toFixed(6);
      document.getElementById("hsv-v").value = out[2].toFixed(6);
    }

    function xyb2lab(x, y, b) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.xyb2lab(x, y, b, outPtr);
      document.getElementById("lab-l").value = out[0].toFixed(6);
      document.getElementById("lab-a").value = out[1].toFixed(6);
      document.getElementById("lab-b").value = out[2].toFixed(6);
    }

    function xyb2xyz(x, y, b) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.xyb2xyz(x, y, b, outPtr);
      document.getElementById("xyz-x").value = out[0].toFixed(6);
      document.getElementById("xyz-y").value = out[1].toFixed(6);
      document.getElementById("xyz-z").value = out[2].toFixed(6);
    }

    function xyb2lms(x, y, b) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.xyb2lms(x, y, b, outPtr);
      document.getElementById("lms-l").value = Math.max(0, out[0]).toFixed(6);
      document.getElementById("lms-m").value = Math.max(0, out[1]).toFixed(6);
      document.getElementById("lms-s").value = Math.max(0, out[2]).toFixed(6);
    }

    function xyb2oklab(x, y, b) {
      const outPtr = wasmExports.alloc(3 * 4);
      const out = new Float64Array(wasmExports.memory.buffer, outPtr, 3);
      wasmExports.xyb2oklab(x, y, b, outPtr);
      document.getElementById("oklab-l").value = out[0].toFixed(6);
      document.getElementById("oklab-a").value = out[1].toFixed(6);
      document.getElementById("oklab-b").value = out[2].toFixed(6);
    }

    function updateFromXyb() {
      const x = parseFloat(document.getElementById("xyb-x").value);
      const y = parseFloat(document.getElementById("xyb-y").value);
      const b = parseFloat(document.getElementById("xyb-b").value);
      if (b < 0) document.getElementById("xyb-b").value = 0;
      xyb2rgb(x, y, b);
      xyb2hsl(x, y, b);
      xyb2hsv(x, y, b);
      xyb2xyz(x, y, b);
      xyb2lab(x, y, b);
      xyb2lms(x, y, b);
      xyb2oklab(x, y, b);
      updateHex();
    }
  });
})();
