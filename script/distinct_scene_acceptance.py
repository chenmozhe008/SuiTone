"""已获视觉认可的两张公开样片；默认只显示计划。"""
import sys
import expanded_visual_acceptance as expanded

expanded.SAMPLES = expanded.ROOT / 'output/distinct-samples-20261029'
expanded.CASES = [
    ('portrait', 'portrait.jpg', '做出明显的暖色胶片风格，保持人物自然肤色。'),
    ('night', 'night.jpg', '做出明显的蓝紫霓虹电影夜景，保留亮灯细节。'),
]


def main():
    if not sys.argv[1:]:
        for key, filename, prompt in expanded.CASES:
            print(key, filename, prompt)
        print('每张首轮及复看各最多一次，合计最多四次请求。')
        return
    if sys.argv[1:] != ['--run-authorized']:
        raise SystemExit('用法：无参数查看计划；获得明确授权后使用 --run-authorized')
    expanded.main()


if __name__ == '__main__':
    main()
