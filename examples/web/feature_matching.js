(function () {
  const canvas1 = document.getElementById("canvas1");
  const canvas2 = document.getElementById("canvas2");
  const ctx1 = canvas1.getContext("2d", { willReadFrequently: true });
  const ctx2 = canvas2.getContext("2d", { willReadFrequently: true });
  const matchButton = document.getElementById("match-button");
  const clearButton = document.getElementById("clear-button");
  const wrapper1 = document.getElementById("wrapper1");
  const wrapper2 = document.getElementById("wrapper2");
  const matchLines = document.getElementById("match-lines");
  const showKeypoints = document.getElementById("show-keypoints");
  const showMatches = document.getElementById("show-matches");

  let image1 = null;
  let image2 = null;
  let wasm_exports = null;
  let currentKeypoints1 = null;
  let currentKeypoints2 = null;
  let currentMatches = null;

  const text_decoder = new TextDecoder();

  function decodeString(ptr, len) {
    if (len === 0) return "";
    return text_decoder.decode(new Uint8Array(wasm_exports.memory.buffer, ptr, len));
  }

  function displayImage(canvas, ctx, file, imageNum) {
    const reader = new FileReader();
    reader.onload = function (e) {
      const img = new Image();
      img.onload = function () {
        // Limit image size to max 1024 on longest side for performance
        const maxSize = 1024;
        let width = img.width;
        let height = img.height;

        if (width > maxSize || height > maxSize) {
          const scale = Math.min(maxSize / width, maxSize / height);
          width = Math.floor(width * scale);
          height = Math.floor(height * scale);
          console.log(`Image ${imageNum} resized from ${img.width}x${img.height} to ${width}x${height}`);
        }

        if (imageNum === 1) {
          image1 = { img, width, height };
          wrapper1.classList.add("has-image");
        } else {
          image2 = { img, width, height };
          wrapper2.classList.add("has-image");
        }

        // Set canvas dimensions
        canvas.width = width;
        canvas.height = height;

        // Draw image
        ctx.drawImage(img, 0, 0, width, height);

        // Clear any existing visualization
        clearVisualization();

        // Enable match button if both images are loaded
        if (image1 && image2 && wasm_exports) {
          matchButton.disabled = false;
        }
      };
      img.src = e.target.result;
    };
    reader.readAsDataURL(file);
  }

  function clearVisualization() {
    // Redraw original images
    if (image1) {
      console.log("Redrawing image 1");
      ctx1.clearRect(0, 0, canvas1.width, canvas1.height);
      ctx1.drawImage(image1.img, 0, 0, image1.width, image1.height);
    }
    if (image2) {
      console.log("Redrawing image 2");
      ctx2.clearRect(0, 0, canvas2.width, canvas2.height);
      ctx2.drawImage(image2.img, 0, 0, image2.width, image2.height);
    }

    // Clear match lines
    matchLines.style.display = "none";
    matchLines.innerHTML = "";

    // Reset stats only if not actively showing results
    if (!currentKeypoints1 && !currentKeypoints2) {
      document.getElementById("features1").textContent = "-";
      document.getElementById("features2").textContent = "-";
      document.getElementById("matches").textContent = "-";
      document.getElementById("avg-distance").textContent = "-";
      document.getElementById("time").textContent = "-";
    }
  }

  function drawKeypoint(ctx, x, y, size, angle, octave) {
    if (!showKeypoints.checked) return;

    // Validate input
    if (isNaN(x) || isNaN(y) || isNaN(size) || isNaN(angle)) {
      console.warn("Invalid keypoint data:", { x, y, size, angle });
      return;
    }

    // Color based on octave
    const colors = [
      "#ff0000", // Red
      "#00ff00", // Green
      "#0000ff", // Blue
      "#ffff00", // Yellow
      "#ff00ff", // Magenta
      "#00ffff", // Cyan
      "#ff8800", // Orange
      "#8800ff", // Purple
    ];
    const color = colors[Math.min(octave, colors.length - 1)];

    ctx.save();

    // Draw circle with increased visibility
    ctx.strokeStyle = color;
    ctx.lineWidth = 3; // Increased from 2
    ctx.beginPath();
    const radius = Math.max(5, size / 2); // Increased minimum from 3 to 5
    ctx.arc(x, y, radius, 0, 2 * Math.PI);
    ctx.stroke();

    // Fill circle for better visibility
    ctx.fillStyle = color;
    ctx.globalAlpha = 0.3;
    ctx.fill();
    ctx.globalAlpha = 1.0;

    // Draw orientation line
    const angleRad = (angle * Math.PI) / 180;
    const lineLength = Math.max(8, size); // Increased from 5
    ctx.beginPath();
    ctx.moveTo(x, y);
    ctx.lineTo(x + Math.cos(angleRad) * lineLength, y + Math.sin(angleRad) * lineLength);
    ctx.lineWidth = 2;
    ctx.stroke();

    ctx.restore();
  }

  function drawMatches() {
    if (!showMatches.checked || !currentMatches || currentMatches.length === 0) {
      matchLines.style.display = "none";
      return;
    }

    // Get canvas positions relative to viewport
    const rect1 = canvas1.getBoundingClientRect();
    const rect2 = canvas2.getBoundingClientRect();

    // Account for CSS scaling between canvas internal pixels and on‑screen size
    // Canvas drawing uses the internal buffer (canvas.width/height). getBoundingClientRect
    // returns the displayed size in CSS pixels, which may differ (responsive CSS, DPR).
    const scaleX1 = rect1.width / canvas1.width;
    const scaleY1 = rect1.height / canvas1.height;
    const scaleX2 = rect2.width / canvas2.width;
    const scaleY2 = rect2.height / canvas2.height;

    console.log("Canvas positions:", {
      canvas1: { left: rect1.left, top: rect1.top, width: rect1.width, height: rect1.height },
      canvas2: { left: rect2.left, top: rect2.top, width: rect2.width, height: rect2.height },
    });

    // Set SVG to cover entire viewport with proper viewBox
    matchLines.style.display = "block";
    matchLines.style.position = "fixed";
    matchLines.style.left = "0px";
    matchLines.style.top = "0px";
    matchLines.style.width = `${window.innerWidth}px`;
    matchLines.style.height = `${window.innerHeight}px`;
    matchLines.style.pointerEvents = "none";
    matchLines.style.zIndex = "1000";
    matchLines.setAttribute("viewBox", `0 0 ${window.innerWidth} ${window.innerHeight}`);

    // Clear previous lines
    matchLines.innerHTML = "";

    // Draw match lines
    let debugCount = 0;
    for (const match of currentMatches) {
      const kp1 = currentKeypoints1[match.idx1];
      const kp2 = currentKeypoints2[match.idx2];

      // Calculate screen coordinates relative to viewport
      // Keypoints are in canvas pixel coordinates; convert to CSS pixels using scale factors
      const x1 = rect1.left + kp1.x * scaleX1;
      const y1 = rect1.top + kp1.y * scaleY1;
      const x2 = rect2.left + kp2.x * scaleX2;
      const y2 = rect2.top + kp2.y * scaleY2;

      // Debug first few matches
      if (debugCount < 3) {
        console.log(`Match ${debugCount}:`, {
          kp1: { x: kp1.x, y: kp1.y },
          kp2: { x: kp2.x, y: kp2.y },
          line: { x1, y1, x2, y2 },
        });
        debugCount++;
      }

      // Color based on match quality
      let color;
      if (match.distance < 30) {
        color = "#00ff00"; // Green - excellent
      } else if (match.distance < 50) {
        color = "#ffff00"; // Yellow - good
      } else if (match.distance < 70) {
        color = "#ff8800"; // Orange - fair
      } else {
        color = "#ff0000"; // Red - poor
      }

      // Create SVG line
      const line = document.createElementNS("http://www.w3.org/2000/svg", "line");
      line.setAttribute("x1", x1.toString());
      line.setAttribute("y1", y1.toString());
      line.setAttribute("x2", x2.toString());
      line.setAttribute("y2", y2.toString());
      line.setAttribute("stroke", color);
      line.setAttribute("stroke-width", "2");
      line.setAttribute("opacity", "0.6");
      matchLines.appendChild(line);
    }
  }

  // File inputs
  const fileInput1 = document.getElementById("file1");
  const fileInput2 = document.getElementById("file2");

  fileInput1.addEventListener("change", function (e) {
    const file = e.target.files[0];
    if (file) displayImage(canvas1, ctx1, file, 1);
  });

  fileInput2.addEventListener("change", function (e) {
    const file = e.target.files[0];
    if (file) displayImage(canvas2, ctx2, file, 2);
  });

  // Canvas clicks
  canvas1.addEventListener("click", () => fileInput1.click());
  canvas2.addEventListener("click", () => fileInput2.click());

  // Drag and drop
  function setupDragDrop(canvas, ctx, imageNum) {
    canvas.ondragover = (e) => e.preventDefault();
    canvas.ondrop = (e) => {
      e.preventDefault();
      const file = e.dataTransfer.files[0];
      if (file) displayImage(canvas, ctx, file, imageNum);
    };
  }

  setupDragDrop(canvas1, ctx1, 1);
  setupDragDrop(canvas2, ctx2, 2);

  // Clear button
  clearButton.addEventListener("click", clearVisualization);

  // Checkbox handlers
  showKeypoints.addEventListener("change", () => {
    if (currentKeypoints1 && currentKeypoints2) {
      clearVisualization();
      visualizeResults();
    }
  });

  showMatches.addEventListener("change", () => {
    drawMatches();
  });

  function visualizeResults() {
    console.log("Visualizing results...");
    console.log(`Drawing ${currentKeypoints1?.length || 0} keypoints on image 1`);
    console.log(`Drawing ${currentKeypoints2?.length || 0} keypoints on image 2`);
    console.log(`Drawing ${currentMatches?.length || 0} matches`);

    // Draw keypoints on image 1
    if (currentKeypoints1 && currentKeypoints1.length > 0) {
      for (const kp of currentKeypoints1) {
        drawKeypoint(ctx1, kp.x, kp.y, kp.size, kp.angle, kp.octave);
      }
    }

    // Draw keypoints on image 2
    if (currentKeypoints2 && currentKeypoints2.length > 0) {
      for (const kp of currentKeypoints2) {
        drawKeypoint(ctx2, kp.x, kp.y, kp.size, kp.angle, kp.octave);
      }
    }

    // Draw match lines
    drawMatches();
  }

  // Match button
  matchButton.addEventListener("click", function () {
    if (!image1 || !image2) {
      alert("Please load both images first");
      return;
    }

    const startTime = performance.now();

    // Get image data
    const imageData1 = ctx1.getImageData(0, 0, canvas1.width, canvas1.height);
    const imageData2 = ctx2.getImageData(0, 0, canvas2.width, canvas2.height);

    const size1 = image1.height * image1.width * 4;
    const size2 = image2.height * image2.width * 4;

    // Allocate memory for images
    const img1Ptr = wasm_exports.alloc(size1) >>> 0;
    const img2Ptr = wasm_exports.alloc(size2) >>> 0;

    // Allocate memory for results (generous allocation)
    const maxFeatures = 500;
    const resultSize = (maxFeatures * 5 + 1) * 2 + (maxFeatures * 3 + 1); // number of floats
    const resultBytes = resultSize * 4; // convert to bytes
    const resultPtr = wasm_exports.alloc(resultBytes) >>> 0;

    // Copy image data to WASM memory
    const img1Array = new Uint8ClampedArray(wasm_exports.memory.buffer, img1Ptr, size1);
    const img2Array = new Uint8ClampedArray(wasm_exports.memory.buffer, img2Ptr, size2);
    img1Array.set(imageData1.data);
    img2Array.set(imageData2.data);

    // Call WASM function
    // Note: resultPtr is already a byte pointer, we pass it directly as Zig will interpret it correctly
    const numResults = wasm_exports.detectAndMatch(
      img1Ptr,
      image1.height,
      image1.width,
      img2Ptr,
      image2.height,
      image2.width,
      resultPtr, // Pass pointer directly - Zig expects [*]f32 and will cast appropriately
      maxFeatures,
      50.0, // max_distance - reduced for better matching
    );

    if (numResults > 0) {
      // Parse results
      const results = new Float32Array(wasm_exports.memory.buffer, resultPtr, numResults);
      let idx = 0;

      // Parse keypoints from image 1
      const numKp1 = results[idx++];
      currentKeypoints1 = [];
      console.log(`Parsing ${numKp1} keypoints from image 1`);
      for (let i = 0; i < numKp1; i++) {
        const kp = {
          x: results[idx++],
          y: results[idx++],
          size: results[idx++],
          angle: results[idx++],
          octave: Math.floor(results[idx++]),
        };
        currentKeypoints1.push(kp);
        if (i < 3) console.log(`KP1[${i}]:`, kp); // Log first few keypoints
      }

      // Parse keypoints from image 2
      const numKp2 = results[idx++];
      currentKeypoints2 = [];
      console.log(`Parsing ${numKp2} keypoints from image 2`);
      for (let i = 0; i < numKp2; i++) {
        const kp = {
          x: results[idx++],
          y: results[idx++],
          size: results[idx++],
          angle: results[idx++],
          octave: Math.floor(results[idx++]),
        };
        currentKeypoints2.push(kp);
        if (i < 3) console.log(`KP2[${i}]:`, kp); // Log first few keypoints
      }

      // Parse matches
      const numMatches = results[idx++];
      currentMatches = [];
      let totalDistance = 0;
      console.log(`Parsing ${numMatches} matches`);
      for (let i = 0; i < numMatches; i++) {
        const match = {
          idx1: Math.floor(results[idx++]),
          idx2: Math.floor(results[idx++]),
          distance: results[idx++],
        };
        currentMatches.push(match);
        totalDistance += match.distance;
        if (i < 3) console.log(`Match[${i}]:`, match); // Log first few matches
      }
      console.log(`Average match distance: ${totalDistance / numMatches}`);

      // Update stats
      document.getElementById("features1").textContent = numKp1;
      document.getElementById("features2").textContent = numKp2;
      document.getElementById("matches").textContent = numMatches;

      if (numMatches > 0) {
        const avgDistance = totalDistance / numMatches;
        document.getElementById("avg-distance").textContent = avgDistance.toFixed(2);
      } else {
        document.getElementById("avg-distance").textContent = "-";
      }

      // Clear and redraw with visualization
      console.log("Clearing and redrawing visualization...");
      clearVisualization();
      visualizeResults();
    }

    const timeMs = performance.now() - startTime;
    document.getElementById("time").textContent = timeMs.toFixed(0);

    // Free memory
    wasm_exports.free(img1Ptr, size1);
    wasm_exports.free(img2Ptr, size2);
    wasm_exports.free(resultPtr, resultBytes);
  });

  // Load WASM module
  fetch("feature_matching.wasm")
    .then((response) =>
      WebAssembly.instantiateStreaming(response, {
        js: {
          log: function (ptr, len) {
            const msg = decodeString(ptr, len);
            console.log(msg);
          },
          now: function () {
            return performance.now();
          },
        },
      }),
    )
    .then(function (obj) {
      window.wasm = obj;
      wasm_exports = obj.instance.exports;

      // Enable match button if both images are already loaded
      if (image1 && image2) {
        matchButton.disabled = false;
      }

      console.log("WASM module loaded successfully");
    })
    .catch(function (err) {
      console.error("Failed to load WASM module:", err);
      alert("Failed to load WASM module. Check the console for details.");
    });
})();
