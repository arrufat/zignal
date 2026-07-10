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

  // A native radio group styled via `.mode-select`. `options` is a list of
  // { value, label }; onChange fires with the chosen value on user selection.
  // `select` flips state silently (no callback). Starts disabled by default.
  function createRadioGroup({ label, name, options, value, onChange, disabled = true }) {
    const group = document.createElement("div");
    group.className = "mode-select";
    group.setAttribute("role", "radiogroup");
    group.setAttribute("aria-label", label);

    const caption = document.createElement("span");
    caption.className = "mode-label";
    caption.textContent = label;
    group.appendChild(caption);

    const inputs = {};
    options.forEach(function (opt) {
      const wrap = document.createElement("label");
      const input = document.createElement("input");
      input.type = "radio";
      input.name = name;
      input.value = opt.value;
      input.checked = opt.value === value;
      input.disabled = disabled;
      input.addEventListener("change", function () {
        if (input.checked && onChange) onChange(opt.value);
      });
      wrap.appendChild(input);
      wrap.appendChild(document.createTextNode(" " + opt.label));
      group.appendChild(wrap);
      inputs[opt.value] = input;
    });
    group.classList.toggle("disabled", disabled);

    return {
      element: group,
      select: function (v) {
        if (inputs[v]) inputs[v].checked = true;
      },
      setDisabled: function (d) {
        for (const v in inputs) inputs[v].disabled = d;
        group.classList.toggle("disabled", d);
      },
    };
  }

  // "Image / Camera" source selector, built on createRadioGroup. onImage/onCamera
  // fire only on user selection; selectImage flips state silently, for when the
  // demo switches modes itself (e.g. an image was dropped).
  function createModeSelector({ onImage, onCamera, name = "input-mode", label = "Mode" }) {
    const group = createRadioGroup({
      label: label,
      name: name,
      value: "image",
      options: [
        { value: "image", label: "Image" },
        { value: "camera", label: "Camera" },
      ],
      onChange: function (v) {
        if (v === "camera") {
          if (onCamera) onCamera();
        } else if (onImage) {
          onImage();
        }
      },
    });
    return {
      element: group.element,
      selectImage: function () {
        group.select("image");
      },
      setDisabled: function (d) {
        group.setDisabled(d);
      },
    };
  }

  window.ZignalUtils = {
    createFileInput,
    enableDrop,
    createImageLoadHandler,
    createRadioGroup,
    createModeSelector,
  };
})();
