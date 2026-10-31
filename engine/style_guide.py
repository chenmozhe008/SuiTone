"""按照片内容给风格排序：本机规则，毫秒级，结果可解释。

只决定首屏的顺序，不删除任何风格；用户展开全部时仍能看到 34 款。
"""
from smart import STYLES, STYLE_SCENES, describe

SCENE_TITLES = dict(portrait='人像', landscape='风光', night='夜色', city='城市街景', daily='日常')

REASONS = {
    'portrait': '画面里有人物，先保住肤色和柔和的反差',
    'landscape': '天空和地面都占了不少，适合把层次和天空推出来',
    'night': '这张偏暗、暗部占比大，先别把黑压得更死',
    'city': '画面以建筑和街景为主，适合有城市味道的冷暖与反差',
    'daily': '没有特别突出的主体，先看几款通用耐看的',
}

HEADLINE = 6  # 首屏格数；推荐只出这么多个，其余进「展开全部」


def scene_of(stats):
    """判主导场景。人像优先，其次夜景，再风光，剩下按日常处理。"""
    regions = stats['regions']
    person = regions.get('person', {})
    sky, land, water = (regions.get(name, {}) for name in ('sky', 'land', 'water'))
    wide = sky.get('available') and (land.get('available') or water.get('available'))
    # 人占画面 12% 以上才算人像；远景里的小人、街拍路人仍然按风光／日常处理。
    if person.get('available') and person.get('area', 0) >= .12 and (person['area'] >= .2 or not wide):
        return 'portrait'
    if stats['luma_median'] < 30 and stats['shadow_fraction'] > .22:
        return 'night'
    if wide or water.get('area', 0) >= .15:
        return 'landscape'
    return 'daily'


def _score(style, scene, stats):
    """场景匹配为主，再按明暗和色度做微调；分数只用于排序。"""
    scenes = STYLE_SCENES.get(style['id'], [])
    score = 3. if scene in scenes else (1. if 'daily' in scenes else 0.)
    params = style['params']
    mid, chroma = stats['luma_median'], stats['mean_chroma']
    exposure = params.get('exposure_add', 0.)
    # 很暗的照片别先推压得更暗的风格；很亮的照片也别硬提亮。
    if mid < 35:
        if exposure > 0: score += .6
        if style['id'] in ('moody', 'matte', 'noir'): score -= 1.2
    if mid > 62:
        if exposure > 0: score -= .6
        if params.get('highlights', 0) < -.2: score += .4
    # 本来就很淡的画面推浓一点的，已经很浓的别再推正片。
    saturation = params.get('saturation', 1.)
    if chroma < 18 and saturation > 1.08: score += .4
    if chroma > 40 and saturation > 1.1: score -= .4
    if stats['shadow_fraction'] > .2 and params.get('shadows', 0) > .15: score += .3
    return score


def rank(stats, family, scene=None):
    """同组风格按匹配度排序，取首屏需要的数量。"""
    scene = scene or scene_of(stats)
    picks = []
    for index, style in enumerate(STYLES):
        if style['family'] != family: continue
        # 会吃掉肤色的黑白／棕调不进人像首屏，但仍留在「展开全部」里。
        if scene == 'portrait' and style['params'].get('skin_protect', True) is False: continue
        picks.append((-_score(style, scene, stats), index, style['id']))
    picks.sort()
    ids = [item for _, _, item in picks]
    if len(ids) < HEADLINE:
        for style in STYLES:
            if style['family'] == family and style['id'] not in ids: ids.append(style['id'])
            if len(ids) >= HEADLINE: break
    return ids[:HEADLINE]


def recommend(analysis):
    """给一张照片的分组推荐：轻微调整和风格化各 6 款，外加一句理由。"""
    stats = describe(analysis)
    scene = scene_of(stats)
    return dict(scene=scene, scene_title=SCENE_TITLES[scene], reason=REASONS[scene],
                natural=rank(stats, 'natural', scene), creative=rank(stats, 'creative', scene))
