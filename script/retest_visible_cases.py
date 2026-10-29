"""用美食和山景两张公开样片验证可见效果；默认只显示计划。"""
import sys
import expanded_visual_acceptance as food
import retest_visual_cases as mountain

def main():
    food_cases=[case for case in food.CASES if case[0]=='food']
    mountain_cases=[case for case in mountain.RETESTS if case[0]=='11']
    if len(food_cases)!=1 or len(mountain_cases)!=1:raise SystemExit('测试案例配置不唯一')
    if not sys.argv[1:]:
        print('美食：',food_cases[0][2]);print('山景：',mountain_cases[0][2])
        print('每张首轮及复看各最多一次，使用前后对照复看。')
        return
    if sys.argv[1:]!=['--run-authorized']:raise SystemExit('用法：无参数看计划；授权后使用 --run-authorized')
    food.CASES=food_cases;mountain.RETESTS=mountain_cases
    food.main();mountain.main()

if __name__=='__main__':main()
