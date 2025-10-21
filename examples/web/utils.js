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

  window.ZignalUtils = {
    createFileInput,
    enableDrop,
    createImageLoadHandler,
  };
})();
