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
    dict(id='vivid',title='鲜明',detail='增强色彩与层次'),
    dict(id='airy',title='轻盈',detail='明亮、柔和与淡彩'),
    dict(id='cinema',title='青橙电影',detail='冷影与暖光的明显分离'),
    dict(id='film',title='暖胶片',detail='暖调、褪黑与柔高光'),
    dict(id='neon',title='霓虹夜色',detail='蓝紫阴影，洋红高光'),
    dict(id='vintage',title='复古褪色',detail='低反差与偏黄绿底色'),
    dict(id='editorial',title='低饱和叙事',detail='克制颜色，冷影暖肤'),
    dict(id='noir',title='高反差黑白',detail='深黑、亮部与强反差'),
    dict(id='golden',title='金色时刻',detail='琥珀暖光与柔和褪黑'),
    dict(id='bleach',title='银幕冷调',detail='低饱和、冷色与硬朗光影'),
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
    if style=='vivid':p.update(contrast=.95,saturation=1.18,highlights=-.18,shadows=.12)
    if style=='airy':p.update(exposure=min(.85,p['exposure']+.2),contrast=.08,saturation=.9,highlights=-.35,shadows=.23,fade=.12)
    if style=='cinema':p.update(contrast=1.45,saturation=.84,shadow_hue=-155.,shadow_chroma=18.,highlight_hue=65.,highlight_chroma=13.,fade=.12)
    if style=='film':p.update(contrast=.65,saturation=.88,temperature=.48,shadow_hue=-145.,shadow_chroma=6.,highlight_hue=70.,highlight_chroma=11.,fade=.5,highlights=-.45)
    if style=='neon':p.update(contrast=1.55,saturation=1.18,temperature=-.18,shadow_hue=-85.,shadow_chroma=23.,highlight_hue=-15.,highlight_chroma=18.,black_white=.28)
    if style=='vintage':p.update(contrast=.18,saturation=.72,temperature=.36,tint=-.17,shadow_hue=95.,shadow_chroma=12.,highlight_hue=72.,highlight_chroma=9.,fade=.72)
    if style=='editorial':p.update(contrast=1.1,saturation=.66,shadow_hue=-150.,shadow_chroma=9.,highlight_hue=58.,highlight_chroma=5.,fade=.16)
    if style=='noir':p.update(saturation=0.,contrast=2.,black_white=.7,highlights=.12,shadows=-.28,exposure=p['exposure']-.1,skin_protect=False)
    if style=='golden':p.update(temperature=.58,tint=.06,contrast=.8,saturation=.91,highlight_hue=75.,highlight_chroma=18.,shadow_hue=40.,shadow_chroma=6.,fade=.22,highlights=-.38)
    if style=='bleach':p.update(temperature=-.24,contrast=1.8,saturation=.48,black_white=.42,shadows=-.18,highlights=-.12,shadow_hue=-140.,shadow_chroma=8.,fade=.05)
    title=next(s['title'] for s in STYLES if s['id']==style)
    notes=[f'曝光 {p["exposure"]:+.2f} EV',f'对比 {p["contrast"]:.2f}',f'饱和 {p["saturation"]:.2f}']
    if p['dehaze_amt']:notes.append(f'轻去雾 {p["dehaze_amt"]:.2f}')
    if style=='smart':notes.append('按画面亮度与反差计算，保留原有色相')
    return dict(params=p,title=title,notes=notes,analysis=stats)


REGION_TITLES=dict(water='水面',sky='天空',land='地面',person='人物')
LOCAL_TITLES=dict(exposure='曝光',contrast='对比',highlights='高光',temperature='色温',saturation='饱和',hue='色相',feather='羽化')


def apply_operations(params,operations,analysis):
    """AI 只给数值操作；没有执行任意代码、文件或 shell 的入口。"""
    from service import parameters,LIMITS
    p=deepcopy(params)
    labels={'exposure':'曝光','contrast':'对比','saturation':'饱和','temperature':'色温',
            'tint':'色调','highlights':'高光','shadows':'阴影','black_white':'黑白点',
            'dehaze_amt':'去雾','effect_strength':'整体强度','smooth':'磨皮','bright':'肤色提亮',
            'match_strength':'参考强度','sky_hue':'天空色相','autumn':'土地饱和','water_var':'水色变化',
            'shadow_hue':'阴影色相','shadow_chroma':'阴影染色','highlight_hue':'高光色相','highlight_chroma':'高光染色','fade':'褪黑',
            'whites':'白色','blacks':'黑色','light':'光线','vibrance':'颜色','texture':'质感'}
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
        elif key.startswith('local_'):
            from grade import LOCAL_FIELDS
            name,field=key[6:].split('_',1)
            if name not in ['water','sky','land','person'] or field not in LOCAL_FIELDS:raise ValueError('AI 请求了尚未支持的参数')
            if not analysis.summary()[name]['available']:
                notes.append(REGION_TITLES[name]+'：没有可靠区域，保持不变');continue
            values=p['local'].setdefault(name,{})
            old=values.get(field,0.)
            result=value if mode=='set' else old+value if mode=='add' else old*value
            values[field]=float(np.clip(result,*LOCAL_FIELDS[field]))
            if field!='feather' and 'feather' not in values:values['feather']=.5
            notes.append(f'{REGION_TITLES[name]}{LOCAL_TITLES[field]} {old:.2f} → {values[field]:.2f}')
        elif key in ['skin_protect','water_enabled','sky_enabled','land_enabled','portrait_enabled']:
            if mode!='set' or value not in [0,1]:raise ValueError('节点开关操作无效')
            if key=='skin_protect':p[key]=bool(value)
            else:p['enabled'][key.removesuffix('_enabled')]=bool(value)
            notes.append(f'{key} {"开启" if value else "关闭"}')
        elif key.rsplit('_',1)[0] in ['water','sky','land','person'] and key.rsplit('_',1)[-1] in ['l','a','b']:
            name,channel=key.rsplit('_',1)
            if not analysis.summary()[name]['available']:
                notes.append(name+'：没有可靠区域，保持不变');continue
            i=['l','a','b'].index(channel)
            if name not in p['regions']:
                from grade import grade_array,rgb2lab
                from match import statistics
                current=statistics(rgb2lab(grade_array(analysis.image,analysis=analysis,**p)),analysis.region(name))
                if current is None:continue
                mean=current['mean'].tolist()
                p['regions'][name]=dict(mean=mean.copy(),source_mean=mean.copy(),chroma_scale=[1.,1.],
                    luma_x=[0.,100.],luma_y=[0.,100.],reference_luma_mean=mean[0],strength=1.,reference_count=0)
            region=p['regions'][name];values=region['mean']
            old=values[i]; result=value if mode=='set' else old+value if mode=='add' else old*value
            values[i]=float(np.clip(result,0 if i==0 else -100,100))
            p['enabled']['match']=True
            notes.append(f'{name} {"Lab"[i]} {old:.2f} → {values[i]:.2f}')
        else:raise ValueError('AI 请求了尚未支持的参数')
    return parameters(p),notes
