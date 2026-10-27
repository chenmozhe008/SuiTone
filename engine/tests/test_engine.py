"""真正的行为约束：区域隔离、无区域不改变、单调影调、缓存与不覆盖。"""
from copy import deepcopy
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import sys
import unittest
import numpy as np
from PIL import Image

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from grade import grade_array,quantize,rgb2lab
from analysis import Analysis
from image_io import load_image,save_new
from match import apply_regions,_curve
from service import parameters,DEFAULTS,Engine
from lut import base_lut,write_cube,read_cube,apply


class EngineTests(unittest.TestCase):
    def test_quality_preview_is_cached_across_color_edits_without_new_segmentation(self):
        from unittest.mock import patch
        from smart import neutral
        image=Image.fromarray(np.random.default_rng(4).integers(60,180,(48,64,3),dtype=np.uint8))
        with TemporaryDirectory() as folder:
            engine=Engine(folder);source=Path(folder)/'noise.png';save_new(image,source)
            asset=engine.import_one(source);context=self.context(image)
            engine.analysis=lambda key:(context,True)
            calls=[]
            def process(im,pixels,**quality):
                calls.append(quality)
                return im,pixels*.8
            with patch('enhance.prepare_quality',side_effect=process):
                plain=engine.preview(asset.id,neutral())
                improved=engine.preview(asset.id,neutral(),dict(denoise=True,scale=1))
                params=neutral();params['exposure']=.3
                engine.preview(asset.id,params,dict(denoise=True,scale=1))
                repeated=engine.preview(asset.id,neutral(),dict(denoise=True,scale=1))
            self.assertEqual(len(calls),1)
            self.assertEqual(repeated['preview'],improved['preview'])
            self.assertNotEqual(plain['preview'],improved['preview'])
            self.assertEqual(plain['inference_count'],repeated['inference_count'])
            self.assertFalse(np.array_equal(np.asarray(Image.open(plain['preview'])),np.asarray(Image.open(improved['preview']))))

    def test_export_uses_each_photos_quality_and_preserves_recipe(self):
        from unittest.mock import patch
        from smart import neutral
        image=Image.new('RGB',(64,48),(90,120,150))
        with TemporaryDirectory() as folder:
            root=Path(folder);destination=root/'exports';destination.mkdir()
            source=root/'source.png';save_new(image,source);original=source.read_bytes()
            engine=Engine(root);asset=engine.import_one(source)
            engine.analysis=lambda key:(self.context(image),True)
            def process(im,pixels=None,**quality):
                size=(im.width*quality['scale'],im.height*quality['scale'])
                im=im.resize(size)
                return im,np.asarray(im,dtype=np.float32)/255
            qualities=[dict(denoise=True,scale=2),dict(denoise=False,scale=1)]
            with patch('enhance.prepare_quality',side_effect=process):
                result=engine.export([dict(id=asset.id,params=neutral(),quality=q) for q in qualities],destination,
                                    dict(format='png',denoise=True,scale=4))
            sizes=[]
            for path in result['files']:
                with Image.open(path) as rendered:sizes.append(rendered.size)
            self.assertEqual(sizes,[(128,96),(64,48)])
            import json
            recipe=json.loads((Path(result['directory'])/'调整记录.photoedit').read_text())
            self.assertEqual([p['quality'] for p in recipe['photos']],qualities)
            self.assertNotIn('scale',recipe['options'])
            self.assertNotIn('denoise',recipe['options'])
            self.assertEqual(source.read_bytes(),original)
            before=set(destination.iterdir())
            with self.assertRaises(ValueError):engine.export([dict(id=asset.id,quality=dict(scale=3))],destination,{})
            self.assertEqual(set(destination.iterdir()),before)

    def test_denoise_keeps_float_precision_until_final_quantization(self):
        from enhance import prepare_quality
        gradient=np.broadcast_to(np.linspace(.3,.6,512,dtype=np.float32)[None,:,None],(24,512,3)).copy()
        image=Image.fromarray(np.uint8(gradient*255+.5))
        _,pixels=prepare_quality(image,gradient,denoise=True,scale=1)
        self.assertEqual(pixels.shape,gradient.shape)
        self.assertTrue(np.isfinite(pixels).all())
        fractional=np.abs(pixels*255-np.round(pixels*255))
        self.assertGreater((fractional>.01).mean(),.8)

    def region(self):
        return dict(mean=[50,-24,-10],source_mean=[50,0,0],chroma_scale=[1,1],
                    luma_x=[0,25,50,75,100],luma_y=[0,20,50,80,100],reference_luma_mean=50,strength=1,reference_count=1)

    def test_matching_never_tints_unselected_mountain(self):
        lab=np.zeros((24,32,3));lab[...,0]=50
        mask=np.zeros((24,32));mask[12:]=1
        context=SimpleNamespace(region=lambda name:mask)
        result=apply_regions(lab,context,{'water':self.region()})
        np.testing.assert_array_equal(result[:12],lab[:12])
        self.assertLess(result[18,10,1],-20)

    def test_zero_match_strength_is_identity(self):
        lab=np.random.default_rng(4).uniform(0,70,(20,30,3))
        context=SimpleNamespace(region=lambda name:np.ones((20,30)))
        np.testing.assert_array_equal(apply_regions(lab,context,{'water':self.region()},0),lab)

    def test_luma_curve_has_no_reversals_or_large_steps(self):
        values=np.linspace(-5,105,10000)
        mapped=_curve(values,[0,20,50,80,100],[0,10,48,85,100])
        self.assertTrue(np.all(np.diff(mapped)>0))
        self.assertLess(np.diff(mapped).max(),.05)

    def test_invalid_curve_and_nan_rejected(self):
        bad=deepcopy(DEFAULTS);bad['regions']={'water':self.region()};bad['regions']['water']['luma_x']=[0,0,50,75,100]
        with self.assertRaises(ValueError):parameters(bad)
        with self.assertRaises(ValueError):parameters({'dehaze_amt':float('nan')})
        with self.assertRaises(ValueError):parameters({'unknown':1})

    def test_disabling_nodes_leaves_float_input_and_aspect_intact(self):
        image=Image.fromarray(np.random.default_rng(3).integers(30,220,(40,75,3),dtype=np.uint8))
        zeros=np.zeros((40,75))
        context=SimpleNamespace(rgb=np.asarray(image,np.float64)/255,water=zeros,sky=zeros)
        p=dict(enabled={n:False for n in ['levels','dehaze','contrast','water','sky','land','match','portrait']})
        output=grade_array(image,analysis=context,**p)
        self.assertEqual(output.shape,(40,75,3))
        self.assertLess(abs(output-context.rgb).max(),.0001)
        self.assertTrue(np.isfinite(output).all())

    def test_save_never_overwrites_and_keeps_profile(self):
        with TemporaryDirectory() as folder:
            path=Path(folder)/'source.png'; image=Image.new('RGB',(93,47),(50,100,140))
            save_new(image,path); original=path.read_bytes()
            with self.assertRaises(FileExistsError):save_new(Image.new('RGB',(1,1)),path)
            self.assertEqual(path.read_bytes(),original)
            self.assertEqual(load_image(path).size,(93,47))
            with Image.open(path) as im:self.assertIn('icc_profile',im.info)

    def test_export_formats_keep_dimensions_profile_and_source(self):
        from smart import neutral
        with TemporaryDirectory() as folder:
            root=Path(folder);destination=root/'exports';destination.mkdir()
            image=Image.new('RGB',(93,47),(70,120,160))
            source=root/'photo.png';save_new(image,source);original=source.read_bytes()
            engine=Engine(root);asset=engine.import_one(source)
            engine.analysis=lambda key:(self.context(image),True)
            for fmt,extension in [('jpeg','.jpg'),('png','.png')]:
                result=engine.export([dict(id=asset.id,params=neutral())],destination,dict(format=fmt))
                path=Path(result['files'][0]);self.assertEqual(path.suffix,extension)
                with Image.open(path) as exported:
                    self.assertEqual(exported.size,image.size);self.assertIn('icc_profile',exported.info)
                self.assertEqual(source.read_bytes(),original)
            before=set(destination.iterdir())
            with self.assertRaises(ValueError):engine.export([dict(id=asset.id)],destination,dict(format='unsupported'))
            self.assertEqual(set(destination.iterdir()),before)

    def test_infobar_allows_missing_exif(self):
        from info_bar import with_bar
        image=Image.new('RGB',(1200,675))
        output=with_bar(image,{},'测试地点')
        self.assertEqual(output.width,image.width)
        self.assertGreater(output.height,image.height)
        np.testing.assert_array_equal(np.asarray(output)[:image.height],np.asarray(image))

    def test_lut_round_trip_and_domain(self):
        with TemporaryDirectory() as folder:
            path=Path(folder)/'test.cube'
            table=base_lut({'exposure':.2,'saturation':1.1,'contrast':1})
            write_cube(table,path);read=read_cube(path)
            self.assertEqual(read.shape,(33,33,33,3));self.assertTrue(np.isfinite(read).all())
            np.testing.assert_allclose(read,table,atol=5.1e-7)
            self.assertEqual(apply(read,Image.new('RGB',(39,21))).size,(39,21))

    def test_dither_preserves_smooth_gradient(self):
        gradient=np.broadcast_to(np.linspace(.2,.6,2048)[None,:,None],(32,2048,3))
        image=quantize(gradient)
        mean=np.asarray(image).mean(axis=(0,2))
        self.assertGreater(len(np.unique(mean)),200)
        self.assertLess(abs(np.diff(mean)).max(),1)

    def test_stripe_export_has_no_boundary_dependence(self):
        from render import render_full
        rgb=np.broadcast_to(np.linspace(.2,.8,300)[None,:,None],(600,300,3)).copy()
        image=Image.fromarray(np.uint8(rgb*255+.5))
        preview=image.resize((75,150));z=np.zeros((150,75))
        context=SimpleNamespace(image=preview,rgb=np.asarray(preview,dtype=float)/255,
                                water=z,sky=z,land=z,person=z,skin=z,dehazed=None)
        disabled={key:False for key in ['light','color','levels','dehaze','contrast','water','sky','land','match','portrait']}
        first=render_full(image,{'enabled':disabled},context,band=97)
        second=render_full(image,{'enabled':disabled},context,band=211)
        np.testing.assert_array_equal(np.asarray(first),np.asarray(second))

    def test_reference_without_water_preserves_existing_parameters(self):
        from match import match
        image=Image.new('RGB',(64,64),(110,110,110));rgb=np.asarray(image,dtype=float)/255;z=np.zeros((64,64))
        context=Analysis.__new__(Analysis)
        context.image=image;context.rgb=rgb;context.lab=rgb2lab(rgb);context.dehazed=None
        for name in ['water','sky','land','person','skin']:setattr(context,name,z)
        p=deepcopy(DEFAULTS);p['match_strength']=.35
        result=match(context,[context],p,only='water')
        self.assertEqual(result['params'],p)
        self.assertEqual(result['learned'],[])

    def context(self,image):
        context=Analysis.__new__(Analysis)
        context.image=image;context.rgb=np.asarray(image,dtype=float)/255;context.lab=rgb2lab(context.rgb);context.dehazed=None
        for name in ['water','sky','land','person','skin']:setattr(context,name,np.zeros(context.rgb.shape[:2]))
        return context

    def test_smart_is_scene_adaptive_and_never_forces_case_colors(self):
        from smart import suggest
        dark=self.context(Image.new('RGB',(64,64),(14,19,25)))
        bright=self.context(Image.new('RGB',(64,64),(205,210,215)))
        first=suggest(dark)['params'];second=suggest(bright)['params']
        self.assertGreater(first['exposure'],second['exposure'])
        for p in [first,second]:
            self.assertFalse(p['enabled']['water']);self.assertFalse(p['enabled']['sky']);self.assertFalse(p['enabled']['land'])
            self.assertFalse(p['auto_dehaze']);self.assertLessEqual(p['dehaze_amt'],.18)
            parameters(p)

    def test_style_strength_zero_returns_original(self):
        from smart import suggest
        image=Image.fromarray(np.random.default_rng(9).integers(10,245,(64,64,3),dtype=np.uint8))
        context=self.context(image);p=suggest(context,'warm')['params'];p['effect_strength']=0
        np.testing.assert_allclose(grade_array(image,analysis=context,**p),context.rgb,atol=5e-5)

    def test_mono_style_is_neutral_and_tone_adjustments_stay_finite(self):
        from smart import suggest
        image=Image.fromarray(np.random.default_rng(10).integers(10,245,(64,64,3),dtype=np.uint8))
        context=self.context(image);p=suggest(context,'mono')['params']
        result=grade_array(image,analysis=context,**p)
        self.assertTrue(np.isfinite(result).all());self.assertLess(np.ptp(result,axis=-1).max(),.0001)

    def test_all_styles_are_valid_distinct_and_keep_disabled_regions(self):
        from smart import STYLES,suggest
        image=Image.fromarray(np.random.default_rng(12).integers(15,240,(64,64,3),dtype=np.uint8))
        context=self.context(image);outputs=[]
        for style in STYLES:
            with self.subTest(style=style['id']):
                p=parameters(suggest(context,style['id'])['params'])
                self.assertTrue(all(not p['enabled'][key] for key in ['water','sky','land']))
                result=grade_array(image,analysis=context,**p)
                self.assertEqual(result.shape,context.rgb.shape)
                self.assertTrue(np.isfinite(result).all())
                for previous in outputs:self.assertGreater(np.abs(result-previous).mean(),.001)
                outputs.append(result)

    def test_ai_plan_validates_scope_and_uses_relative_parameters(self):
        from assistant import validate_plan
        from smart import neutral
        context=self.context(Image.new('RGB',(64,64),(120,135,145)))
        engine=SimpleNamespace(analysis=lambda key:(context,True))
        targets=[dict(id='one',params=neutral()),dict(id='two',params=dict(neutral(),exposure=.3))]
        plan=dict(reply='整批曝光轻提',selection='none',actions=[dict(id=t['id'],preset='keep',adjustments=[dict(parameter='exposure',mode='add',value=.15)]) for t in targets])
        result=validate_plan(plan,targets,engine)
        self.assertAlmostEqual(result['changes'][0]['params']['exposure'],.15)
        self.assertAlmostEqual(result['changes'][1]['params']['exposure'],.45)
        bad=deepcopy(plan);bad['actions'][0]['id']='outside'
        with self.assertRaises(ValueError):validate_plan(bad,targets,engine)
        bad=deepcopy(plan);bad['actions'][0]['adjustments'][0]['parameter']='shell'
        with self.assertRaises(ValueError):validate_plan(bad,targets,engine)
        self.assertEqual(targets[0]['params']['exposure'],0)

    def test_ai_questions_do_not_produce_changes_and_missing_regions_stay_put(self):
        from assistant import validate_plan
        from smart import neutral,apply_operations
        context=self.context(Image.new('RGB',(64,64),(120,135,145)))
        engine=SimpleNamespace(analysis=lambda key:(context,True))
        p=neutral();targets=[dict(id='one',params=p)]
        result=validate_plan(dict(reply='可以先试自然风格。',selection='none',actions=[]),targets,engine)
        self.assertEqual(result['changes'],[])
        updated,notes=apply_operations(p,[dict(parameter='water_a',mode='add',value=-3)],context)
        self.assertEqual(updated,p);self.assertTrue(notes)

    def test_cli_failures_are_actionable_and_do_not_echo_private_logs(self):
        from assistant import cli_failure
        private='private-fixture-value'
        network=cli_failure('codex','stream disconnected '+private)
        self.assertTrue(network.retryable);self.assertNotIn(private,str(network))
        for output in ['401 unauthorized '+private,'429 rate limit '+private,'unexpected argument '+private]:
            error=cli_failure('codex',output)
            self.assertFalse(error.retryable);self.assertNotIn(private,str(error))

    def test_transient_cli_retry_happens_once_and_auth_errors_do_not_retry(self):
        from assistant import AssistantBridge,CLIRequestError,SCHEMA
        from smart import STYLES
        from threading import Event
        bridge=AssistantBridge(None);calls=[]
        def invoke(*args):
            calls.append(1)
            if len(calls)==1:raise CLIRequestError('temporary',retryable=True)
            return dict(reply='ok',selection='none',actions=[])
        bridge._invoke_once=invoke
        self.assertEqual(bridge._invoke('codex','test',Event())['reply'],'ok');self.assertEqual(len(calls),2)
        calls=[]
        def unauthorized(*args):calls.append(1);raise CLIRequestError('auth')
        bridge._invoke_once=unauthorized
        with self.assertRaises(CLIRequestError):bridge._invoke('codex','test',Event())
        self.assertEqual(len(calls),1)
        self.assertEqual(set(SCHEMA['properties']['actions']['items']['properties']['preset']['enum']),{'keep'}|{s['id'] for s in STYLES})

    def test_old_recipes_keep_manual_dehaze(self):
        self.assertFalse(parameters(dict(dehaze_amt=.35))['auto_dehaze'])

    def test_extreme_reference_curve_is_bounded_and_editable(self):
        from match import match
        target=self.context(Image.fromarray(np.tile(np.linspace(15,230,64,dtype=np.uint8)[None,:,None],(64,1,3))))
        ref=self.context(Image.new('RGB',(64,64),(253,253,253)))
        target.water=np.ones((64,64));ref.water=np.ones((64,64))
        from smart import neutral
        result=match(target,[ref],neutral(),only='water')
        p=result['params']['regions']['water'];y=np.array(p['luma_y'])
        self.assertTrue(np.all((y>=0)&(y<=100)));self.assertTrue((np.diff(y)>0).all())
        parameters(result['params'])


if __name__=='__main__':unittest.main()
