import zignal


class TestCanvas:
    def test_create_and_draw(self):
        img = zignal.Image(20, 30, 0)
        canvas = img.canvas()
        # Draw a few primitives; just assert it modifies the image
        before = img.copy()
        canvas.fill((10, 20, 30))
        canvas.draw_line((0, 0), (10, 10), (255, 0, 0))
        rect = zignal.Rectangle(5, 5, 15, 15)
        canvas.draw_rectangle(rect, (0, 255, 0))
        canvas.fill_circle((10, 10), 3, (0, 0, 255))
        assert img != before

    def test_color_inputs(self):
        img = zignal.Image(10, 10, 0)
        canvas = img.canvas()
        # Tuples
        canvas.fill((1, 2, 3))
        canvas.fill((1, 2, 3, 200))
        # Color objects
        canvas.fill(zignal.Rgb(4, 5, 6))
        canvas.draw_line((0, 0), (5, 5), zignal.Rgba(7, 8, 9, 255))

    def test_accepts_any_colorspace_and_auto_converts(self):
        # Rgba canvas fill should accept any colorspace object.
        rgba_img = zignal.Image(3, 3, (0, 0, 0, 0), dtype=zignal.Rgba)
        rgba_canvas = rgba_img.canvas()

        hsl = zignal.Hsl(0.0, 1.0, 0.5)  # red
        rgba_canvas.fill(hsl)
        expected_rgba = hsl.to(zignal.Rgba)
        got_rgba = rgba_img[1, 1].item()
        assert got_rgba == expected_rgba

        # Rgb canvas fill should accept float-backed colors too.
        rgb_img = zignal.Image(3, 3, (0, 0, 0), dtype=zignal.Rgb)
        rgb_canvas = rgb_img.canvas()
        lab = zignal.Lab(0.7, 0.0, 0.0)
        rgb_canvas.fill(lab)
        expected_rgb = lab.to(zignal.Rgb)
        got_rgb = rgb_img[0, 0].item()
        assert got_rgb == expected_rgb

        # Gray canvas should accept non-gray colors and convert to luminance.
        gray_img = zignal.Image(3, 3, 0, dtype=zignal.Gray)
        gray_canvas = gray_img.canvas()
        gray_canvas.fill(hsl)
        assert gray_img[0, 0] == hsl.to(zignal.Gray).y

    def test_draw_image(self):
        dest = zignal.Image(6, 6, (0, 0, 0, 255), dtype=zignal.Rgba)
        canvas = dest.canvas()

        sprite = zignal.Image(2, 2, (255, 0, 0, 128), dtype=zignal.Rgba)
        sprite[0, 1] = zignal.Rgba(0, 255, 0, 255)
        sprite[1, 0] = zignal.Rgba(0, 0, 255, 255)

        before = dest.copy()
        canvas.draw_image(sprite, (2.0, 2.0))
        assert dest != before

        blended = dest[2, 2].item()
        assert blended.r > 0
        assert blended.g == 0

        # Use a source rect to copy only left column of sprite to top-left corner
        src_rect = zignal.Rectangle(0, 0, 1, sprite.rows)
        canvas.draw_image(sprite, (0.0, 0.0), src_rect)
        top_left = dest[0, 0].item()
        assert top_left.r == 128
        assert top_left.g == 0
