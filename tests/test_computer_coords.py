"""The picture ↔ screen arithmetic of the hands (nanomuse.computer.coords): UI-TARS's
smart resize on known sizes, the picture size the model gets, the 0–1000 grid, boxes,
and the mapping of picture pixels onto the hands' screen space and onto fractions."""

from __future__ import annotations

import pytest

from nanomuse.computer.coords import (
    IMAGE_FACTOR,
    MAX_PIXELS,
    MIN_PIXELS,
    Mapping,
    box_centre,
    from_norm,
    picture_size,
    smart_resize,
)


@pytest.mark.parametrize(
    ("height", "width", "expected"),
    [
        (1080, 1920, (1932, 1092)),  # Qwen2.5-VL's own example: 1920×1080 → 1932×1092
        (2160, 3840, (3836, 2156)),  # a 4K screen, under the pixel cap: rounded to 28s
        (900, 1600, (1596, 896)),  # the default max_image_width, 16:10-ish
        (1092, 1932, (1932, 1092)),  # already a multiple of 28: the identity
        (8000, 8000, (3584, 3584)),  # over the cap: shrunk, floored to 28s
        (3, 4, (336, 252)),  # under the floor: grown, ceiled to 28s
    ],
)
def test_smart_resize_known_values(height: int, width: int, expected: tuple[int, int]) -> None:
    assert smart_resize(height, width) == expected


def test_smart_resize_keeps_the_contract() -> None:
    for w, h in ((1366, 768), (2560, 1440), (1440, 900), (5120, 2880), (800, 1280), (640, 480)):
        pw, ph = smart_resize(h, w)
        assert pw % IMAGE_FACTOR == 0 and ph % IMAGE_FACTOR == 0
        assert MIN_PIXELS <= pw * ph <= MAX_PIXELS
        # the aspect ratio moves by less than one factor on each side
        assert abs(pw / ph - w / h) < IMAGE_FACTOR / min(pw, ph) * 2
    with pytest.raises(ValueError, match="aspect ratio"):
        smart_resize(10, 10_000)
    with pytest.raises(ValueError, match="positive"):
        smart_resize(0, 100)


def test_picture_size_caps_then_resizes() -> None:
    # a 4K X11 screen with the default cap: 1600 wide, then to multiples of 28
    assert picture_size(3840, 2160, 1600) == (1596, 896)
    # no width cap: the screen's own size rounded (1680×1050 is under the pixel budget)
    assert picture_size(1680, 1050, 0) == (1680, 1064)
    # a cap wider than the screen changes nothing but the rounding
    assert picture_size(1440, 900, 1600) == (1428, 896)
    assert picture_size(0, 0, 1600) == (0, 0)


def test_picture_size_keeps_the_pixel_budget() -> None:
    # the shared rule: at most 2 Mpx before encoding. A 4K screen with no width cap comes
    # down to about half its side; the aspect ratio is kept
    w, h = picture_size(3840, 2160, 0)
    assert w * h <= 2_000_000 and abs(w / h - 16 / 9) < 0.02
    # 1080p (2.07 Mpx) is trimmed a little, in either orientation
    assert picture_size(1920, 1080, 0) == (1876, 1064)
    assert picture_size(1080, 1920, 0) == (1064, 1876)
    # max_pixels=0 switches the budget off; a tighter one is honoured
    assert picture_size(3840, 2160, 0, max_pixels=0) == (3836, 2156)
    w, h = picture_size(1920, 1080, 0, max_pixels=500_000)
    assert w * h <= 520_000  # smart_resize rounds to 28s, a little over is the rounding


def test_boxes_and_the_norm_grid() -> None:
    assert box_centre([10, 20, 30, 40]) == (20.0, 30.0)
    assert box_centre([7, 9]) == (7.0, 9.0)
    with pytest.raises(ValueError):
        box_centre([1, 2, 3])
    # UI-TARS's parseBoxToScreenCoords: 0.131 of 2560 → 335.36 (rounded to the grid)
    assert from_norm(131, 250, 2560, 1440) == (335.36, 360.0)
    assert from_norm(500, 500, 1000, 1000) == (500.0, 500.0)
    assert from_norm(1000, 0, 1596, 896) == (1596.0, 0.0)


def test_mapping_picture_to_screen_and_fractions() -> None:
    # the picture is 1596×896 of a 3840×2160 screen (4K, X11: the hands move in root pixels)
    m = Mapping(1596, 896, 3840, 2160)
    sx, sy = m.scale
    assert round(sx, 4) == round(3840 / 1596, 4) and round(sy, 4) == round(2160 / 896, 4)
    assert m.to_screen(798, 448) == (1920.0, 1080.0)
    assert m.to_screen(0, 0) == (0.0, 0.0)
    assert m.to_screen(1596, 896) == (3840.0, 2160.0)
    # one past the edge means the edge
    assert m.to_screen(1700, -5) == (3840.0, 0.0)
    assert m.fractions(798, 448) == (0.5, 0.5)
    assert m.fractions(1596, 896) == (1.0, 1.0)
    # a Retina Mac: the capture is 2880×1800 pixels, the picture 1596×996, the hands
    # (pyautogui) move in 1440×900 points — the screen space is the points, not the capture
    mac = Mapping(1596, 996, 1440, 900)
    x, y = mac.to_screen(798, 498)
    assert (round(x), round(y)) == (720, 450)
    # a device that taps where it looks: 1:1
    assert Mapping(720, 1600, 720, 1600).to_screen(100, 200) == (100.0, 200.0)
    # unknown sizes: nothing is scaled, nothing is clamped
    assert Mapping(0, 0, 0, 0).to_screen(12.5, 7) == (12.5, 7.0)
    assert Mapping(0, 0, 0, 0).fractions(12.5, 7) == (0.0, 0.0)
