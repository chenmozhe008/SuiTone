"""验证 AI 是否纠正画面事实，并遵从明确的冷暖方向。"""
import sys
import expanded_visual_acceptance as expanded

expanded.SAMPLES = expanded.ROOT / 'output/sunrise-candidates-20261029'
expanded.CASES = [
    ('color-question', 'silhouette.jpg', '我觉得这张日出已经偏暖。请先看图告诉我你的判断；如果不一致，请直接说出来，不要修改照片。'),
    ('color-cool', 'silhouette.jpg', '我觉得这张日出偏暖，请保留人物剪影，把天空明显调冷。如果你看到的原图不是偏暖，也请如实说明。'),
]

if __name__ == '__main__':
    if sys.argv[1:] == ['--run-authorized']:
        expanded.main()
    elif not sys.argv[1:]:
        for item in expanded.CASES:
            print(*item)
    else:
        raise SystemExit('用法：无参数查看计划，或使用 --run-authorized 执行')
