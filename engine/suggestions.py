"""根据本机画面统计和区域识别生成可解释的快捷建议。"""
import numpy as np


def local_suggestions(analysis):
    regions = analysis.summary()
    luma = analysis.lab[..., 0]
    cards = []
    if float((luma < 20).mean()) >= .12:
        cards.append(dict(id='shadows', title='提亮暗部', preset='keep',
                          adjustments=[dict(parameter='shadows', mode='add', value=.12)]))
    if float((luma > 85).mean()) >= .08:
        cards.append(dict(id='highlights', title='收住高光', preset='keep',
                          adjustments=[dict(parameter='highlights', mode='add', value=-.16)]))
    if regions.get('sky', {}).get('available', False):
        cards.append(dict(id='sky', title='天空更通透', preset='keep',
                          adjustments=[dict(parameter='sky_b', mode='add', value=-4.)]))
    if regions.get('person', {}).get('available', False):
        cards.append(dict(id='person', title='提亮人物', preset='keep',
                          adjustments=[dict(parameter='person_l', mode='add', value=4.)]))
    cards.append(dict(id='film', title='柔和电影感', preset='film', adjustments=[]))
    from recommendations import EXTRA_CARDS
    fallback = ['light', 'contrast'] if float(np.median(luma)) < 50 else ['contrast', 'warm']
    for key in fallback:
        if len(cards) >= 3:
            break
        cards.append(next(dict(card) for card in EXTRA_CARDS if card['id'] == key))
    return cards[:5]
