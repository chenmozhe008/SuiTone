"""参考图张数必须跟服务商官方文档一致，改代码时不要顺手放宽。

数字来源（2026-10-30 核对）：
- 火山方舟 图片生成 API：Seedream 5.0 pro / 5.0 flash 最多 10 张参考图；5.0 lite / 4.5 / 4.0 最多 14 张。
- Gemini 模型规格：gemini-2.5-flash-image 每个提示最多 3 张图；Nano Banana 2.1 / 3 Pro Image 最多 14 张。
"""
from pathlib import Path
import sys, unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from image_edit import image_limit, reference_limit, reference_limits


class ImageLimitTests(unittest.TestCase):
    def test_seedream_50_pro_and_flash_allow_ten_images(self):
        self.assertEqual(image_limit('jimeng', 'doubao-seedream-5-0-pro-260628'), 10)
        self.assertEqual(image_limit('jimeng', 'doubao-seedream-5-0-flash-260915'), 10)
        # 原图占一个位置，所以还能加 9 张参考图
        self.assertEqual(reference_limit('jimeng', 'doubao-seedream-5-0-pro-260628'), 9)

    def test_seedream_50_lite_and_4x_allow_fourteen_images(self):
        for model in ['doubao-seedream-5-0-260128', 'doubao-seedream-4-5-251128', 'doubao-seedream-4-0-250828']:
            self.assertEqual(image_limit('jimeng', model), 14, model)
            self.assertEqual(reference_limit('jimeng', model), 13, model)

    def test_gemini_25_flash_image_allows_three_images(self):
        self.assertEqual(image_limit('gemini', 'gemini-2.5-flash-image'), 3)
        self.assertEqual(reference_limit('gemini', 'gemini-2.5-flash-image'), 2)

    def test_gemini_nano_banana_and_3_pro_allow_fourteen_images(self):
        for model in ['gemini-nano-banana-2.1', 'gemini-3-pro-image']:
            self.assertEqual(image_limit('gemini', model), 14, model)

    def test_unknown_model_falls_back_to_the_conservative_series_rule(self):
        self.assertEqual(image_limit('jimeng', 'doubao-seedream-4-0-240000'), 14)
        self.assertEqual(image_limit('gemini', 'gemini-2.5-flash-image-preview'), 3)
        # 完全不认识的型号：只让带原图，不硬塞参考图
        self.assertEqual(image_limit('jimeng', 'something-else'), 1)
        self.assertEqual(reference_limit('jimeng', 'something-else'), 0)

    def test_service_limits_cover_every_listed_model(self):
        for service in ('jimeng', 'gemini'):
            limits = reference_limits(service)
            self.assertTrue(limits, service)
            self.assertTrue(all(isinstance(v, int) and v >= 0 for v in limits.values()), service)


if __name__ == '__main__':
    unittest.main()
