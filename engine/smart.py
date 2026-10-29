"""面向不同照片的保守初调和通用风格；不把某个案例的区域目标色当默认值。"""
from copy import deepcopy
import numpy as np

# 风格表：family＝natural（自然，求真）或 creative（出片，求惊艳）；params 覆盖在每张照片的智能初调之上，
# exposure_add 表示在初调曝光上加减。出片类都带 texture（暗角＋柔光＋颗粒），不只调颜色。
# 注意：阴影／高光染色在乘饱和度之前加，饱和度为 0 的风格染色会被抹掉；要带色调的单色风格用低饱和＋暖色做。
# id 一经发布不改（旧调整记录和 AI 都按 id 引用）；新增风格只加一行。
STYLES = [
    dict(id='smart',title='智能自然',detail='按每张照片的明暗与反差调整',family='natural',params={}),
    dict(id='true',title='真实还原',detail='只校正曝光，几乎不动颜色',family='natural',
         params=dict(contrast=.25,black_white=.08,highlights=-.04,shadows=.03)),
    dict(id='clean',title='清透',detail='轻对比，干净明亮',family='natural',params=dict(exposure_add=.12,contrast=.85,saturation=1.06)),
    dict(id='bright',title='明亮',detail='提亮暗部，保留高光',family='natural',params=dict(exposure_add=.25,light=.2,shadows=.22,contrast=.4)),
    dict(id='soft',title='柔和',detail='收住高光，保留柔和层次',family='natural',
         params=dict(contrast=.12,black_white=.06,highlights=-.3,shadows=.17,saturation=.94)),
    dict(id='warm',title='暖调',detail='温暖中间调，颜色略收敛',family='natural',params=dict(temperature=.38,tint=.04,contrast=.42,saturation=.93)),
    dict(id='cool',title='冷调',detail='清冷中间调，保留肤色',family='natural',params=dict(temperature=-.28,tint=-.03,contrast=.6,saturation=.95)),
    dict(id='vivid',title='鲜明',detail='增强色彩与层次',family='natural',params=dict(contrast=.95,saturation=1.18,highlights=-.18,shadows=.12)),
    dict(id='airy',title='轻盈',detail='明亮、柔和与淡彩',family='natural',
         params=dict(exposure_add=.2,contrast=.08,saturation=.9,highlights=-.35,shadows=.23,fade=.12)),
    dict(id='mono',title='黑白',detail='只留光影与纹理',family='natural',params=dict(saturation=0.,contrast=1.15,black_white=.3,skin_protect=False)),

    dict(id='film',title='暖胶片',detail='暖调、褪黑与柔高光',family='creative',
         params=dict(contrast=.65,saturation=.88,temperature=.48,shadow_hue=55.,shadow_chroma=5.,highlight_hue=70.,highlight_chroma=11.,fade=.5,highlights=-.45,texture=.45)),
    dict(id='portra',title='人像胶片',detail='暖肤色、柔反差、细颗粒',family='creative',
         params=dict(contrast=.45,saturation=.9,temperature=.22,tint=.05,highlight_hue=60.,highlight_chroma=7.,shadow_hue=-150.,shadow_chroma=4.,fade=.3,highlights=-.3,texture=.35)),
    dict(id='cinema',title='青橙电影',detail='冷影与暖光的明显分离',family='creative',
         params=dict(contrast=1.45,saturation=.84,shadow_hue=-155.,shadow_chroma=18.,highlight_hue=65.,highlight_chroma=13.,fade=.12,texture=.25)),
    dict(id='nightfilm',title='夜色胶片',detail='冷蓝夜色，灯光泛红晕',family='creative',
         params=dict(temperature=-.3,contrast=1.,saturation=1.05,shadow_hue=-110.,shadow_chroma=12.,highlight_hue=20.,highlight_chroma=14.,fade=.15,texture=.6)),
    dict(id='neon',title='霓虹夜色',detail='蓝紫阴影，洋红高光',family='creative',
         params=dict(contrast=1.55,saturation=1.18,temperature=-.18,shadow_hue=-85.,shadow_chroma=15.,highlight_hue=-15.,highlight_chroma=16.,black_white=.28,texture=.2)),
    dict(id='rich',title='浓郁正片',detail='饱满色彩，扎实反差',family='creative',
         params=dict(contrast=1.3,saturation=1.15,vibrance=.2,temperature=.15,black_white=.35,shadow_hue=-130.,shadow_chroma=5.,texture=.25)),
    dict(id='clearpositive',title='清冷正片',detail='青绿暗部，克制颜色',family='creative',
         params=dict(contrast=.9,saturation=.8,temperature=-.12,vibrance=-.2,shadow_hue=-170.,shadow_chroma=10.,highlight_hue=50.,highlight_chroma=4.,fade=.15,texture=.3)),
    dict(id='japan',title='日系通透',detail='明亮、低反差、偏青',family='creative',
         params=dict(exposure_add=.3,light=.2,contrast=.1,saturation=.78,temperature=-.15,tint=-.06,shadows=.3,highlights=-.25,fade=.25,texture=.15)),
    dict(id='cream',title='奶油清新',detail='暖白高光，柔和淡彩',family='creative',
         params=dict(exposure_add=.15,contrast=.2,saturation=.85,temperature=.2,tint=.08,highlight_hue=75.,highlight_chroma=10.,fade=.35,highlights=-.35,texture=.2)),
    dict(id='summer',title='盛夏',detail='明快暖色，色彩饱满',family='creative',
         params=dict(contrast=1.,saturation=1.2,vibrance=.3,temperature=.25,highlights=-.2,shadows=.15,texture=.15)),
    dict(id='golden',title='金色时刻',detail='琥珀暖光与柔和褪黑',family='creative',
         params=dict(temperature=.58,tint=.06,contrast=.8,saturation=.91,highlight_hue=75.,highlight_chroma=18.,shadow_hue=40.,shadow_chroma=6.,fade=.22,highlights=-.38,texture=.3)),
    dict(id='autumn',title='秋日',detail='橙黄更暖，绿色收敛',family='creative',
         params=dict(temperature=.35,tint=.04,saturation=1.05,vibrance=.2,highlight_hue=70.,highlight_chroma=10.,shadow_hue=30.,shadow_chroma=5.,contrast=.8,texture=.3)),
    dict(id='bluehour',title='蓝调时刻',detail='深蓝暗部，粉紫高光',family='creative',
         params=dict(temperature=-.45,tint=.12,contrast=.9,saturation=1.05,shadow_hue=-95.,shadow_chroma=14.,highlight_hue=-20.,highlight_chroma=8.,texture=.3)),
    dict(id='desert',title='沙漠',detail='暖沙色，蓝色褪淡',family='creative',
         params=dict(temperature=.4,saturation=.75,vibrance=-.2,contrast=.9,highlight_hue=70.,highlight_chroma=12.,shadow_hue=45.,shadow_chroma=8.,fade=.2,texture=.4)),
    dict(id='moody',title='暗调氛围',detail='压暗、低饱和、青色暗部',family='creative',
         params=dict(light=-.35,contrast=1.1,saturation=.7,shadow_hue=-150.,shadow_chroma=12.,highlight_hue=55.,highlight_chroma=5.,blacks=-.3,texture=.45)),
    dict(id='editorial',title='低饱和叙事',detail='克制颜色，冷影暖肤',family='creative',
         params=dict(contrast=1.1,saturation=.66,shadow_hue=-150.,shadow_chroma=9.,highlight_hue=58.,highlight_chroma=5.,fade=.16,texture=.2)),
    dict(id='bleach',title='银幕冷调',detail='低饱和、冷色与硬朗光影',family='creative',
         params=dict(temperature=-.24,contrast=1.8,saturation=.48,black_white=.42,shadows=-.18,highlights=-.12,shadow_hue=-140.,shadow_chroma=8.,fade=.05,texture=.3)),
    dict(id='matte',title='哑光',detail='抬起黑位，柔和低反差',family='creative',
         params=dict(contrast=.35,saturation=.85,fade=.8,highlights=-.2,texture=.3)),
    dict(id='vintage',title='复古褪色',detail='低反差与偏黄绿底色',family='creative',
         params=dict(contrast=.18,saturation=.72,temperature=.36,tint=-.17,shadow_hue=95.,shadow_chroma=12.,highlight_hue=72.,highlight_chroma=9.,fade=.72,texture=.55)),
    dict(id='polaroid',title='拍立得',detail='偏绿暗部，暖白高光，暗角',family='creative',
         params=dict(contrast=.4,saturation=.85,temperature=.1,tint=-.1,shadow_hue=170.,shadow_chroma=6.,highlight_hue=75.,highlight_chroma=10.,fade=.55,highlights=-.3,texture=.6)),
    dict(id='ccd',title='复古 CCD',detail='冷调、高反差、像早年数码相机',family='creative',
         params=dict(exposure_add=.1,contrast=1.2,saturation=1.15,temperature=-.2,tint=-.05,highlights=.1,black_white=.3,texture=.55)),
    dict(id='sepia',title='怀旧棕调',detail='近单色的旧照片棕',family='creative',
         params=dict(saturation=.22,temperature=.8,highlight_hue=70.,highlight_chroma=30.,shadow_hue=50.,shadow_chroma=20.,contrast=.7,fade=.35,texture=.55,skin_protect=False)),
    dict(id='silver',title='银盐黑白',detail='柔和颗粒的胶片黑白',family='creative',
         params=dict(saturation=0.,contrast=1.3,black_white=.4,fade=.15,texture=.65,skin_protect=False)),
    dict(id='noir',title='高反差黑白',detail='深黑、亮部与强反差',family='creative',
         params=dict(exposure_add=-.1,saturation=0.,contrast=2.,black_white=.7,highlights=.12,shadows=-.28,texture=.4,skin_protect=False)),
]
STYLE_BY_ID={style['id']:style for style in STYLES}


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
    if style not in STYLE_BY_ID:raise ValueError('未知风格')
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
    overrides=dict(STYLE_BY_ID[style]['params'])
    add=overrides.pop('exposure_add',0.)
    # 提亮类风格有上限，已经够亮的照片不再往上推。
    p['exposure']=float(min(p['exposure']+add,.9) if add>0 else np.clip(p['exposure']+add,-3,3))
    p.update(overrides)
    title=STYLE_BY_ID[style]['title']
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
