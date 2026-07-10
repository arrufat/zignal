(function () {
  function createFileInput(onFile, options) {
    const input = document.createElement("input");
    input.type = "file";
    input.accept = options?.accept ?? "image/*";
    input.style.display = "none";
    input.addEventListener("change", function (event) {
      const file = event.target.files[0];
      if (file) onFile(file);
    });
    document.body.appendChild(input);
    return input;
  }

  function enableDrop(element, { onClick, onDrop }) {
    if (onClick) {
      element.addEventListener("click", onClick);
    }
    element.addEventListener("dragover", function (event) {
      event.preventDefault();
    });
    element.addEventListener("drop", function (event) {
      event.preventDefault();
      const file = event.dataTransfer.files[0];
      if (file && onDrop) onDrop(file);
    });
  }

  function createImageLoadHandler({ load, setLoaded, onError }) {
    return function (file) {
      setLoaded(false);
      Promise.resolve(load(file))
        .then(function () {
          setLoaded(true);
        })
        .catch(function (error) {
          if (onError) {
            onError(error);
          } else {
            console.error(error);
          }
        });
    };
  }

  // A native "Image / Camera" radio group for demos that accept either an
  // uploaded image or a live camera feed. onImage/onCamera fire only on user
  // selection; selectImage/selectCamera flip the state silently (no callback),
  // for when the demo switches modes itself (e.g. an image was dropped).
  function createModeSelector({ onImage, onCamera, name = "input-mode", label = "Mode" }) {
    const group = document.createElement("div");
    group.className = "mode-select";
    group.setAttribute("role", "radiogroup");
    group.setAttribute("aria-label", label);

    const caption = document.createElement("span");
    caption.className = "mode-label";
    caption.textContent = label;
    group.appendChild(caption);

    function makeOption(value, text, checked) {
      const wrap = document.createElement("label");
      const input = document.createElement("input");
      input.type = "radio";
      input.name = name;
      input.value = value;
      input.checked = checked;
      input.disabled = true;
      wrap.appendChild(input);
      wrap.appendChild(document.createTextNode(" " + text));
      group.appendChild(wrap);
      return input;
    }

    const imageInput = makeOption("image", "Image", true);
    const cameraInput = makeOption("camera", "Camera", false);
    group.classList.add("disabled");

    imageInput.addEventListener("change", function () {
      if (imageInput.checked && onImage) onImage();
    });
    cameraInput.addEventListener("change", function () {
      if (cameraInput.checked && onCamera) onCamera();
    });

    return {
      element: group,
      selectImage: function () {
        imageInput.checked = true;
      },
      selectCamera: function () {
        cameraInput.checked = true;
      },
      isCamera: function () {
        return cameraInput.checked;
      },
      setDisabled: function (disabled) {
        imageInput.disabled = disabled;
        cameraInput.disabled = disabled;
        group.classList.toggle("disabled", disabled);
      },
    };
  }

  window.ZignalUtils = {
    createFileInput,
    enableDrop,
    createImageLoadHandler,
    createModeSelector,
  };
})();
