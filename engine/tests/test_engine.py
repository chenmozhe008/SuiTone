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


if __name__=='__main__':unittest.main()
