# Zignal

<img src="https://github.com/bfactory-ai/zignal/blob/master/assets/liza.jpg" width=400> 

Zignal is an image processing library heavily inspired by the amazing [dlib](http://dlib.net).


## Reason of being

This library is used by [Ameli](https://ameli.co.kr/) for its makeup virtual try on.

## Features

Initially, the features in this library are the ones required to get the virtual makeup try on working.
However, we hope that it can be a foundation from which we can build a high quality image processing library, collaboratively.

Current features include:

- color space conversions
- simple matrix struct with common linear algebra operations
- singular value decomposition (SVD) ported from dlib
- geometry
  - points and rectangles
  - projective and similarity transforms
  - convex hull
- simple image struct with common operations (resize, rotate)
  - more features will be added soon, like cropping and blurring

## Examples

I plan to add examples for most of the features of this library as simple HTML/JS + Wasm. One of the greatest things about dlib
is the large amount of examples illustrating how to use many of that library features.

## Acknowledgements

First of all, this project would not have been possible without the existance of [dlib](http://dlib.net).
In fact, the first version of the virtual makeup try on was written in C++ with dlib and Emscripten.
However, we decided to give Zig a go, even if that meant rewriting the world, but we have no dependencies now.

Finally, [B factory, Inc](https://www.bfactory.ai/), which is my employer and graciously agreed to release this library to the public.
