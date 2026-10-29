"""用偏冷的公开日出照片测试保留剪影、明显暖化晨光。"""
import sys
import expanded_visual_acceptance as expanded

expanded.SAMPLES = expanded.ROOT / 'output/sunrise-candidates-20261029'
expanded.CASES = [
    ('14', 'silhouette.jpg', '保留人物剪影和海面层次，把偏冷的日出天空明显调暖，有自然的晨光感。'),
]

if __name__ == '__main__':
    if sys.argv[1:] == ['--run-authorized']:
        expanded.main()
    elif not sys.argv[1:]:
        for item in expanded.CASES:
            print(*item)
    else:
        raise SystemExit('用法：无参数查看计划，或使用 --run-authorized 执行')
