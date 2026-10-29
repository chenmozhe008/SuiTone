"""用对应的公开样片重测未通过的三个调色方向。"""
import sys
import expanded_visual_acceptance as expanded

expanded.SAMPLES = expanded.ROOT / 'output'
expanded.CASES = [
    ('03', 'distinct-samples-20261029/portrait.jpg',
     '调成柔和暖胶片感，人物自然，风格变化要清楚可见。'),
    ('05', 'expanded-public-samples-20261029/Street photographer on Nanjing Road at night.jpg',
     '保留夜景氛围，明显打开暗部，不要把灯光压灭或过曝。'),
    ('11', 'scene-matched-samples-20261029/Haze in Mountains.jpg',
     '保留真实感觉，让有灰霾的远山清楚可见地更通透，天空自然且没有色阶断层。'),
]

if __name__ == '__main__':
    if sys.argv[1:] == ['--run-authorized']:
        expanded.main()
    elif not sys.argv[1:]:
        for item in expanded.CASES:
            print(*item)
    else:
        raise SystemExit('用法：无参数查看计划，或使用 --run-authorized 执行')
