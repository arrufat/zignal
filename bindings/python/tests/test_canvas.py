"""Bindings-level smoke tests for Canvas API."""

import zignal


class TestCanvasSmoke:
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
