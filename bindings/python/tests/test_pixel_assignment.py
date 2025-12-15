import zignal


class TestPixelAssignment:
    def test_assign_any_colorspace_to_rgb_image(self):
        img = zignal.Image(2, 2, dtype=zignal.Rgb)

        gray = zignal.Gray(128)
        img[0, 0] = gray
        px00 = img[0, 0].item()
        assert px00 == gray.to(zignal.Rgb)

        hsl = zignal.Hsl(0.0, 1.0, 0.5)  # red
        img[0, 1] = hsl
        expected = hsl.to(zignal.Rgb)
        px01 = img[0, 1].item()
        assert px01 == expected

        rgba = zignal.Rgba(1, 2, 3, 4)
        img[1, 0] = rgba
        px10 = img[1, 0].item()
        assert px10 == rgba.to(zignal.Rgb)

    def test_assign_any_colorspace_to_gray_image(self):
        img = zignal.Image(2, 2, dtype=zignal.Gray)

        rgb = zignal.Rgb(255, 255, 255)
        img[0, 0] = rgb
        assert img[0, 0] == rgb.to(zignal.Gray).y

        hsl = zignal.Hsl(0.33, 1.0, 0.5)
        img[0, 1] = hsl
        assert img[0, 1] == hsl.to(zignal.Gray).y
