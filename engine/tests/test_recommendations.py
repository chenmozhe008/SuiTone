from pathlib import Path
import sys
import unittest
from tempfile import TemporaryDirectory
from time import monotonic, sleep
from unittest.mock import patch
import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from recommendations import candidates, select
from ai_recommendation import RecommendationBridge


class RecommendationTests(unittest.TestCase):
    def test_local_http_recommendations_require_token_and_return_results(self):
        from analysis import Analysis
        from grade import rgb2lab
        from service import Engine,serve
        from smart import neutral
        from threading import Event,Thread
        from http.server import ThreadingHTTPServer
        from urllib.error import HTTPError
        from urllib.request import Request,urlopen
        import json
        with TemporaryDirectory() as folder:
            root=Path(folder);source=root/'sample.png';image=Image.new('RGB',(32,32),(100,110,120));image.save(source)
            engine=Engine(root);asset=engine.import_one(source)
            context=Analysis.__new__(Analysis);context.image=image
            context.rgb=np.asarray(image,dtype=float)/255;context.lab=rgb2lab(context.rgb);context.dehazed=None
            for name in ('water','sky','land','person','skin'):setattr(context,name,np.zeros((32,32)))
            engine.analysis=lambda key:(context,True)
            ready=Event();servers=[];token='fixture-session-token'
            def make_server(*args,**kwargs):
                server=ThreadingHTTPServer(*args,**kwargs);servers.append(server);ready.set();return server
            response={'reply':'{"cards":["warm","shadows","cinema"]}','selection':'none','actions':[]}
            with patch('service.Engine',return_value=engine),patch('service.ThreadingHTTPServer',side_effect=make_server),\
                 patch('assistant.executable',return_value='/fake/codex'),\
                 patch.object(engine.ai_recommendations.bridge,'_invoke',return_value=response):
                thread=Thread(target=serve,args=(root,token,False),daemon=True);thread.start()
                self.assertTrue(ready.wait(3))
                base='http://127.0.0.1:'+str(servers[0].server_port)
                def request(path,data=None,authorized=True):
                    headers={'Authorization':'Bearer '+token} if authorized else {}
                    payload=json.dumps(data).encode() if data is not None else None
                    with urlopen(Request(base+path,data=payload,headers=headers),timeout=3) as result:
                        return json.load(result)
                try:
                    with self.assertRaises(HTTPError) as denied:request('/recommendation-status?id=x',authorized=False)
                    self.assertEqual(denied.exception.code,403)
                    job=request('/recommendation-start',{'provider':'codex','image_consent':False,
                        'targets':[{'id':asset.id,'params':neutral()}]})['id']
                    deadline=monotonic()+3
                    while monotonic()<deadline:
                        result=request('/recommendation-status?id='+job)
                        if result['state'] not in ('thinking','preparing'):break
                        sleep(.01)
                    self.assertEqual(result['state'],'done')
                    self.assertEqual([card['id'] for card in result['cards']],['warm','shadows','cinema'])
                finally:
                    servers[0].shutdown();thread.join(3)
                    self.assertFalse(thread.is_alive())

    def test_suggestions_and_chat_run_independently_and_cancel_separately(self):
        from analysis import Analysis
        from grade import rgb2lab
        from service import Engine
        from smart import neutral
        from threading import Event
        with TemporaryDirectory() as folder:
            root=Path(folder);source=root/'sample.png';image=Image.new('RGB',(32,32),(100,110,120));image.save(source)
            engine=Engine(root);asset=engine.import_one(source)
            context=Analysis.__new__(Analysis);context.image=image
            context.rgb=np.asarray(image,dtype=float)/255;context.lab=rgb2lab(context.rgb);context.dehazed=None
            for name in ('water','sky','land','person','skin'):setattr(context,name,np.zeros((32,32)))
            engine.analysis=lambda key:(context,True)
            started=Event();release=Event()
            def slow_recommendation(provider,prompt,cancel):
                started.set()
                while not release.wait(.01):
                    if cancel.is_set():raise InterruptedError()
                raise InterruptedError()
            response={'reply':'可以调整','selection':'none','actions':[]}
            with patch('assistant.executable',return_value='/fake/codex'),\
                 patch.object(engine.ai_recommendations.bridge,'_invoke',side_effect=slow_recommendation),\
                 patch.object(engine.assistant,'_invoke',return_value=response):
                try:
                    recommendation=engine.ai_recommendations.start({'provider':'codex','image_consent':False,
                        'targets':[{'id':asset.id,'params':neutral()}]})['id']
                    self.assertTrue(started.wait(3))
                    chat=engine.assistant.start({'provider':'codex','message':'讨论调整','image_consent':False,
                        'targets':[{'id':asset.id,'params':neutral()}]})['id']
                    deadline=monotonic()+3
                    while monotonic()<deadline and engine.assistant.status(chat)['state'] in ('preparing','thinking'):sleep(.01)
                    self.assertEqual(engine.assistant.status(chat)['state'],'done')
                    engine.ai_recommendations.cancel(recommendation)
                    deadline=monotonic()+3
                    while monotonic()<deadline and engine.ai_recommendations.status(recommendation)['state'] in ('preparing','thinking'):sleep(.01)
                    self.assertEqual(engine.ai_recommendations.status(recommendation)['state'],'cancelled')
                    self.assertEqual(engine.assistant.status(chat)['state'],'done')
                finally:release.set()

    def test_recommendations_use_separate_real_job_and_apply_candidate(self):
        from analysis import Analysis
        from grade import rgb2lab
        from service import Engine
        from smart import neutral
        with TemporaryDirectory() as folder:
            root=Path(folder);source=root/'sample.png';image=Image.new('RGB',(32,32),(100,110,120));image.save(source)
            engine=Engine(root);asset=engine.import_one(source)
            context=Analysis.__new__(Analysis);context.image=image
            context.rgb=np.asarray(image,dtype=float)/255;context.lab=rgb2lab(context.rgb);context.dehazed=None
            for name in ('water','sky','land','person','skin'):setattr(context,name,np.zeros((32,32)))
            engine.analysis=lambda key:(context,True)
            engine.preview=lambda key,params,quality=None:{'preview':'local-fixture'}
            response={'reply':'{"cards":["warm","shadows","cinema"]}','selection':'none','actions':[]}
            with patch('assistant.executable',return_value='/fake/codex'),patch.object(engine.ai_recommendations.bridge,'_invoke',return_value=response):
                started=engine.ai_recommendations.start({'provider':'codex','image_consent':False,
                    'targets':[{'id':asset.id,'params':neutral()}]})
                deadline=monotonic()+5
                while monotonic()<deadline and engine.ai_recommendations.status(started['id'])['state'] in ('thinking','preparing'):sleep(.01)
                result=engine.ai_recommendations.status(started['id'])
            self.assertEqual(result['state'],'done')
            self.assertEqual([card['id'] for card in result['cards']],['warm','shadows','cinema'])
            applied=engine.apply_suggestion(asset.id,'warm',neutral())
            self.assertAlmostEqual(applied['params']['temperature'],.12)
            with self.assertRaises(ValueError):engine.apply_suggestion(asset.id,'sky',neutral())

    def test_background_model_choices_are_validated_without_changing_photo(self):
        class Analysis:
            lab=np.full((10,10,3),50.)
            def summary(self):return {'sky':{'available':False},'person':{'available':True}}
        class Engine:
            def analysis(self,key):return Analysis(),True
        class Bridge:
            def __init__(self):self.result={'state':'thinking'};self.request=None
            def start(self,request):self.request=request;return {'id':'job'}
            def status(self,key):return self.result
            def cancel(self,key):return {'cancelled':True}
        bridge=Bridge();worker=RecommendationBridge(Engine(),bridge)
        request={'provider':'codex','targets':[{'id':'a','params':{}}],'image_consent':False}
        job=worker.start(request)['id']
        self.assertEqual(worker.status(job)['state'],'thinking')
        self.assertFalse(bridge.request['image_consent'])
        self.assertEqual(bridge.request['reference_ids'],[])
        bridge.result={'state':'done','selection':'none','changes':[],
                       'reply':'{"cards":["person","shadows","cinema"]}'}
        self.assertEqual([c['id'] for c in worker.status(job)['cards']],['person','shadows','cinema'])
        bridge.result['reply']='{"cards":["sky","shadows","cinema"]}'
        self.assertEqual(worker.status(job)['state'],'error')
        bridge.result['reply']='{"cards":["person","shadows","cinema"]}'
        bridge.result['changes']=[{'id':'a'}]
        self.assertEqual(worker.status(job)['state'],'error')

    def test_model_cannot_offer_missing_regions_or_invent_operations(self):
        class Analysis:
            lab=np.full((10,10,3),50.)
            def summary(self):
                return {'sky': {'available': False}, 'person': {'available': True}}
        pool=candidates(Analysis())
        chosen=select({'cards':['person','shadows','cinema']},pool)
        self.assertEqual([item['id'] for item in chosen],['person','shadows','cinema'])
        self.assertEqual(chosen[0]['adjustments'][0]['parameter'],'person_l')
        for invalid in [
            {'cards':['sky','shadows','cinema']},
            {'cards':['person','shadows','unknown']},
            {'cards':['person','person','shadows']},
            {'cards':['person','shadows','cinema'],'operations':['arbitrary']},
        ]:
            with self.subTest(plan=invalid),self.assertRaises(ValueError):select(invalid,pool)
        chosen[0]['title']='changed locally'
        self.assertNotEqual(next(item for item in pool if item['id']=='person')['title'],'changed locally')


if __name__=='__main__':unittest.main()
