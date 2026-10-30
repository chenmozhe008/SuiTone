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
    def test_contrast_preserves_continuous_gray_gradient_order(self):
        from smart import neutral
        values=np.linspace(0,1,4096)
        ramp=np.tile(values,(32,1))
        rgb=np.repeat(ramp[...,None],3,axis=2)
        image=Image.fromarray(np.uint8(rgb*255))
        zeros=np.zeros(ramp.shape)
        context=Analysis.__new__(Analysis)
        context.image=image;context.rgb=rgb;context.dehazed=None
        for name in ('water','sky','land','person','skin'):setattr(context,name,zeros)
        for strength in (0.,.65,1.25,2.):
            params=neutral();params['contrast']=strength
            result=grade_array(image,analysis=context,**params)
            self.assertTrue(np.isfinite(result).all())
            self.assertTrue(np.all(np.diff(result[16].mean(axis=1))>=-1e-8))

    def test_contrast_highlight_increase_preserves_headroom(self):
        from grade import _protect_contrast_highlights
        original=np.array([20.,80.,95.,99.,100.])
        adjusted=np.array([18.,82.,100.,103.,105.])
        result=_protect_contrast_highlights(original,adjusted)
        self.assertEqual(result[0],adjusted[0])
        self.assertTrue(np.all(result[1:4]>original[1:4]))
        self.assertTrue(np.all(result[1:4]<100.))
        self.assertEqual(result[-1],100.)
        self.assertTrue(np.allclose(_protect_contrast_highlights(original,original),original))

    def test_assistant_prompt_handles_missing_or_uncertain_subjects(self):
        from assistant import SYSTEM
        self.assertIn('对象明显不存在时，说明没有看到', SYSTEM)
        self.assertIn('无法确定时，说明无法确认', SYSTEM)
        self.assertIn('别指示用户框选不存在的对象', SYSTEM)

    def test_exposure_with_highlight_recovery_preserves_smooth_bright_detail(self):
        from grade import _expose
        values=np.linspace(0,1,4096,dtype=np.float64)
        ramp=np.repeat(values[None,:,None],3,axis=2)
        clipped=_expose(ramp,.5,0)[0,:,0]
        recovered=_expose(ramp,.5,-.4)[0,:,0]
        self.assertTrue(np.all(np.diff(recovered)>=-1e-12))
        self.assertLess(np.max(np.abs(np.diff(recovered,2))),.001)
        self.assertLess(np.count_nonzero(recovered>=.999),np.count_nonzero(clipped>=.999))
        self.assertTrue(np.allclose(recovered[values<.5],clipped[values<.5]))
        color=np.array([[[.9,.6,.3]]])
        from grade import _lin
        ratio=_lin(_expose(color,.5,-.4))[0,0]
        self.assertTrue(np.allclose(ratio/ratio[0],_lin(color)[0,0]/_lin(color)[0,0,0],atol=1e-8))

    def test_cli_cancellation_interrupts_blocked_input(self):
        from assistant import AssistantBridge
        from threading import Event,Thread
        from time import monotonic
        from unittest.mock import Mock,patch
        with TemporaryDirectory() as folder:
            bridge=AssistantBridge(SimpleNamespace(folder=Path(folder)))
            started=Event();release=Event();finished=Event();cancel=Event();errors=[]
            child=Mock();child.returncode=None
            def write(_):
                started.set();release.wait(5)
            child.stdin.write.side_effect=write
            child.poll.side_effect=lambda: child.returncode
            def terminate():
                child.returncode=-15;release.set()
            child.terminate.side_effect=terminate
            def invoke():
                try:
                    bridge._invoke_once('claude','test',cancel,monotonic()+10,
                                        [{'label':'fixture','data':b'image'}])
                except Exception as exc:errors.append(exc)
                finally:finished.set()
            with patch('assistant.executable',return_value='/test/claude'),patch('assistant.subprocess.Popen',return_value=child):
                thread=Thread(target=invoke,daemon=True);thread.start()
                try:
                    self.assertTrue(started.wait(2))
                    cancel.set()
                    self.assertTrue(finished.wait(1),'取消应中断阻塞的 CLI 输入')
                    self.assertIsInstance(errors[0],InterruptedError)
                finally:
                    release.set();thread.join(3)

    def test_claude_image_input_is_structured_and_tools_remain_disabled(self):
        from assistant import AssistantBridge
        from threading import Event
        from time import monotonic
        from unittest.mock import Mock,patch
        import base64,json
        with TemporaryDirectory() as folder:
            bridge=AssistantBridge(SimpleNamespace(folder=Path(folder)));calls=[]
            def run(command,**kwargs):
                child=Mock();child.stdin=Mock();child.poll.return_value=0;child.returncode=0
                calls.append((command,child))
                kwargs['stdout'].write((json.dumps({'type':'result','structured_output':{'reply':'ok','selection':'none','actions':[]}})+'\n').encode())
                return child
            with patch('assistant.executable',return_value='/test/claude'),patch('assistant.subprocess.Popen',side_effect=run):
                result=bridge._invoke_once('claude','test prompt',Event(),monotonic()+10,
                    [{'label':'公开样片','data':b'image-fixture'}])
            command,child=calls[0]
            self.assertEqual(result['reply'],'ok')
            self.assertEqual(command[command.index('--tools')+1],'')
            self.assertEqual(command[command.index('--input-format')+1],'stream-json')
            self.assertEqual(command[command.index('--output-format')+1],'stream-json')
            self.assertIn('--verbose',command)
            message=json.loads(child.stdin.write.call_args.args[0])
            self.assertEqual(message['message']['content'][1]['text'],'公开样片')
            self.assertEqual(base64.b64decode(message['message']['content'][2]['source']['data']),b'image-fixture')

    def test_advice_preserves_repair_options_and_rejects_unavailable_export(self):
        from assistant import SYSTEM,safe_advice,validate_plan
        from smart import neutral
        context=self.context(Image.new('RGB',(32,32),(100,110,120)))
        engine=SimpleNamespace(analysis=lambda key:(context,True))
        plan=dict(reply='请在导出流程中设置 3:4，保存时选择覆盖原文件。',selection='none',actions=[])
        result=validate_plan(plan,[dict(id='a',params=neutral())],engine)
        self.assertIn('不能覆盖原文件',result['reply'])
        self.assertIn('不支持裁切',result['reply'])
        self.assertNotIn('选择覆盖',result['reply'])
        self.assertEqual(safe_advice('请涂抹或框选后再修复。'),'请涂抹或框选后再修复。')
        self.assertIn('画笔、套索、点选物体和方框',SYSTEM)
        self.assertNotIn('只支持框选',SYSTEM)
        self.assertIn('local_selected_exposure',SYSTEM)
        self.assertIn('不支持裁切',safe_advice('可以在导出时设置裁剪比例。'))

    def test_visual_review_cannot_apply_preset_or_tool_operation(self):
        from assistant import validate_plan
        from smart import neutral
        context=self.context(Image.new('RGB',(32,32),(100,110,120)))
        engine=SimpleNamespace(analysis=lambda key:(context,True))
        targets=[{'id':'a','params':neutral()}]
        action=dict(id='a',preset='film',adjustments=[],operations=[])
        plan=dict(reply='建议',selection='none',actions=[action])
        with self.assertRaises(ValueError):validate_plan(plan,targets,engine,{'review_only':True})
        action['preset']='keep';action['operations']=[{'kind':'denoise','value':1}]
        with self.assertRaises(ValueError):validate_plan(plan,targets,engine,{'review_only':True})
        action['operations']=[];action['adjustments']=[{'parameter':'shadows','mode':'add','value':.05}]
        result=validate_plan(plan,targets,engine,{'review_only':True})
        self.assertAlmostEqual(result['changes'][0]['params']['shadows'],.05)

    def test_api_adapter_requires_image_consent_and_does_not_expose_credentials(self):
        from anthropic_provider import invoke, ENDPOINT
        from assistant import SCHEMA
        from io import BytesIO
        from urllib.error import HTTPError
        import json
        calls=[]
        class Response:
            def __enter__(self): return self
            def __exit__(self,*args): pass
            def read(self,limit):
                return json.dumps({'stop_reason':'end_turn','content':[{'type':'text','text':'{"reply":"ok","selection":"none","actions":[]}'}]}).encode()
        def opener(request,timeout):
            calls.append(request);return Response()
        image=[{'label':'当前照片 a','data':b'fixture-image'}]
        with self.assertRaises(ValueError):invoke('fixture-secret','test',SCHEMA,image,opener=opener)
        self.assertEqual(calls,[])
        result=invoke('fixture-secret','test',SCHEMA,image,image_consent=True,opener=opener)
        self.assertEqual(result['reply'],'ok')
        self.assertEqual(calls[0].full_url,ENDPOINT)
        body=json.loads(calls[0].data)
        self.assertEqual(body['messages'][0]['content'][2]['source']['type'],'base64')
        self.assertEqual(body['output_config']['format']['schema'],SCHEMA)
        def denied(request,timeout): raise HTTPError(ENDPOINT,401,'fixture-secret',{},BytesIO())
        with self.assertRaises(ValueError) as error:invoke('fixture-secret','test',SCHEMA,opener=denied)
        self.assertNotIn('fixture-secret',str(error.exception))

    def test_openai_compatible_providers_send_images_and_hide_credentials(self):
        from api_providers import invoke, list_models, resolve
        from assistant import SCHEMA
        from io import BytesIO
        from urllib.error import HTTPError
        import json
        calls=[]
        class Response:
            def __init__(self,value):self.value=value
            def __enter__(self): return self
            def __exit__(self,*args): pass
            def read(self,limit):return json.dumps(self.value).encode()
        reply={'choices':[{'finish_reason':'stop','message':{'content':'```json\n{"reply":"ok","selection":"none","actions":[]}\n```'}}]}
        def opener(request,timeout):
            calls.append(request);return Response(reply)
        image=[{'label':'当前照片 a','data':b'fixture-image'}]
        data=dict(provider='qwen',api_key='fixture-secret',image_consent=True)
        self.assertEqual(invoke(data,'test',SCHEMA,image,opener=opener)['reply'],'ok')
        request=calls[0];body=json.loads(request.data)
        self.assertEqual(request.full_url,'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions')
        self.assertEqual(request.get_header('Authorization'),'Bearer fixture-secret')
        self.assertEqual(body['model'],'qwen3-vl-plus')
        self.assertEqual(body['response_format'],{'type':'json_object'})
        self.assertIn('JSON Schema',body['messages'][0]['content'][0]['text'])
        self.assertTrue(body['messages'][0]['content'][2]['image_url']['url'].startswith('data:image/jpeg;base64,'))
        self.assertNotIn('fixture-secret',request.data.decode())
        invoke(dict(provider='openai',api_key='k',model='gpt-x'),'test',SCHEMA,opener=opener)
        body=json.loads(calls[1].data)
        self.assertEqual(body['response_format']['json_schema']['schema'],SCHEMA)
        self.assertEqual(body['model'],'gpt-x')
        with self.assertRaises(ValueError):invoke(dict(provider='qwen',api_key='k'),'test',SCHEMA,image,opener=opener)
        self.assertEqual(len(calls),2)
        for url in ['http://example.com/v1','ftp://x','',None]:
            with self.assertRaises(ValueError):resolve(dict(provider='custom',api_key='k',model='m',base_url=url))
        self.assertEqual(resolve(dict(provider='custom',api_key='k',model='m',base_url='http://localhost:11434/v1/'))[3],
                         'http://localhost:11434/v1')
        with self.assertRaises(ValueError):resolve(dict(provider='nope',api_key='k'))
        def denied(request,timeout): raise HTTPError(request.full_url,401,'fixture-secret',{},BytesIO())
        with self.assertRaises(ValueError) as error:invoke(dict(provider='deepseek',api_key='fixture-secret'),'test',SCHEMA,opener=denied)
        self.assertNotIn('fixture-secret',str(error.exception))
        def echoed(request,timeout):
            raise HTTPError(request.full_url,401,'',{},BytesIO(json.dumps({'error':{'message':'bad key sk-fixture-secret'}}).encode()))
        with self.assertRaises(ValueError) as error:invoke(dict(provider='deepseek',api_key=' ｓｋ-fixture-secret\u200b\n'),'test',SCHEMA,opener=echoed)
        self.assertIn('服务商返回',str(error.exception));self.assertNotIn('sk-fixture-secret',str(error.exception))
        self.assertEqual(resolve(dict(provider='deepseek',api_key=' ｓｋ-ab\u200bc\n'))[1],'sk-abc')
        reply={'data':[{'id':'models/gemini-b'},{'id':'gemini-a'}]}
        self.assertEqual(list_models(dict(provider='gemini',api_key='k'),opener=opener)['models'],['gemini-a','gemini-b'])
        self.assertTrue(calls[-1].full_url.endswith('/v1beta/openai/models'))

    def test_api_provider_uses_common_validation_without_putting_key_in_prompt(self):
        from assistant import AssistantBridge
        from smart import neutral
        from threading import Event,RLock
        from unittest.mock import patch
        context=self.context(Image.new('RGB',(32,32),(80,90,100)))
        engine=SimpleNamespace(lock=RLock(),analysis=lambda key:(context,True))
        bridge=AssistantBridge(engine);bridge.events['job']=Event();bridge.jobs['job']={'state':'preparing'}
        data=dict(provider='anthropic',api_key='fixture-secret',message='只讨论，不修改',
                  targets=[dict(id='a',params=neutral(),quality={'denoise':False,'scale':1})],
                  image_consent=False)
        def invoke(key,prompt,schema,images,**kwargs):
            self.assertEqual(key,'fixture-secret');self.assertNotIn(key,prompt);self.assertEqual(images,[])
            return dict(reply='建议',selection='none',actions=[])
        with patch('anthropic_provider.invoke',side_effect=invoke):bridge._run('job',data)
        result=bridge.status('job')
        self.assertEqual(result['state'],'done');self.assertEqual(result['changes'],[])
        self.assertNotIn('fixture-secret',repr(result))

    def test_cutout_transparent_mask_keeps_subject_and_rejects_background(self):
        from cutout import subject_alpha
        from unittest.mock import patch
        image=Image.new('RGB',(100,80),(100,120,140))
        p=np.zeros((2,8,10),np.float32);p[0]=.95;p[1]=.05
        p[0,2:7,3:7]=.05;p[1,2:7,3:7]=.95
        with patch('segmentation.probabilities',return_value=(p,{0:'sky',1:'person'})):
            alpha=np.asarray(subject_alpha(image,[.5,.5]))
            self.assertGreater(int(alpha[40,50]),240)
            self.assertEqual(int(alpha[5,5]),0)
            with self.assertRaises(ValueError):subject_alpha(image,[.05,.05])

    def test_provider_distinguishes_truncated_and_invalid_responses(self):
        from api_providers import invoke
        from assistant import SCHEMA
        import json
        class Response:
            def __init__(self,choice):self.choice=choice
            def __enter__(self):return self
            def __exit__(self,*args):pass
            def read(self,limit):return json.dumps({'choices':[self.choice]}).encode()
        data=dict(provider='deepseek',api_key='test-secret',model='test')
        with self.assertRaisesRegex(ValueError,'回复被截断'):
            invoke(data,'test',SCHEMA,opener=lambda request,timeout:Response({'finish_reason':'length','message':{'content':'{'}}))
        with self.assertRaisesRegex(ValueError,'不是有效的结构化回复'):
            invoke(data,'test',SCHEMA,opener=lambda request,timeout:Response({'finish_reason':'stop','message':{'content':'invalid'}}))

    def test_multiple_variants_are_independent_and_never_apply_operations(self):
        from assistant import validate_plan
        from smart import neutral
        from analysis import Analysis
        from grade import rgb2lab
        image=Image.new('RGB',(32,32),(100,110,120))
        context=Analysis.__new__(Analysis);context.image=image
        context.rgb=np.asarray(image,dtype=float)/255;context.lab=rgb2lab(context.rgb);context.dehazed=None
        for name in ('water','sky','land','person','skin'):setattr(context,name,np.zeros((32,32)))
        class FixtureEngine:
            def analysis(self,key):return context,True
        source=neutral();targets=[dict(id='a',params=source)]
        variants=[dict(id='a',title=name,preset='keep',operations=[],adjustments=[dict(parameter='temperature',mode='add',value=value)])
                  for name,value in [('暖',.3),('冷',-.3),('原色',0.)]]
        result=validate_plan(dict(reply='三种效果',selection='none',actions=[],variants=variants),targets,FixtureEngine())
        self.assertEqual([v['params']['temperature'] for v in result['variants']],[.3,-.3,0.])
        self.assertEqual(result['changes'],[]);self.assertEqual(source['temperature'],0.)
        variants[0]['operations']=[dict(kind='undo',value=0)]
        with self.assertRaises(ValueError):validate_plan(dict(reply='',selection='none',actions=[],variants=variants),targets,FixtureEngine())

    def test_local_suggestions_only_offer_detected_regions(self):
        from suggestions import local_suggestions
        class Context:
            def __init__(self,sky,person): self.sky=sky;self.person=person;self.lab=np.full((10,10,3),50.)
            def summary(self):
                return {'sky':{'available':self.sky},'person':{'available':self.person}}
        for sky in [False,True]:
            for person in [False,True]:
                cards=local_suggestions(Context(sky,person))
                ids={card['id'] for card in cards}
                self.assertEqual('sky' in ids,sky)
                self.assertEqual('person' in ids,person)
                self.assertGreaterEqual(len(cards),3)
                self.assertLessEqual(len(cards),5)
                self.assertEqual(len(cards),len(ids))

    def test_local_suggestions_use_tonal_content(self):
        from suggestions import local_suggestions
        class Context:
            def __init__(self, light): self.lab=np.full((10,10,3),light)
            def summary(self): return {}
        dark={c['id'] for c in local_suggestions(Context(10))}
        bright={c['id'] for c in local_suggestions(Context(95))}
        mid={c['id'] for c in local_suggestions(Context(50))}
        self.assertIn('shadows',dark);self.assertNotIn('highlights',dark)
        self.assertIn('highlights',bright);self.assertNotIn('shadows',bright)
        self.assertNotIn('shadows',mid);self.assertNotIn('highlights',mid)

    def test_local_suggestions_cache_does_not_share_mutable_results(self):
        class Context:
            lab=np.full((10,10,3),50.)
            def summary(self):return {'sky':{'available':True},'person':{'available':False}}
        with TemporaryDirectory() as folder:
            engine=Engine(folder);engine.asset=lambda key:None
            calls=[]
            def analyze(key): calls.append(key);return Context(),False
            engine.analysis=analyze
            first=engine.suggestions('photo')
            first['cards'][0]['title']='changed locally'
            second=engine.suggestions('photo')
            self.assertFalse(first['cache_hit']);self.assertTrue(second['cache_hit'])
            self.assertNotEqual(second['cards'][0]['title'],'changed locally')
            self.assertEqual(calls,['photo'])

    def test_suggestion_applies_only_available_card_to_current_parameters(self):
        from smart import neutral
        context=self.context(Image.new('RGB',(48,48),(100,110,120)))
        with TemporaryDirectory() as folder:
            engine=Engine(folder);engine.asset=lambda key:None
            engine.analysis=lambda key:(context,True)
            engine.preview=lambda key,p,quality:{'preview':'fixture-preview'}
            params=neutral();params['exposure']=.3
            result=engine.apply_suggestion('photo','shadows',params)
            self.assertAlmostEqual(result['params']['shadows'],.12)
            self.assertAlmostEqual(result['params']['exposure'],.3)
            self.assertEqual(result['preview'],'fixture-preview')
            with self.assertRaises(ValueError):engine.apply_suggestion('photo','sky',params)

    def test_visual_inputs_require_explicit_consent_before_reading_assets(self):
        from vision import prepare_images
        from threading import Event
        class UnreadableEngine:
            def __getattr__(self, name):
                raise AssertionError('未授权时不应读取照片')
        self.assertEqual(prepare_images(UnreadableEngine(), {'targets': []}), [])
        self.assertEqual(prepare_images(UnreadableEngine(), {'targets': [], 'image_consent': False}), [])
        with self.assertRaises(ValueError):
            prepare_images(UnreadableEngine(), {'targets': [], 'image_consent': 1})
        cancelled=Event();cancelled.set()
        with self.assertRaises(InterruptedError):
            prepare_images(UnreadableEngine(), {'targets':[{'id':'x'}], 'image_consent':True},cancelled)

    def test_review_comparison_sends_before_and_after_in_one_bounded_attachment(self):
        from vision import prepare_images
        from io import BytesIO
        with TemporaryDirectory() as folder:
            before=Path(folder)/'before.png';after=Path(folder)/'after.png'
            Image.new('RGB',(1200,800),(25,35,45)).save(before)
            Image.new('RGB',(1200,800),(180,190,200)).save(after)
            class MockEngine:
                def preview(self,key,params,quality):
                    return {'preview':str(before if key=='original' else after)}
            data={'image_consent':True,'review_only':True,
                  'targets':[{'id':'edited','params':{},'quality':{}}],
                  'review_before':[{'id':'edited','source_id':'original','params':{},'quality':{}}]}
            result=prepare_images(MockEngine(),data)
            self.assertEqual(len(result),1)
            self.assertIn('左侧调整前，右侧调整后',result[0]['label'])
            with Image.open(BytesIO(result[0]['data'])) as image:
                self.assertLessEqual(max(image.size),1024)
                self.assertLess(image.getpixel((image.width//4,image.height//2))[0],50)
                self.assertGreater(image.getpixel((image.width*3//4,image.height//2))[0],150)
                self.assertFalse(image.getexif())
            data['repair_selection']={'id':'edited','box':[.1,.2,.4,.5]}
            with_selection=prepare_images(MockEngine(),data)
            self.assertEqual(len(with_selection),2)
            self.assertIn('用户指定的选区',with_selection[1]['label'])

    def test_review_job_does_not_claim_images_when_consent_is_off(self):
        from assistant import AssistantBridge
        from smart import neutral
        from threading import Event,RLock
        from unittest.mock import patch
        context=self.context(Image.new('RGB',(32,32),(80,90,100)))
        engine=SimpleNamespace(lock=RLock(),analysis=lambda key:(context,True))
        bridge=AssistantBridge(engine);bridge.events['job']=Event();bridge.jobs['job']={'state':'preparing'}
        data=dict(provider='codex',message='复看',targets=[dict(id='a',params=neutral(),quality={})],
                  image_consent=False,review_only=True,
                  review_before=[dict(id='a',source_id='a',params=neutral(),quality={})])
        def invoke(provider,prompt,cancel,*images):
            self.assertNotIn('每张对照图左侧',prompt)
            self.assertFalse(images)
            return dict(reply='建议',selection='none',actions=[])
        with patch.object(bridge,'_invoke',side_effect=invoke):bridge._run('job',data)
        self.assertEqual(bridge.status('job')['state'],'done')

    def test_review_job_sends_comparison_to_model_with_clear_order(self):
        from assistant import AssistantBridge
        from smart import neutral
        from threading import Event,RLock
        from unittest.mock import patch
        context=self.context(Image.new('RGB',(32,32),(80,90,100)))
        engine=SimpleNamespace(lock=RLock(),analysis=lambda key:(context,True))
        bridge=AssistantBridge(engine);bridge.events['job']=Event();bridge.jobs['job']={'state':'preparing'}
        data=dict(provider='codex',message='复看',targets=[dict(id='a',params=neutral(),quality={})],
                  image_consent=True,review_only=True,
                  review_before=[dict(id='a',source_id='a',params=neutral(),quality={})])
        attachment=[dict(label='照片对照 a：左侧调整前，右侧调整后',data=b'fixture')]
        def invoke(provider,prompt,cancel,images):
            self.assertIn('每张对照图左侧为调整前、右侧为调整后',prompt)
            self.assertEqual(images,attachment)
            return dict(reply='建议',selection='none',actions=[])
        with patch('vision.prepare_images',return_value=attachment),patch.object(bridge,'_invoke',side_effect=invoke):bridge._run('job',data)
        self.assertEqual(bridge.status('job')['state'],'done')

    def test_visual_inputs_use_current_preview_strip_metadata_and_keep_selection(self):
        from vision import prepare_images
        from io import BytesIO
        class MockEngine:
            def __init__(self, path): self.path=path; self.called=[]
            def preview(self, key, params, quality):
                self.called.append((key, params, quality)); return {'preview': str(self.path)}
            def asset(self, key): return SimpleNamespace(image_path=self.path)
        with TemporaryDirectory() as folder:
            path=Path(folder)/'source.jpg'
            image=Image.new('RGB',(1500,1000),(100,120,140))
            exif=Image.Exif();exif[270]='private test metadata'
            image.save(path,exif=exif)
            engine=MockEngine(path)
            data={'image_consent':True,'targets':[{'id':'a','params':{'exposure':.2},'quality':{'scale':1}}],
                  'reference_ids':['b'],'repair_selection':{'id':'a','box':[.1,.2,.3,.4]}}
            result=prepare_images(engine,data)
            self.assertEqual(len(result),3)
            self.assertEqual(engine.called,[('a',{'exposure':.2},{'scale':1})])
            self.assertIn('用户指定的选区',result[1]['label'])
            for attachment in result:
                with Image.open(BytesIO(attachment['data'])) as sent:
                    self.assertEqual(sent.size,(1024,683))
                    self.assertFalse(sent.getexif())
            self.assertNotEqual(result[0]['data'],result[1]['data'])
            data['targets']*=21
            with self.assertRaises(ValueError):prepare_images(engine,data)

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

    def test_startup_cleans_finished_sessions_and_caps_cache(self):
        from service import clean_temporary
        import tempfile,os
        tmp=Path(tempfile.mkdtemp())
        dead=tmp/'app-session-dead';dead.mkdir();(dead/'owner.pid').write_text('999999');(dead/'x.png').write_bytes(b'1')
        legacy=tmp/'app-session-legacy';legacy.mkdir()
        live=tmp/'app-session-live';live.mkdir();(live/'owner.pid').write_text(str(os.getpid()))
        starting=tmp/('app-session-'+str(os.getpid())+'-starting');starting.mkdir()
        interrupted=tmp/'app-session-999999-starting';interrupted.mkdir()
        cache=tmp/'app-cache/segmentation';cache.mkdir(parents=True)
        for i in range(3):
            f=cache/(str(i)*64+'.npz');f.write_bytes(b'x'*100);os.utime(f,(i,i))
        writing=cache/('a'*64+'-writing.npz');writing.write_bytes(b'x'*100)
        clean_temporary(tmp,cache_limit=150)
        self.assertFalse(dead.exists());self.assertTrue(legacy.exists());self.assertTrue(live.exists())
        self.assertTrue(starting.exists());self.assertFalse(interrupted.exists())
        self.assertEqual(sorted(f.name for f in cache.iterdir()),['2'*64+'.npz',writing.name])

    def test_corrupt_segmentation_cache_is_recomputed(self):
        import hashlib,json
        from collections import OrderedDict
        from unittest.mock import patch
        import segmentation
        with TemporaryDirectory() as folder:
            root=Path(folder);model=root/'model';model.mkdir()
            (model/'model.onnx').write_bytes(b'model')
            (model/'config.json').write_text(json.dumps({'id2label':{'0':'sky','1':'land'}}))
            image=Image.new('RGB',(8,8),(80,120,140))
            signature=str(((model/'model.onnx').stat().st_mtime_ns,(model/'config.json').stat().st_mtime_ns,'imagenet-512-bicubic-v1'))
            digest=hashlib.sha256(image.tobytes()+signature.encode()).hexdigest()
            cache=root/'cache';cache.mkdir();(cache/(digest+'.npz')).write_bytes(b'broken')
            session=SimpleNamespace(get_inputs=lambda:[SimpleNamespace(name='input')],run=lambda *args:[np.zeros((1,2,2,2),np.float32)])
            with patch.object(segmentation,'MODEL_DIR',model),patch.object(segmentation,'cache_dir',cache),patch.object(segmentation,'_cache',OrderedDict()),patch.object(segmentation,'_session',session):
                probabilities,labels=segmentation.probabilities(image)
            self.assertEqual(probabilities.shape,(2,2,2));self.assertEqual(labels[0],'sky')
            with np.load(cache/(digest+'.npz')) as saved:self.assertEqual(saved['p'].shape,(2,2,2))

    def test_generation_proposal_is_validated_and_exclusive(self):
        from assistant import validate_plan
        from smart import neutral
        context=self.context(Image.new('RGB',(64,64),(120,135,145)))
        engine=SimpleNamespace(analysis=lambda key:(context,True))
        targets=[dict(id='one',params=neutral())]
        base=dict(reply='换背景需要生成新图',selection='none',actions=[],variants=[])
        result=validate_plan(dict(base,generate=dict(needed=True,prompt='把背景换成雪山，人物不变')),targets,engine)
        self.assertEqual(result['generation']['prompt'],'把背景换成雪山，人物不变');self.assertEqual(result['changes'],[])
        self.assertIsNone(validate_plan(dict(base,generate=dict(needed=False,prompt='')),targets,engine)['generation'])
        with self.assertRaises(ValueError):validate_plan(dict(base,generate=dict(needed=True,prompt='  ')),targets,engine)
        action=dict(id='one',preset='keep',adjustments=[dict(parameter='exposure',mode='add',value=.1)],operations=[])
        with self.assertRaises(ValueError):validate_plan(dict(base,actions=[action],generate=dict(needed=True,prompt='加只猫')),targets,engine)

    def test_image_edit_job_renders_sends_and_returns_result(self):
        from service import Engine
        from time import sleep
        import tempfile
        root=Path(tempfile.mkdtemp());engine=Engine(root);engine.generated_dir=root/'generated'
        source=root/'photo.jpg';Image.new('RGB',(320,200),(30,60,200)).save(source)
        key=engine.import_one(source).id
        base=dict(id=key,params={},service='mock',prompt='换背景',image_consent=True)
        with self.assertRaises(ValueError):engine.image_edit.start(dict(base,image_consent=False))
        with self.assertRaises(ValueError):engine.image_edit.start(dict(base,service='jimeng'))  # 没密钥
        job=engine.image_edit.start(base)['id']
        for _ in range(100):
            status=engine.image_edit.status(job)
            if status['state']!='running':break
            sleep(.05)
        self.assertEqual(status['state'],'done',status)
        result=Image.open(status['paths'][0])
        self.assertEqual(result.size,(320,200));self.assertGreater(np.asarray(result)[-2,10,0],150)  # 模拟图底部色带
        adopted=engine.adopt_generated(key,status['paths'][0])
        self.assertTrue(Path(adopted['stored']).is_file())

    def test_generated_version_persists_and_replays(self):
        from service import Engine,replay_operations
        import tempfile
        root=Path(tempfile.mkdtemp());engine=Engine(root);engine.generated_dir=root/'generated'
        original=root/'photo.jpg';Image.new('RGB',(300,200),(30,60,90)).save(original)
        asset=engine.import_one(original)
        made=root/'made.png';Image.new('RGB',(150,100),(220,40,40)).save(made)
        result=engine.adopt_generated(asset.id,str(made))
        stored=Path(result['stored']);self.assertTrue(stored.is_file());self.assertEqual(stored.parent,root/'generated')
        made.unlink()  # 临时结果删掉后，版本仍从 generated 目录读取
        new=engine.asset(result['id'])
        self.assertEqual(new.operations[-1]['generated'],str(stored))
        image,pixels=replay_operations(new)
        self.assertEqual(image.size,(150,100));self.assertGreater(np.asarray(image)[50,75,0],200)
        self.assertEqual(engine.adopt_generated(asset.id,str(stored))['stored'],str(stored))  # 同内容只存一份
        stored.rename(root/'moved.png')
        with self.assertRaises(ValueError):replay_operations(new)
        bad=root/'bad.png';bad.write_bytes(b'not an image')
        with self.assertRaises(ValueError):engine.adopt_generated(asset.id,str(bad))

    def test_region_outline_draws_only_the_edge(self):
        from service import Engine
        import tempfile
        engine=Engine.__new__(Engine);engine.folder=Path(tempfile.mkdtemp())
        sky=np.zeros((100,200));sky[:40]=1
        context=SimpleNamespace(image=Image.new('RGB',(200,100)),sky=sky,region=lambda name:sky)
        engine.analysis=lambda key:(context,True)
        out=np.asarray(Image.open(engine.region_outline('a',{},'sky')['outline']))
        self.assertEqual(out.shape,(100,200,4))
        self.assertEqual(out[10,100,3],0);self.assertEqual(out[80,100,3],0)   # 区域内外都透明
        self.assertGreater(out[39:42,100,3].max(),200)                        # 边缘有线
        with self.assertRaises(ValueError):engine.region_outline('a',{},'unknown')

    def test_reference_strength_drops_when_reference_differs_a_lot(self):
        from match import suggested_strength
        names={'sky':'天空','water':'水'}
        close,advice=suggested_strength({'sky':(3.,5.)},names)
        far,warning=suggested_strength({'sky':(-40.,10.),'water':(2.,40.)},names)
        self.assertLessEqual(close,.8);self.assertGreaterEqual(far,.45);self.assertLess(far,close)
        self.assertIn('天空比这张暗很多',warning[0]);self.assertIn('水颜色',warning[0]);self.assertNotIn('暗很多',advice[0])

    def test_brush_lasso_and_object_selection_masks(self):
        from inpaint import build_mask
        from service import shape_input
        from unittest.mock import patch
        image=Image.new('RGB',(200,100),(120,120,120))
        brush=np.asarray(build_mask(image,box=(0,0,1,1),strokes=[[[.1,.5],[.4,.5]]],radius=.03))>127
        self.assertTrue(brush[50,20:80].all());self.assertFalse(brush[10].any());self.assertFalse(brush[:,150:].any())
        lasso=np.asarray(build_mask(image,box=(0,0,1,1),polygon=[[.6,.2],[.9,.2],[.9,.8],[.6,.8]]))>127
        self.assertTrue(lasso[50,140]);self.assertFalse(lasso[50,60])
        # 点选：左上角一小块是“人”，其余是天空；点人得到那一块，点天空拒绝。
        p=np.zeros((2,10,10),np.float32);p[1]=1;p[0,1:3,1:3]=1;p[1,1:3,1:3]=0
        labels={0:'person',1:'sky'}
        with patch('segmentation.probabilities',return_value=(p,labels)):
            obj=np.asarray(build_mask(image,box=(0,0,1,1),point=[.15,.15],grow=1))>127
            self.assertTrue(obj[15,30]);self.assertFalse(obj[80,150])
            with self.assertRaises(ValueError):build_mask(image,box=(0,0,1,1),point=[.8,.8])
        for bad in [dict(strokes=[[[.1,1.5]]],radius=.02),dict(strokes=[[[.1,.1]]],radius=.5),
                    dict(polygon=[[.1,.1],[.2,.2]]),dict(point=[.1]),dict(strokes=[[[.1,.1]]])]:
            with self.assertRaises(ValueError):shape_input(**bad)
        shape_input(strokes=[[[.1,.1],[.2,.2]]],radius=.02);shape_input(polygon=[[0,0],[1,0],[1,1]]);shape_input(point=[.5,.5])

    def test_cli_quota_error_fails_fast_instead_of_spinning(self):
        from assistant import AssistantBridge
        from threading import Event
        from time import monotonic
        from unittest.mock import patch
        import tempfile
        # 模拟 CLI：打印额度用完后不退出（真实 Codex 会反复重试）。
        script=Path(tempfile.mkdtemp())/'fake-cli'
        script.write_text('#!/bin/sh\ncat >/dev/null\necho "ERROR: You have hit your usage limit" >&2\nsleep 60\n')
        script.chmod(0o755)
        bridge=AssistantBridge(SimpleNamespace(folder=Path(tempfile.mkdtemp())))
        start=monotonic()
        with patch('assistant.executable',return_value=str(script)):
            with self.assertRaises(ValueError) as error:bridge._invoke_once('codex','提示 quota 不算',Event(),monotonic()+30)
        self.assertLess(monotonic()-start,5)
        self.assertIn('额度',str(error.exception))
        from assistant import early_failure
        self.assertIsNone(early_failure('codex','用户说：0.4291 401 429'))

    def test_texture_and_local_have_no_stripe_seams(self):
        from render import render_full
        rgb=np.broadcast_to(np.linspace(.2,.8,300)[None,:,None],(600,300,3)).copy()
        image=Image.fromarray(np.uint8(rgb*255+.5))
        preview=image.resize((75,150));z=np.zeros((150,75));sky=z.copy();sky[:60]=1
        def context():
            c=SimpleNamespace(image=preview,rgb=np.asarray(preview,dtype=float)/255,
                              water=z,sky=sky,land=z,person=z,skin=z,dehazed=None)
            c.region=lambda name:getattr(c,name)
            return c
        disabled={key:False for key in ['levels','dehaze','contrast','water','sky','land','match','portrait']}
        params={'enabled':disabled,'texture':.8,'local':{'sky':{'exposure':-.5,'temperature':-.6,'feather':.6}}}
        first=np.asarray(render_full(image,params,context(),band=97),int)
        second=np.asarray(render_full(image,params,context(),band=211),int)
        self.assertLessEqual(np.abs(first-second).max(),1)
        plain=np.asarray(render_full(image,{'enabled':disabled},context(),band=211),int)
        # 局部：天空在上方，变暗变冷；底部远离天空的地方不受影响（暗角和颗粒另算）。
        self.assertLess(first[:150].mean(),plain[:150].mean()-5)
        self.assertGreater(first[:150,:,2].mean()-first[:150,:,0].mean(),plain[:150,:,2].mean()-plain[:150,:,0].mean())

    def test_local_only_changes_selected_region(self):
        from grade import apply_local
        lab=np.full((40,40,3),50.);lab[...,1]=5;lab[...,2]=10
        c=SimpleNamespace(sky=np.zeros((40,40)));c.sky[:20]=1;c.region=lambda name:getattr(c,name)
        out=apply_local(lab,c,{'sky':{'exposure':.5,'saturation':-.5,'feather':0}},40)
        self.assertGreater(out[:20,:,0].mean(),55);np.testing.assert_allclose(out[20:],lab[20:])
        self.assertLess(abs(out[:20,:,2]).mean(),10)
        with self.assertRaises(ValueError):parameters({'local':{'face':{'exposure':.2}}})
        with self.assertRaises(ValueError):parameters({'local':{'sky':{'exposure':3}}})
        with self.assertRaises(ValueError):parameters({'local':{'sky':{'glow':1}}})
        self.assertEqual(parameters({'local':{'sky':{'exposure':.2}}})['local']['sky']['exposure'],.2)

    def test_manual_box_and_brush_change_only_selected_pixels(self):
        from grade import apply_local
        image=Image.new('RGB',(100,100),(100,100,100))
        lab=np.full((100,100,3),50.)
        box='selection-123456789abc'; brush='selection-abcdef123456'
        masks={box:dict(box=[.1,.1,.3,.3]),brush:dict(box=[.6,.6,.8,.8],strokes=[[[.65,.65],[.75,.75]]],radius=.03)}
        context=SimpleNamespace(image=image)
        local={box:dict(exposure=.5,feather=0),brush:dict(exposure=-.5,feather=0)}
        out=apply_local(lab,context,local,100,masks)
        self.assertGreater(out[20,20,0],lab[20,20,0]);self.assertLess(out[70,70,0],lab[70,70,0])
        np.testing.assert_allclose(out[40:55,40:55],lab[40:55,40:55])
        self.assertEqual(parameters(dict(local=local,manual_masks=masks))['manual_masks'],masks)
        with self.assertRaises(ValueError):parameters(dict(local=local,manual_masks={box:masks[box]}))

    def test_ai_selected_adjustment_requires_and_persists_exact_selection(self):
        from assistant import validate_plan
        from smart import neutral
        image=Image.new('RGB',(64,64),(100,100,100));context=self.context(image)
        engine=SimpleNamespace(analysis=lambda key:(context,True))
        target=[dict(id='a',params=neutral())]
        plan=dict(reply='提亮选区',selection='none',actions=[dict(id='a',preset='keep',operations=[],
            adjustments=[dict(parameter='local_selected_exposure',mode='add',value=.4)])])
        with self.assertRaises(ValueError):validate_plan(plan,target,engine)
        shape=dict(id='a',box=[.1,.1,.4,.4],strokes=[[[.2,.2],[.3,.3]]],radius=.02)
        result=validate_plan(plan,target,engine,dict(repair_selection=shape))
        p=result['changes'][0]['params'];key=next(iter(p['manual_masks']))
        self.assertEqual(p['manual_masks'][key],{k:v for k,v in shape.items() if k!='id'})
        self.assertEqual(p['local'][key]['exposure'],.4)
        self.assertEqual(p['exposure'],0)

    def test_manual_mask_full_render_has_no_stripe_seams(self):
        from render import render_full
        image=Image.new('RGB',(120,240),(110,120,130));preview=image.resize((60,120));z=np.zeros((120,60))
        def context():
            c=SimpleNamespace(image=preview,rgb=np.asarray(preview,dtype=float)/255,
                              water=z,sky=z,land=z,person=z,skin=z,dehazed=None)
            c.region=lambda name:getattr(c,name)
            return c
        name='selection-123456789abc'
        p=dict(enabled={key:False for key in ['levels','dehaze','contrast','water','sky','land','match','portrait']},
               manual_masks={name:dict(box=[.1,.2,.6,.8])},local={name:dict(exposure=.5,feather=.4)})
        a=np.asarray(render_full(image,p,context(),band=43),int);b=np.asarray(render_full(image,p,context(),band=97),int)
        self.assertLessEqual(np.abs(a-b).max(),1)

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

    def test_ai_operations_are_bounded_and_require_real_context(self):
        from assistant import validate_plan
        from smart import neutral
        context=self.context(Image.new('RGB',(64,64),(120,135,145)))
        engine=SimpleNamespace(analysis=lambda key:(context,True))
        targets=[dict(id='one',params=neutral())]
        action=dict(id='one',preset='keep',adjustments=[],operations=[
            dict(kind='denoise',value=1),dict(kind='upscale',value=2),
            dict(kind='repair',value=0),dict(kind='match',value=0)])
        plan=dict(reply='准备处理',selection='none',actions=[action])
        available=dict(repair_selection=dict(id='one',box=[.1,.1,.4,.4]),reference_ids=['ref'])
        result=validate_plan(plan,targets,engine,available)
        self.assertEqual([op['kind'] for op in result['changes'][0]['operations']],['denoise','upscale','repair','match'])
        with self.assertRaises(ValueError):validate_plan(plan,targets,engine,dict(reference_ids=['ref']))
        with self.assertRaises(ValueError):validate_plan(plan,targets,engine,dict(repair_selection=available['repair_selection']))
        for op in [dict(kind='upscale',value=3),dict(kind='denoise',value=2),dict(kind='shell',value=0)]:
            invalid=deepcopy(plan);invalid['actions'][0]['operations']=[op]
            with self.assertRaises(ValueError):validate_plan(invalid,targets,engine,available)
        undo=deepcopy(plan);undo['actions'][0]['operations']=[dict(kind='undo',value=0)]
        with self.assertRaises(ValueError):validate_plan(undo,targets,engine,available)
        self.assertEqual(validate_plan(undo,targets,engine,dict(undo_available=True))['changes'][0]['operations'][0]['kind'],'undo')
        undo['actions'][0]['operations'].append(dict(kind='denoise',value=1))
        with self.assertRaises(ValueError):validate_plan(undo,targets,engine,dict(undo_available=True))

    def test_ai_cancellation_wins_before_result_is_published(self):
        from assistant import AssistantBridge
        from threading import Event
        from unittest.mock import patch
        from smart import neutral
        context=self.context(Image.new('RGB',(64,64),(120,135,145)))
        from threading import RLock
        engine=SimpleNamespace(lock=RLock(),analysis=lambda key:(context,True))
        bridge=AssistantBridge(engine);key='cancelled-job';event=Event()
        bridge.events[key]=event;bridge.jobs[key]=dict(state='preparing')
        data=dict(provider='codex',targets=[dict(id='one',params=neutral())],history=[],message='调整')
        def invoke(*args):
            return dict(reply='计划',selection='none',actions=[])
        def validate(*args):
            event.set()
            return dict(reply='计划',selection='none',changes=[])
        with patch.object(bridge,'_invoke',side_effect=invoke),patch('assistant.validate_plan',side_effect=validate):
            bridge._run(key,data)
        self.assertEqual(bridge.status(key)['state'],'cancelled')

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

    def test_codex_request_disables_general_tools(self):
        from assistant import AssistantBridge
        from threading import Event
        from time import monotonic
        from unittest.mock import Mock,patch
        with TemporaryDirectory() as folder:
            bridge=AssistantBridge(SimpleNamespace(folder=Path(folder)))
            commands=[]
            def run(command,**kwargs):
                commands.append(command)
                output=Path(command[command.index('--output-last-message')+1])
                output.write_text('{"reply":"测试","selection":"none","actions":[]}')
                child=Mock();child.stdin=Mock();child.poll.return_value=0;child.returncode=0
                return child
            with patch('assistant.executable',return_value='/test/codex'),patch('assistant.subprocess.Popen',side_effect=run):
                result=bridge._invoke_once('codex','测试',Event(),monotonic()+10)
            self.assertEqual(result['actions'],[])
            disabled={commands[0][i+1] for i,x in enumerate(commands[0][:-1]) if x=='--disable'}
            self.assertTrue({'shell_tool','unified_exec','apps','browser_use'}.issubset(disabled))

    def test_codex_receives_only_prepared_image_attachments(self):
        from assistant import AssistantBridge
        from threading import Event
        from time import monotonic
        from unittest.mock import Mock,patch
        with TemporaryDirectory() as folder:
            bridge=AssistantBridge(SimpleNamespace(folder=Path(folder)))
            sent=[]
            def run(command,**kwargs):
                paths=[Path(command[i+1]) for i,x in enumerate(command[:-1]) if x=='--image']
                sent.extend(path.read_bytes() for path in paths)
                Path(command[command.index('--output-last-message')+1]).write_text('{"reply":"ok","selection":"none","actions":[]}')
                child=Mock();child.stdin=Mock();child.poll.return_value=0;child.returncode=0
                return child
            with patch('assistant.executable',return_value='/test/codex'),patch('assistant.subprocess.Popen',side_effect=run):
                bridge._invoke_once('codex','test',Event(),monotonic()+10,[{'label':'a','data':b'first'}, {'label':'b','data':b'second'}])
            self.assertEqual(sent,[b'first',b'second'])

    def test_vision_consent_controls_end_to_end_cli_attachments(self):
        from assistant import AssistantBridge
        from smart import neutral
        from time import monotonic,sleep
        from unittest.mock import Mock,patch
        with TemporaryDirectory() as folder:
            root=Path(folder);source=root/'sample.png'
            Image.new('RGB',(48,32),(100,110,120)).save(source)
            engine=Engine(root);asset=engine.import_one(source)
            context=self.context(Image.new('RGB',(48,32),(100,110,120)))
            engine.analysis=lambda key:(context,True)
            bridge=AssistantBridge(engine);seen=[]
            def run(command,**kwargs):
                seen.append(sum(x=='--image' for x in command))
                Path(command[command.index('--output-last-message')+1]).write_text('{"reply":"ok","selection":"none","actions":[]}')
                child=Mock();child.stdin=Mock();child.poll.return_value=0;child.returncode=0
                return child
            with patch('assistant.executable',return_value='/test/codex'),patch('assistant.subprocess.Popen',side_effect=run):
                for allowed in [False,True]:
                    job=bridge.start(dict(provider='codex',message='只讨论',targets=[dict(id=asset.id,params=neutral())],image_consent=allowed))['id']
                    deadline=monotonic()+10
                    while bridge.status(job)['state'] in ('preparing','thinking') and monotonic()<deadline:sleep(.01)
                    self.assertEqual(bridge.status(job)['state'],'done')
            self.assertEqual(seen,[0,1])

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
