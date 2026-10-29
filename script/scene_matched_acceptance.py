"""针对场景选择样片；无参数只显示计划，不发起网络请求。"""
import sys
import expanded_visual_acceptance as expanded

expanded.SAMPLES=expanded.ROOT/'output/scene-matched-samples-20261029'
fog=next(expanded.SAMPLES.glob('Fog shrouds the mountains on Newfound Gap Road*.jpg'))
expanded.CASES=[
    ('haze','Haze in Mountains.jpg','远处山景有灰霾，请让远山层次更通透，变化能看出来，保持自然天空和现场感。'),
    ('fog',fog.name,'保留雾气和秋景氛围，让山林层次稍微更清楚，不要把雾完全去掉。'),
]

def main():
    if not sys.argv[1:]:
        for key,name,prompt in expanded.CASES:print(key,name,prompt)
        print('每张首轮及复看各最多一次。')
        return
    if sys.argv[1:]!=['--run-authorized']:raise SystemExit('用法：无参数查看计划；授权后使用 --run-authorized')
    expanded.main()

if __name__=='__main__':main()
