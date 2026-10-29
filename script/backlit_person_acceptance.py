"""适合暗脸提亮的公开窗边人像；默认仅查看计划。"""
import sys
import expanded_visual_acceptance as expanded

expanded.SAMPLES=expanded.ROOT/'output/backlit-candidates-20261029'
expanded.CASES=[('backlit-person','Portrait at the window.jpg',
                 '人物脸部偏暗，请只提亮人物，让变化能看出来，保持肤色自然和窗外背景不变。')]

def main():
    if not sys.argv[1:]:
        print(expanded.CASES[0][1],expanded.CASES[0][2]);print('首轮及复看各最多一次。');return
    if sys.argv[1:]!=['--run-authorized']:raise SystemExit('用法：无参数查看计划；授权后使用 --run-authorized')
    expanded.main()

if __name__=='__main__':main()
