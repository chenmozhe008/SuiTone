"""参考图分区反推：公开的 Lab 目标值、色度比例和单调影调曲线。"""
from copy import deepcopy
import numpy as np
from analysis import Analysis, REGIONS
from grade import grade_array, rgb2lab

QUANTILES = np.array([.02, .1, .25, .5, .75, .9, .98])


def statistics(lab, mask):
    selected = lab[mask > .65]
    if len(selected) < 32:
        return None
    low, high = np.quantile(selected, [.02, .98], axis=0)
    robust = np.clip(selected, low, high)
    return {'mean': robust.mean(0), 'std': robust.std(0),
            'luma': np.quantile(selected[:, 0], QUANTILES)}


def match(target, references, params=None, only=None, reference_regions=None):
    """references 接受 Analysis 或 PIL 图；只改变双方确实存在的区域。"""
    target = target if isinstance(target, Analysis) else Analysis(target)
    references = [r if isinstance(r, Analysis) else Analysis(r) for r in references]
    reference_regions=reference_regions or [None]*len(references)
    if not references:
        raise ValueError('请先添加至少一张参考图')
    if only is not None and only not in REGIONS:
        raise ValueError('未知匹配区域')
    output = deepcopy(params or {})
    baseline_params = deepcopy(output)
    baseline_params.pop('regions', None)
    baseline_params.pop('analysis', None)
    baseline = rgb2lab(grade_array(target.image, analysis=target, **baseline_params))
    adjustments = deepcopy(output.get('regions') or {})
    summary = target.summary()
    notes = []
    learned = []
    gaps = {}
    names = {'water': '水', 'sky': '天空', 'land': '土地', 'person': '人物'}
    for region in ([only] if only else REGIONS):
        if not summary[region]['available']:
            notes.append(f'目标图的{names[region]}区域不足或识别不确定，保持原设置')
            continue
        refs = [statistics(r.lab, r.region(region)) for r,scope in zip(references,reference_regions)
                if (scope is None or scope==region) and r.summary()[region]['available']]
        refs = [r for r in refs if r is not None]
        if not refs:
            notes.append(f'参考图没有可用的{names[region]}区域，保持原设置')
            continue
        source = statistics(baseline, target.region(region))
        if source is None:
            continue
        mean = np.mean([r['mean'] for r in refs], 0)
        std = np.mean([r['std'] for r in refs], 0)
        dest = np.mean([r['luma'] for r in refs], 0)
        x = source['luma']
        keep = np.r_[True, np.diff(x) > .05]
        x, dest = x[keep], dest[keep]
        if len(x) < 2:
            x = np.array([0., 100.])
            dest = np.clip(x + mean[0] - source['mean'][0], 0, 100)
        # 限制局部斜率，防止极端参考图拉出断层或反转影调。
        for i in range(1, len(x)):
            dest[i] = dest[i-1] + np.clip(dest[i]-dest[i-1], .2*(x[i]-x[i-1]), 3*(x[i]-x[i-1]))
        # 保留斜率关系，同时把极端参考曲线放回可显示、可编辑的亮度域。
        if dest[-1]>100:
            dest=dest*(100/dest[-1])
        if dest[0]<0:
            dest=(dest-dest[0])*(100/(dest[-1]-dest[0]))
        adjustments[region] = {
            'mean': mean.tolist(), 'source_mean': source['mean'].tolist(),
            'chroma_scale': np.clip(std[1:] / np.maximum(source['std'][1:], 1.), .25, 2.).tolist(),
            'luma_x': x.tolist(), 'luma_y': dest.tolist(), 'reference_luma_mean': float(mean[0]),
            'strength': 1.0, 'reference_count': len(refs),
        }
        learned.append(region)
        gaps[region] = (float(mean[0]-source['mean'][0]), float(np.hypot(*(mean[1:]-source['mean'][1:]))))
    if learned:
        output['regions'] = adjustments
        output['match_strength'], advice = suggested_strength(gaps, names)
        notes.extend(advice)
    return {'params': output, 'learned': learned, 'notes': notes,
            'boundary': '只学习颜色与影调；光线方向和光比不会改变。结果可继续微调。'}


def suggested_strength(gaps, names):
    """参考图和照片差得越多，越不能照搬：按最大差异把强度压到 0.45–0.8，并说明原因。"""
    worst = max(max(abs(dl) / 30, dc / 35) for dl, dc in gaps.values())
    strength = float(np.clip(.8 - .25 * max(worst - .5, 0), .45, .8))
    advice = []
    for region, (dl, dc) in gaps.items():
        if abs(dl) >= 18:
            advice.append(f'参考图的{names[region]}比这张{"亮" if dl > 0 else "暗"}很多')
        elif dc >= 25:
            advice.append(f'参考图的{names[region]}颜色和这张差别较大')
    if advice:
        advice = ['，'.join(advice) + f'，照搬会显得生硬，已按 {strength*100:.0f}% 强度匹配，可拖「参考强度」调整']
    else:
        advice = [f'已按 {strength*100:.0f}% 强度匹配，可拖「参考强度」调整']
    return strength, advice


def _curve(values, x, y):
    result = np.interp(values, x, y)
    left = np.clip((y[1]-y[0])/(x[1]-x[0]), .2, 3)
    right = np.clip((y[-1]-y[-2])/(x[-1]-x[-2]), .2, 3)
    result = np.where(values < x[0], y[0]+(values-x[0])*left, result)
    return np.where(values > x[-1], y[-1]+(values-x[-1])*right, result)


def apply_regions(lab, analysis, regions, strength=1.0):
    output = lab.copy()
    for region in REGIONS:
        if region not in regions:
            continue
        p = regions[region]
        m = analysis.region(region)*np.clip(strength*p.get('strength', 1.), 0, 1)
        if m.max() <= 0:
            continue
        changed = lab.copy()
        changed[..., 0] = _curve(lab[..., 0], p['luma_x'], p['luma_y'])
        changed[..., 0] += p['mean'][0]-p['reference_luma_mean']
        for i in (1, 2):
            changed[..., i] = (lab[..., i]-p['source_mean'][i])*p['chroma_scale'][i-1]+p['mean'][i]
        # 每个区域互斥或柔和相接；始终以输入为基准计算，不串染其他区域。
        output += (changed-lab)*m[..., None]
    return output
