"""裁切与旋转：方向、尺寸、不留黑边，以及参数校验。"""
from pathlib import Path
import sys
import unittest

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import geometry
from service import parameters


def half_colors(image):
    """左半和右半的平均颜色，用来判断有没有转反、翻反。"""
    array = np.asarray(image.convert('RGB'), np.float64)
    middle = array.shape[1] // 2
    return array[:, :middle].mean(axis=(0, 1)), array[:, middle:].mean(axis=(0, 1))


class GeometryTests(unittest.TestCase):
    def test_quarter_turns_swap_orientation(self):
        image = Image.new('RGB', (400, 200))
        self.assertEqual(geometry.apply(image, dict(rotation=90)).size, (200, 400))
        self.assertEqual(geometry.apply(image, dict(rotation=180)).size, (400, 200))
        self.assertEqual(geometry.apply(image, dict(rotation=270)).size, (200, 400))

    def test_clockwise_rotation_moves_left_edge_to_top(self):
        image = Image.new('RGB', (4, 2))
        image.paste((255, 0, 0), (0, 0, 2, 2))     # 左半边红
        image.paste((0, 0, 255), (2, 0, 4, 2))     # 右半边蓝
        turned = geometry.apply(image, dict(rotation=90))
        top = np.asarray(turned)[0, :, :].mean(axis=0)
        # 顺时针转 90°：原来在左边的红色跑到上边
        self.assertGreater(top[0], 200)
        self.assertLess(top[2], 60)

    def test_crop_keeps_requested_portion(self):
        image = Image.new('RGB', (400, 200))
        cropped = geometry.apply(image, dict(crop=[0.25, 0.5, 0.5, 0.5]))
        self.assertEqual(cropped.size, (200, 100))

    def test_crop_ignores_absurd_box_instead_of_crashing(self):
        image = Image.new('RGB', (100, 100))
        self.assertEqual(geometry.apply(image, dict(crop=[0.99, 0.99, 0.5, 0.5])).size, (100, 100))

    def test_flip_mirrors_sides(self):
        image = Image.new('RGB', (8, 4))
        image.paste((255, 0, 0), (0, 0, 4, 4))
        image.paste((0, 0, 255), (4, 0, 8, 4))
        left, right = half_colors(geometry.apply(image, dict(flip='h')))
        self.assertGreater(right[0], 200)
        self.assertLess(left[0], 60)

    def test_straighten_never_leaves_black_corners(self):
        image = Image.new('RGB', (300, 200), (240, 240, 240))
        for angle in (-8, -3, 2.5, 7):
            result = np.asarray(geometry.apply(image, dict(angle=angle)), np.float64)
            corners = [result[0, 0], result[0, -1], result[-1, 0], result[-1, -1]]
            for corner in corners:
                self.assertTrue((corner > 200).all(), f'{angle}° 时角落被填黑了')

    def test_neutral_when_nothing_set(self):
        self.assertTrue(geometry.is_neutral(dict(rotation=0, angle=0, flip='', crop=None)))
        self.assertFalse(geometry.is_neutral(dict(rotation=90)))
        self.assertFalse(geometry.is_neutral(dict(angle=1.5)))

    def test_parameters_accept_geometry_and_reject_bad_values(self):
        accepted = parameters(dict(rotation=270, angle=-3.5, flip='h', crop=[0.1, 0.1, 0.8, 0.8]))
        self.assertEqual(accepted['rotation'], 270)
        self.assertEqual(accepted['flip'], 'h')
        for bad in (dict(rotation=45), dict(flip='x'), dict(crop=[0.5, 0.5, 0.8, 0.8]), dict(crop=[0, 0, 1.2, 1])):
            with self.assertRaises(ValueError):
                parameters(bad)


if __name__ == '__main__':
    unittest.main()
