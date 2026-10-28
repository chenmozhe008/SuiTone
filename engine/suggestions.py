"""无视觉模型时的本地建议，区域卡片必须有可靠的识别结果。"""


def local_suggestions(analysis):
    regions = analysis.summary()
    cards = [
        dict(id='shadows', title='提亮暗部', preset='keep',
             adjustments=[dict(parameter='shadows', mode='add', value=.12)]),
        dict(id='highlights', title='收住高光', preset='keep',
             adjustments=[dict(parameter='highlights', mode='add', value=-.16)]),
    ]
    if regions.get('sky', {}).get('available', False):
        cards.append(dict(id='sky', title='天空更通透', preset='keep',
                          adjustments=[dict(parameter='sky_b', mode='add', value=-4.)]))
    if regions.get('person', {}).get('available', False):
        cards.append(dict(id='person', title='提亮人物', preset='keep',
                          adjustments=[dict(parameter='person_l', mode='add', value=4.)]))
    cards.append(dict(id='film', title='柔和电影感', preset='film', adjustments=[]))
    return cards
