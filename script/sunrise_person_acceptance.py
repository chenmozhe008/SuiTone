"""日出逆光人像的公开样片视觉验收。"""
import sys
import expanded_visual_acceptance as expanded

expanded.SAMPLES = expanded.ROOT / 'output/sunrise-candidates-20261029'
expanded.CASES = [
    ('13', 'portrait.jpg', '人物在日出逆光中偏暗，请明显提亮人物脸部和衣服，保持肤色自然，保留日出光感和背景。'),
]

if __name__ == '__main__':
    if sys.argv[1:] == ['--run-authorized']:
        expanded.main()
    elif not sys.argv[1:]:
        for item in expanded.CASES:
            print(*item)
    else:
        raise SystemExit('用法：无参数查看计划，或使用 --run-authorized 执行')
