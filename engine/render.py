"""全尺寸按条带计算；共享全图黑白点、影调和选区，避免接缝和内存峰值。"""
from types import SimpleNamespace
import numpy as np
from PIL import Image
from grade import grade_array,quantize,rgb2lab


def rows(field, width, height, top, bottom):
    import cv2
    source_height,source_width=field.shape[:2]
    sx,sy=source_width/width,source_height/height
    transform=np.array([[sx,0,(sx-1)/2],[0,sy,sy*(top+.5)-.5]],np.float64)
    return cv2.warpAffine(field.astype(np.float32),transform,(width,bottom-top),
                          flags=cv2.INTER_LINEAR|cv2.WARP_INVERSE_MAP,borderMode=cv2.BORDER_REPLICATE)


def render_full(image,params,preview,pixels=None,band=384):
    params=dict(params)
    if params.get('auto_dehaze'):
        params['dehaze_amt']=preview.recommended_dehaze()
        params['auto_dehaze']=False
    # 全图统计取自同一份预览分析，保证拖滑块和导出使用相同的参数锚点。
    grade_array(preview.image,analysis=preview,**params)
    width,height=image.size
    output=Image.new('RGB',image.size)
    rng=np.random.default_rng(0)
    margin=max(16,width//250*2+4)
    active_water=bool(preview.water.mean()>.01)
    active_sky=bool(preview.sky.mean()>.01)
    enabled=params.get('enabled',{})
    for core_top in range(0,height,band):
        core_bottom=min(height,core_top+band)
        top,bottom=max(0,core_top-margin),min(height,core_bottom+margin)
        tile=image.crop((0,top,width,bottom))
        rgb=np.asarray(tile,np.float64)/255 if pixels is None else pixels[top:bottom].astype(np.float64)
        context=SimpleNamespace(image=tile,rgb=rgb,global_fields=True,
                                level_points=preview.level_points,water_active=active_water,sky_active=active_sky)
        for name in ['water','sky','land','person','skin']:
            setattr(context,name,rows(getattr(preview,name),width,height,top,bottom))
        context.sky_blurred=rows(preview.sky_blurred,width,height,top,bottom)
        context.region=lambda name:getattr(context,name)
        context.lab=rgb2lab(rgb) if params.get('skin_protect') or params.get('smooth') or params.get('bright') or params.get('effect_strength',1)<1 else None
        if enabled.get('contrast',True) and enabled.get('light',True):
            context.contrast_blur=rows(preview.contrast_blur,width,height,top,bottom)
        if active_water and enabled.get('water',True): context.water_mean=preview.water_mean
        context.dehazed=None
        if params.get('dehaze_amt',1) and enabled.get('dehaze',True) and enabled.get('light',True):
            transmission=rows(preview.dehaze_t,width,height,top,bottom)[...,None]
            context.dehazed=np.clip((rgb-preview.dehaze_A)/transmission+preview.dehaze_A,0,1)
        context.frame=(top,height,width)
        context.local_masks={key:rows(mask,width,height,top,bottom) for key,mask in getattr(preview,'local_masks',{}).items()}
        if params.get('texture'):context.glow_field=rows(preview.glow_field,width,height,top,bottom)
        rgb_out=grade_array(tile,analysis=context,**params)
        rendered=quantize(rgb_out[core_top-top:core_bottom-top],rng=rng)
        output.paste(rendered,(0,core_top))
    return output
