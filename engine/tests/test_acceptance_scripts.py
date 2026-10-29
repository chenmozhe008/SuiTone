"""验收脚本离线行为：画质操作必须随最终预览和复看一起传递。"""
import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from PIL import Image

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'script'))
import expanded_visual_acceptance as runner
import visual_acceptance as fixed_runner
import retry_backlit_review as retry
from review_constraints import review_allowed
from copy import deepcopy


class AcceptanceScriptTests(unittest.TestCase):
    def test_fixed_cases_review_receives_before_and_after(self):
        with TemporaryDirectory() as folder:
            root=Path(folder);sample=root/'sample.png'
            Image.new('RGB',(8,8),(80,100,120)).save(sample)
            class FakeEngine:
                def preview(self,key,params,quality=None):return {'preview':str(sample)}
            requests=[]
            def fake_invoke(engine,request):
                requests.append(deepcopy(request))
                if len(requests)==1:
                    changed=deepcopy(request['targets'][0]['params']);changed['exposure']=.2
                    return {'state':'done','changes':[{'params':changed,'operations':[]}]}
                return {'state':'done','changes':[]}
            with patch.object(fixed_runner,'invoke',side_effect=fake_invoke):
                fixed_runner.execute_case(FakeEngine(),SimpleNamespace(id='photo'),('14','backlit','日出调暖'),root,True)
            self.assertEqual(requests[1]['review_before'][0]['source_id'],'photo')
            self.assertEqual(requests[1]['review_before'][0]['params']['exposure'],0)
            self.assertEqual(requests[1]['targets'][0]['params']['exposure'],.2)

    def test_review_restricts_new_regions_and_unrequested_channels(self):
        base={'regions':{},'exposure':0.0}
        region={'mean':[60,1,2],'source_mean':[50,1,2],'chroma_scale':[1,1],
                'luma_x':[0,100],'luma_y':[0,100],'reference_luma_mean':50,'strength':1,'reference_count':0}
        first={'regions':{'person':region},'exposure':0.0}
        good=deepcopy(first);good['regions']['person']['mean'][0]=65
        self.assertTrue(review_allowed(base,first,good))
        different_region=deepcopy(first);different_region['regions']['sky']=deepcopy(region)
        self.assertFalse(review_allowed(base,first,different_region))
        different_channel=deepcopy(first);different_channel['regions']['person']['mean'][1]=12
        self.assertFalse(review_allowed(base,first,different_channel))
        new_exposure=deepcopy(first);new_exposure['exposure']=.3
        self.assertFalse(review_allowed(base,first,new_exposure))

    def test_retry_only_requests_review_once_and_retains_failure(self):
        with TemporaryDirectory() as folder:
            root=Path(folder);(root/'output').mkdir();prior=root/'prior';prior.mkdir()
            image=prior/'sample.png';Image.new('RGB',(8,8),(80,100,120)).save(image)
            for side in ('before','after'):
                (prior/('backlit-person-'+side+'.png')).write_bytes(image.read_bytes())
            params=retry.neutral();original={'id':'backlit-person','prompt':'提亮人物',
                'initial':{'state':'done','changes':[{'params':params,'operations':[]}]},
                'review':{'state':'error','error':'frequency-limited'},'final_params':params}
            source=prior/'results.json';source.write_text(json.dumps({'cases':[original]}));requests=[]
            class FakeEngine:
                def __init__(self,_):self.assistant=SimpleNamespace()
                def import_one(self,path):return SimpleNamespace(id='fixture')
                def preview(self,key,params,quality=None):return {'preview':str(image)}
            def fake_invoke(engine,request):
                requests.append(request);return {'state':'done','changes':[]}
            with patch.object(retry,'ROOT',root),patch.object(retry,'SOURCE',source),patch.object(retry,'PHOTO',image),\
                 patch.object(retry,'Engine',FakeEngine),patch.object(retry,'invoke',side_effect=fake_invoke),\
                 patch.object(sys,'argv',['fixture','--run-authorized']):retry.main()
            output=json.loads(next((root/'output').glob('*/results.json')).read_text())
            self.assertEqual(len(requests),1)
            self.assertTrue(requests[0]['review_only'])
            self.assertEqual(requests[0]['review_before'][0]['source_id'],'fixture')
            self.assertEqual(output['cases'][0]['review_attempts'][0]['error'],'frequency-limited')
            self.assertEqual(output['cases'][0]['initial']['state'],'done')
            self.assertEqual(output['status'],'awaiting_manual_review')

    def test_denoise_is_rendered_and_sent_to_review(self):
        with TemporaryDirectory() as folder:
            root=Path(folder);(root/'output').mkdir();sample=root/'sample.png'
            Image.new('RGB',(8,8),(80,100,120)).save(sample)
            requests=[];rendered=[]
            class FakeEngine:
                def __init__(self,_):self.assistant=SimpleNamespace()
                def import_one(self,path):return SimpleNamespace(id='photo')
                def preview(self,key,params,quality=None):
                    rendered.append(quality);return {'preview':str(sample)}
            def fake_invoke(engine,request):
                requests.append(request)
                if len(requests)==1:
                    return {'state':'done','changes':[{'params':request['targets'][0]['params'],
                                                       'operations':[{'kind':'denoise','value':1}]}]}
                return {'state':'done','changes':[]}
            with patch.object(runner,'ROOT',root),patch.object(runner,'SAMPLES',root),\
                 patch.object(runner,'CASES',[('test','sample.png','测试')]),patch.object(runner,'Engine',FakeEngine),\
                 patch.object(runner,'invoke',side_effect=fake_invoke),patch.object(sys,'argv',['fixture','--run-authorized']):
                runner.main()
            report=json.loads(next((root/'output').glob('*/results.json')).read_text())
            self.assertTrue(report['cases'][0]['quality']['denoise'])
            self.assertTrue(requests[1]['targets'][0]['quality']['denoise'])
            self.assertFalse(requests[1]['review_before'][0]['quality']['denoise'])
            self.assertTrue(rendered[-1]['denoise'])


if __name__=='__main__':unittest.main()
