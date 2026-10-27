"""命令行入口（给 App / 其他工具调用），所有参数 JSON 化，结果写文件、stdout 打一行 JSON。
  python cli.py grade   --in a.jpg --out b.jpg [--params '{"water":[54,-17,-7],"dehaze_amt":0.6}']
  python cli.py remove  --in a.jpg --out b.jpg --params '{"box":[0.64,0.22,0.76,0.49],"keep":["sky"]}'
  python cli.py portrait --in a.jpg --out b.jpg [--params '{"smooth":0.5,"bright":0.3}']
  python cli.py infobar --in a.jpg --exif 原始照片.jpg --out b.jpg --params '{"place":"宁夏 · 西吉"}'
  python cli.py denoise|upscale|raw ...     python cli.py lut-fit --out x.cube --pairs o1 g1 o2 g2
"""
import sys, os, json, argparse
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from PIL import Image
def main():
    ap=argparse.ArgumentParser(); ap.add_argument('cmd'); ap.add_argument('--in',dest='inp'); ap.add_argument('--out')
    ap.add_argument('--params',default='{}'); ap.add_argument('--exif'); ap.add_argument('--pairs',nargs='*'); ap.add_argument('--long',type=int,default=4032)
    a=ap.parse_args(); p=json.loads(a.params)
    from grade import load
    if a.cmd=='raw':
        from raw import load_raw; im=load_raw(a.inp,long=a.long,**p)
    elif a.cmd=='lut-fit':
        from lut import _pairs, fit, write_cube
        L,cov=fit([_pairs(a.pairs[i],a.pairs[i+1]) for i in range(0,len(a.pairs),2)]); write_cube(L,a.out)
        print(json.dumps({'ok':True,'out':a.out,'coverage':cov})); return
    else:
        im=load(a.inp,long=a.long)
        if a.cmd=='grade':
            from grade import grade
            if 'water' in p: p['water']=tuple(p['water'])
            im=grade(im,**p)
        elif a.cmd=='remove':
            from inpaint import remove
            if 'box' in p: p['box']=tuple(p['box'])
            im,_=remove(im,**p)
        elif a.cmd=='portrait':
            from portrait import retouch; im=retouch(im,**p)
        elif a.cmd=='denoise':
            from enhance import denoise; im=denoise(im,**p)
        elif a.cmd=='upscale':
            from enhance import upscale; im=upscale(im,**p)
        elif a.cmd=='infobar':
            from info_bar import with_bar, meta; im=with_bar(im,meta(a.exif or a.inp),**p)
        else: raise SystemExit(f'unknown cmd {a.cmd}')
    im.save(a.out,quality=94); print(json.dumps({'ok':True,'out':a.out,'size':im.size}))
if __name__=='__main__': main()
