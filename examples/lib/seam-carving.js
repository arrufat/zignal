(function () {
  let wasmPromise = fetch("seam_carving.wasm");
  var wasmExports = null;
  const text_decoder = new TextDecoder();
  let image = null;

  const removeButton = document.getElementById("remove-button");
  const canvas = document.getElementById("canvas-seam");
  const ctx = canvas.getContext("2d");
  canvas.ondragover = function (event) {
    event.preventDefault();
  };

  function displayImageSize() {
    let sizeElement = document.getElementById("size");
    sizeElement.textContent = "size: " + canvas.width + "×" + canvas.height + " px.";
  }

  canvas.ondrop = function (event) {
    event.preventDefault();
    let img = new Image();
    img.onload = function () {
      canvas.width = img.width;
      canvas.height = img.height;
      ctx.drawImage(img, 0, 0);
      image = ctx.getImageData(0, 0, canvas.width, canvas.height);
      original = new ImageData(image.width, image.height);
      original.data.set(image.data);
      displayImageSize();
    };
    img.src = URL.createObjectURL(event.dataTransfer.files[0]);
  };

  function displayImage(file) {
    const reader = new FileReader();
    reader.onload = function (e) {
      const imageData = e.target.result;
      const img = document.createElement("img");
      img.src = imageData;
      img.onload = function () {
        canvas.width = img.width;
        canvas.height = img.height;
        ctx.drawImage(img, 0, 0);
        image = ctx.getImageData(0, 0, canvas.width, canvas.height);
        original = new ImageData(image.width, image.height);
        original.data.set(image.data);
        displayImageSize();
      };
    };
    reader.readAsDataURL(file);
  }

  const fileInput = document.createElement("input");
  fileInput.type = "file";
  fileInput.style.display = "none";
  fileInput.addEventListener("change", function (e) {
    const file = e.target.files[0];
    displayImage(file);
  });

  canvas.addEventListener("click", function () {
    fileInput.click();
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

    let copy = null;
    function seamCarve() {
      if (copy) {
        ctx.putImageData(copy, 0, 0);
      }
      const rows = image.height;
      const cols = image.width;
      const rgbaSize = rows * cols * 4;
      const rgbaPtr = wasmExports.alloc(rgbaSize);
      const seamSize = rows * 4;
      const seamPtr = wasmExports.alloc(seamSize);
      const extraSize = rows * cols * 10;
      const extraPtr = wasmExports.alloc(extraSize);
      var rgba = new Uint8ClampedArray(wasmExports.memory.buffer, rgbaPtr, rgbaSize);
      var seam = new Uint32Array(wasmExports.memory.buffer, seamPtr, image.height);
      image = ctx.getImageData(0, 0, canvas.width, canvas.height);
      rgba.set(image.data);
      wasmExports.seam_carve(rgbaPtr, rows, cols, extraPtr, extraSize, seamPtr, rows);
      canvas.width = cols - 1;
      image = ctx.getImageData(0, 0, canvas.width, canvas.height);
      rgba = new Uint8ClampedArray(wasmExports.memory.buffer, rgbaPtr, rgbaSize - 4 * rows);

      image.data.set(rgba);
      ctx.putImageData(image, 0, 0);
      copy = ctx.getImageData(0, 0, canvas.width, canvas.height);
      displayImageSize();

      for (let i = 1; i < rows; ++i) {
        ctx.beginPath();
        ctx.moveTo(seam[i - 1], [i - 1]);
        ctx.lineTo(seam[i], [i]);
        ctx.strokeStyle = "red";
        ctx.lineWidth = 1;
        ctx.stroke();
      }

      wasmExports.free(rgbaPtr, rgbaSize);
      wasmExports.free(extraPtr, extraSize);
    }
    removeButton.addEventListener("click", () => {
      seamCarve();
    });
  });
})();
