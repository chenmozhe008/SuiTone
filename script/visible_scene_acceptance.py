"""真实公开样片与可见调色要求；默认只预览计划，不发送照片。"""
import sys
import expanded_visual_acceptance as expanded

ROOT = expanded.ROOT
SAMPLES = ROOT / 'output'
expanded.SAMPLES = SAMPLES
expanded.CASES = [
    ('haze', 'scene-matched-samples-20261029/Haze in Mountains.jpg',
     '远山灰霾明显，请让山体层次和通透度有清楚可见的改善；保留自然天空，不要出现高光断层。'),
    ('backlit-person', 'backlit-candidates-20261029/Portrait at the window.jpg',
     '人物脸部偏暗，请只提亮人物，前后变化要明显，保持自然肤色和窗外背景。'),
    ('night', 'expanded-public-samples-20261029/Street photographer on Nanjing Road at night.jpg',
     '做成明显的蓝色电影夜景，保留暖色灯光、人物和亮部细节。'),
]


def main():
    if not sys.argv[1:]:
        for key, filename, prompt in expanded.CASES:
            print(key, filename, prompt)
        print('每张首轮及复看各最多一次，合计最多六次请求。')
        return
    if sys.argv[1:] != ['--run-authorized']:
        raise SystemExit('用法：无参数查看计划；获得明确授权后使用 --run-authorized')
    expanded.main()


if __name__ == '__main__':
    main()
