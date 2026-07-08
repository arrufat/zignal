"""Tests for QR code encoding and decoding."""

import pytest

import zignal


class TestQrCodeEncode:
    def test_returns_square_grayscale_image(self):
        img = zignal.qrcode_encode("hello", module_size=2, quiet_zone=4)
        assert isinstance(img, zignal.Image)
        assert img.rows == img.cols
        # Version 1 (21 modules) plus 2 * 4 quiet zone modules, 2 px each.
        assert img.rows == (21 + 8) * 2

    def test_forced_version_and_module_size(self):
        img = zignal.qrcode_encode("hi", version=5, module_size=1, quiet_zone=0)
        assert img.rows == 17 + 4 * 5

    def test_data_too_large(self):
        with pytest.raises(ValueError):
            zignal.qrcode_encode("A" * 8000)

    def test_invalid_version(self):
        with pytest.raises(ValueError):
            zignal.qrcode_encode("hi", version=41)

    def test_invalid_module_size(self):
        with pytest.raises(ValueError):
            zignal.qrcode_encode("hi", module_size=0)

    def test_rejects_non_string_data(self):
        with pytest.raises(TypeError):
            zignal.qrcode_encode(123)


class TestQrCodeDecode:
    def test_roundtrip_text(self):
        text = "https://github.com/arrufat/zignal"
        img = zignal.qrcode_encode(text)
        result = zignal.qrcode_decode(img)
        assert result is not None
        assert result.text == text
        assert result.data == text.encode()
        assert result.version >= 1
        assert result.ec_level == zignal.EcLevel.MEDIUM
        assert result.corrected_errors == 0

    def test_roundtrip_binary(self):
        payload = bytes(range(256))
        img = zignal.qrcode_encode(payload, ec_level=zignal.EcLevel.LOW)
        result = zignal.qrcode_decode(img)
        assert result is not None
        assert result.data == payload

    def test_ec_level_roundtrip(self):
        for level in (zignal.EcLevel.LOW, zignal.EcLevel.MEDIUM, zignal.EcLevel.QUARTILE, zignal.EcLevel.HIGH):
            img = zignal.qrcode_encode("ec level test", ec_level=level)
            result = zignal.qrcode_decode(img)
            assert result is not None
            assert result.ec_level == level

    def test_ec_level_accepts_int(self):
        img = zignal.qrcode_encode("int level", ec_level=int(zignal.EcLevel.HIGH))
        result = zignal.qrcode_decode(img)
        assert result is not None
        assert result.ec_level == zignal.EcLevel.HIGH

    def test_corners_present_and_ordered(self):
        module_size, quiet_zone = 4, 4
        img = zignal.qrcode_encode("corners", module_size=module_size, quiet_zone=quiet_zone)
        result = zignal.qrcode_decode(img)
        assert result is not None
        corners = result.corners
        assert corners is not None and len(corners) == 4
        # Top-left corner sits at the quiet zone edge.
        x, y = corners[0]
        assert x == pytest.approx(quiet_zone * module_size, abs=module_size)
        assert y == pytest.approx(quiet_zone * module_size, abs=module_size)

    def test_decode_color_image(self):
        gray = zignal.qrcode_encode("color conversion")
        rgb = gray.convert(zignal.Rgb)
        result = zignal.qrcode_decode(rgb)
        assert result is not None
        assert result.text == "color conversion"

    def test_no_qr_code_returns_none(self):
        blank = zignal.Image(64, 64, 255, dtype=zignal.Gray)
        assert zignal.qrcode_decode(blank) is None

    def test_rejects_non_image(self):
        with pytest.raises(TypeError):
            zignal.qrcode_decode("not an image")

    def test_repr(self):
        result = zignal.qrcode_decode(zignal.qrcode_encode("repr"))
        assert result is not None
        assert "QrDecodeResult" in repr(result)
