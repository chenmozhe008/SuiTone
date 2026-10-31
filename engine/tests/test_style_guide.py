from pathlib import Path
import sys
import unittest
import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from analysis import Analysis
from smart import STYLES, STYLE_SCENES
from style_guide import HEADLINE, rank, recommend, scene_of


def fake(person=0., sky=0., land=0., water=0., luma=50., chroma=10., shadow_fraction=0.):
    """造一份只带统计量的分析对象，避免测试里真的跑分割模型。"""
    width, height = 80, 60
    result = Analysis.__new__(Analysis)
    result.image = Image.new('RGB', (width, height))
    result.rgb = np.zeros((height, width, 3))
    lab = np.zeros((height, width, 3))
    lab[..., 0] = luma
    lab[..., 1] = chroma * .7
    lab[..., 2] = chroma * .7
    if shadow_fraction:
        lab[:int(height * shadow_fraction), :, 0] = 2
    result.lab = lab
    result.dehazed = None

    def region(area):
        mask = np.zeros((height, width))
        mask[:int(round(height * area)), :] = .9  # summary 只统计 > .65 的像素
        return mask

    for name, area in (('person', person), ('sky', sky), ('land', land), ('water', water)):
        setattr(result, name, region(area))
    result.skin = np.zeros((height, width))
    return result


class StyleGuideTests(unittest.TestCase):
    def test_scene_detection(self):
        self.assertEqual(scene_of(_stats(fake(person=.34, luma=50))), 'portrait')
        self.assertEqual(scene_of(_stats(fake(sky=.4, land=.4, luma=55))), 'landscape')
        self.assertEqual(scene_of(_stats(fake(luma=18, shadow_fraction=.45))), 'night')
        self.assertEqual(scene_of(_stats(fake(luma=50))), 'daily')

    def test_small_figure_in_a_wide_shot_stays_landscape(self):
        # 风光照里站着一个人，不该整张按人像来推荐。
        self.assertEqual(scene_of(_stats(fake(person=.1, sky=.4, land=.4, luma=55))), 'landscape')

    def test_portrait_keeps_styles_that_protect_skin(self):
        guide = recommend(fake(person=.34, luma=50))
        self.assertEqual(guide['scene'], 'portrait')
        self.assertIn('portra', guide['creative'])
        self.assertEqual(len(guide['creative']), HEADLINE)
        for style in ('mono', 'sepia', 'silver', 'noir'):
            self.assertNotIn(style, guide['creative'], '会吃掉肤色的黑白／棕调不该进人像首屏')

    def test_landscape_does_not_lead_with_night_styles(self):
        guide = recommend(fake(sky=.4, land=.4, luma=55))
        self.assertEqual(guide['scene'], 'landscape')
        for style in ('nightfilm', 'neon'):
            self.assertNotIn(style, guide['creative'])

    def test_night_photo_gets_night_styles_first(self):
        guide = recommend(fake(luma=18, shadow_fraction=.45))
        self.assertEqual(guide['scene'], 'night')
        self.assertTrue({'nightfilm', 'neon', 'bluehour'} & set(guide['creative']))

    def test_every_style_has_a_scene_label(self):
        self.assertEqual({style['id'] for style in STYLES}, set(STYLE_SCENES))

    def test_headline_is_filled_and_belongs_to_its_family(self):
        analysis = fake(sky=.4, land=.4, luma=55)
        guide = recommend(analysis)
        families = {style['id']: style['family'] for style in STYLES}
        for family in ('natural', 'creative'):
            self.assertEqual(len(guide[family]), HEADLINE)
            self.assertEqual(len(set(guide[family])), HEADLINE)
            self.assertTrue(all(families[item] == family for item in guide[family]))

    def test_ranking_is_stable(self):
        analysis = fake(person=.2, luma=42)
        first = recommend(analysis)
        second = recommend(analysis)
        self.assertEqual(first['creative'], second['creative'])
        self.assertEqual(first['natural'], second['natural'])
        self.assertTrue(rank(_stats(analysis), 'creative', 'portrait'))


def _stats(analysis):
    from smart import describe
    return describe(analysis)


if __name__ == '__main__':
    unittest.main()
