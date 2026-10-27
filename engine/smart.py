"""面向不同照片的保守初调和通用风格；不把某个案例的区域目标色当默认值。"""
from copy import deepcopy
import numpy as np

STYLES = [
    dict(id='smart',title='智能自然',detail='按每张照片的明暗与反差调整'),
    dict(id='clean',title='清透',detail='轻对比，干净明亮'),
    dict(id='soft',title='柔和',detail='收住高光，保留柔和层次'),
    dict(id='warm',title='暖调',detail='温暖中间调，颜色略收敛'),
    dict(id='cool',title='冷调',detail='清冷中间调，保留肤色'),
    dict(id='mono',title='黑白',detail='只留光影与纹理'),
]


def describe(analysis):
    luma=analysis.lab[...,0]
    low,mid,high=np.percentile(luma,[5,50,95])
    chroma=np.hypot(analysis.lab[...,1],analysis.lab[...,2])
    regions=analysis.summary()
    return dict(luma_p05=float(low),luma_median=float(mid),luma_p95=float(high),
                shadow_fraction=float((luma<8).mean()),highlight_fraction=float((luma>96).mean()),
                mean_chroma=float(np.median(chroma)),regions=regions,
                scene_hints=(['人物'] if regions['person']['available'] else [])+
                (['开阔风景'] if regions['sky']['available'] and regions['land']['available'] else [])+
                (['暗调／夜景候选'] if mid<25 else []))


def neutral():
    from service import parameters
    return parameters(dict(water=[54.,-17.,-7.],water_var=.6,dehaze_amt=0.,auto_dehaze=False,
                           black_white=0.,contrast=0.,saturation=1.,skin_protect=True,
                           enabled=dict(water=False,sky=False,land=False)))


def suggest(analysis,style='smart'):
    if style not in {s['id'] for s in STYLES}:raise ValueError('未知风格')
    p=neutral();stats=describe(analysis)
    low,mid,high=(stats[key] for key in ['luma_p05','luma_median','luma_p95'])
    # 暗调和夜景只轻提；明亮画面也不强拉成同一个中灰。
    target=mid+4 if mid<25 else np.clip(mid,44,61)
    p['exposure']=float(np.clip(3*np.log2((target+16)/max(mid+16,1)),-.35,.65))
    p['black_white']=.18 if high-low>24 else .05
    p['contrast']=.5
    p['saturation']=1.03 if stats['mean_chroma']<25 else 1.
    p['shadows']=.16 if stats['shadow_fraction']>.05 else .05
    p['highlights']=-.2 if stats['highlight_fraction']>.01 else -.06
    # 有亮天空且黑位抬高的低反差画面才轻去雾；不对所有场景套远山参数。
    if stats['regions']['sky']['available'] and low>22 and high-low<50:p['dehaze_amt']=.18
    if style=='clean':p.update(exposure=min(.8,p['exposure']+.12),contrast=.85,saturation=1.06)
    if style=='soft':p.update(contrast=.12,black_white=.06,highlights=-.3,shadows=.17,saturation=.94)
    if style=='warm':p.update(temperature=.38,tint=.04,contrast=.42,saturation=.93)
    if style=='cool':p.update(temperature=-.28,tint=-.03,contrast=.6,saturation=.95)
    if style=='mono':p.update(saturation=0.,contrast=1.15,black_white=.3,skin_protect=False)
    title=next(s['title'] for s in STYLES if s['id']==style)
    notes=[f'曝光 {p["exposure"]:+.2f} EV',f'对比 {p["contrast"]:.2f}',f'饱和 {p["saturation"]:.2f}']
    if p['dehaze_amt']:notes.append(f'轻去雾 {p["dehaze_amt"]:.2f}')
    if style=='smart':notes.append('保留原有色相；未启用固定水色、天空或土地色')
    return dict(params=p,title=title,notes=notes,analysis=stats)


def apply_operations(params,operations,analysis):
    """AI 只给数值操作；没有执行任意代码、文件或 shell 的入口。"""
    from service import parameters,LIMITS
    p=deepcopy(params)
    labels={'exposure':'曝光','contrast':'对比','saturation':'饱和','temperature':'色温',
            'tint':'色调','highlights':'高光','shadows':'阴影','black_white':'黑白点',
            'dehaze_amt':'去雾','effect_strength':'整体强度','smooth':'磨皮','bright':'肤色提亮',
            'match_strength':'参考强度','sky_hue':'天空色相','autumn':'土地饱和','water_var':'水色变化'}
    notes=[]
    if len(operations)>48:raise ValueError('单次调整过多')
    for operation in operations:
        key,mode,value=operation['parameter'],operation['mode'],operation['value']
        if mode not in ['set','add','multiply'] or isinstance(value,bool) or not isinstance(value,(int,float)) or not np.isfinite(value):
            raise ValueError('AI 返回的数值操作无效')
        if key in LIMITS:
            old=p[key]
            result=value if mode=='set' else old+value if mode=='add' else old*value
            p[key]=float(np.clip(result,*LIMITS[key]))
            if key=='dehaze_amt':p['auto_dehaze']=False
            notes.append(f'{labels.get(key,key)} {old:.2f} → {p[key]:.2f}')
        elif key in ['skin_protect','water_enabled','sky_enabled','land_enabled','portrait_enabled']:
            if mode!='set' or value not in [0,1]:raise ValueError('节点开关操作无效')
            if key=='skin_protect':p[key]=bool(value)
            else:p['enabled'][key.removesuffix('_enabled')]=bool(value)
            notes.append(f'{key} {"开启" if value else "关闭"}')
        elif key in ['water_l','water_a','water_b']:
            if not analysis.summary()['water']['available']:continue
            i=['water_l','water_a','water_b'].index(key)
            region=p['regions'].get('water')
            values=region['mean'] if region else p['water']
            old=values[i]; result=value if mode=='set' else old+value if mode=='add' else old*value
            values[i]=float(np.clip(result,0 if i==0 else -100,100))
            if not region:p['enabled']['water']=True
            notes.append(f'水 {"Lab"[i]} {old:.2f} → {values[i]:.2f}')
        else:raise ValueError('AI 请求了尚未支持的参数')
    return parameters(p),notes
