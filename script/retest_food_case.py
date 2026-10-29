"""仅重测已准备的公开美食案例；无参数时不发送图片。"""
import sys
import expanded_visual_acceptance as expanded

def main():
    food=[case for case in expanded.CASES if case[0]=='food']
    if len(food)!=1:raise SystemExit('美食案例配置不唯一')
    if not sys.argv[1:]:
        print('计划：',food[0][1],food[0][2], '首轮及复看各最多一次')
        return
    if sys.argv[1:]!=['--run-authorized']:
        raise SystemExit('用法：无参数查看计划；授权后使用 --run-authorized')
    expanded.CASES=food
    expanded.main()

if __name__=='__main__':main()
