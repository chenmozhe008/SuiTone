"""视觉建议的受限候选池；模型只选择 ID，具体操作由引擎决定。"""
from copy import deepcopy

from suggestions import local_suggestions


EXTRA_CARDS = [
    dict(id='light', title='轻轻提亮', preset='keep',
         adjustments=[dict(parameter='exposure', mode='add', value=.15)]),
    dict(id='contrast', title='增强层次', preset='keep',
         adjustments=[dict(parameter='contrast', mode='add', value=.12)]),
    dict(id='warm', title='温暖一点', preset='keep',
         adjustments=[dict(parameter='temperature', mode='add', value=.12)]),
    dict(id='cool', title='清冷一点', preset='keep',
         adjustments=[dict(parameter='temperature', mode='add', value=-.12)]),
    dict(id='cinema', title='电影冷暖', preset='cinema', adjustments=[]),
    dict(id='airy', title='明亮轻盈', preset='airy', adjustments=[]),
    dict(id='mono', title='黑白光影', preset='mono', adjustments=[]),
]
IDS = ['shadows', 'highlights', 'sky', 'person', 'film'] + [c['id'] for c in EXTRA_CARDS]
SCHEMA = dict(type='object', additionalProperties=False, required=['cards'], properties=dict(
    cards=dict(type='array', items=dict(type='string', enum=IDS))))


def candidates(analysis):
    return local_suggestions(analysis) + deepcopy(EXTRA_CARDS)


def select(plan, cards):
    """拒绝未知、重复或照片中不可用的选项；不会接纳模型生成的操作。"""
    if not isinstance(plan, dict) or set(plan) != {'cards'}:
        raise ValueError('AI 建议格式无效')
    selected=plan['cards']
    if not isinstance(selected,list) or not 3<=len(selected)<=5 or not all(isinstance(i,str) for i in selected):
        raise ValueError('AI 建议数量无效')
    allowed={card['id']:card for card in cards}
    if len(set(selected))!=len(selected) or any(item not in allowed for item in selected):
        raise ValueError('AI 建议包含不可用的区域或重复项目')
    return [deepcopy(allowed[item]) for item in selected]
