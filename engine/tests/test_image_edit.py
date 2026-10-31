from io import BytesIO
from pathlib import Path
import base64,json,sys,unittest
from PIL import Image
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from image_edit import gemini_edit, call_service, reference_limit
from ideogram_edit import ideogram_edit


def png():
    out=BytesIO();Image.new('RGB',(8,8),'red').save(out,format='PNG');return out.getvalue()


class ImageEditTests(unittest.TestCase):
    def test_gemini_uses_image_and_returns_valid_image_without_key_in_body(self):
        calls=[]
        class Response:
            def __enter__(self):return self
            def __exit__(self,*args):pass
            def read(self,limit):return json.dumps({'candidates':[{'content':{'parts':[{'inlineData':{
                'mimeType':'image/png','data':base64.b64encode(png()).decode()}}]}}]}).encode()
        def opener(request,timeout):calls.append(request);return Response()
        result=gemini_edit('fixture-secret','gemini-image',png(),'移除杂物',opener=opener)
        self.assertEqual(result[0]['data'],png())
        self.assertNotIn('fixture-secret',calls[0].data.decode())
        self.assertIn('generateContent',calls[0].full_url)
        body=json.loads(calls[0].data)
        self.assertEqual(body['generationConfig']['responseModalities'],['TEXT','IMAGE'])
        self.assertEqual(body['contents'][0]['parts'][1]['inline_data']['mime_type'],'image/png')

    def test_gemini_rejects_empty_prompt_and_invalid_image(self):
        with self.assertRaises(ValueError):gemini_edit('key','model',png(),'')
        with self.assertRaises(ValueError):gemini_edit('key','model',b'not an image','修图')


class IdeogramTests(unittest.TestCase):
    def test_precise_edit_uploads_references_and_downloads_result_without_key(self):
        calls = []
        class Response:
            def __init__(self, data): self.data = data
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self, limit): return self.data[:limit]
        def opener(request, timeout):
            calls.append(request)
            if len(calls) == 1: return Response(json.dumps({'data': [{'url': 'https://ideogram.ai/api/images/direct/test'}]}).encode())
            return Response(png())
        result = call_service('ideogram', 'fixture-secret', 'ideogram-4-5', png(), '换背景', references=[png()], opener=opener)
        self.assertEqual(result[0]['data'], png())
        self.assertIn(b'name="reference_images"', calls[0].data)
        self.assertNotIn(b'fixture-secret', calls[0].data)
        self.assertIsNone(calls[1].get_header('Api-key'))
        self.assertEqual(reference_limit('ideogram', 'ideogram-4-5'), 4)

    def test_rejects_untrusted_download_url_and_excess_references(self):
        class Response:
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self, limit): return b'{"data":[{"url":"https://evil.example/image"}]}'
        calls = []
        def opener(request, timeout): calls.append(request); return Response()
        with self.assertRaises(ValueError): ideogram_edit('key', 'ideogram-4-5', png(), '修图', opener=opener)
        self.assertEqual(len(calls), 1)
        with self.assertRaises(ValueError): ideogram_edit('key', 'ideogram-4-5', png(), '修图', references=[png()]*5, opener=opener)

class AspectRatioTests(unittest.TestCase):
    def test_gemini_ratio_is_sent_in_image_config(self):
        calls=[]
        class Response:
            def __enter__(self): return self
            def __exit__(self,*args): pass
            def read(self,limit): return json.dumps({'candidates':[{'content':{'parts':[{'inlineData':{'mimeType':'image/png','data':base64.b64encode(png()).decode()}}]}}]}).encode()
        def opener(request,timeout): calls.append(request); return Response()
        gemini_edit('key','gemini-image',png(),'change',aspect_ratio='16:9',opener=opener)
        self.assertEqual(json.loads(calls[0].data)['generationConfig']['imageConfig']['aspectRatio'],'16:9')

    def test_jimeng_ratio_respects_each_model_pixel_limits(self):
        from jimeng_edit import jimeng_edit
        calls=[]
        class Response:
            def __enter__(self): return self
            def __exit__(self,*args): pass
            def read(self,limit): return json.dumps({'data':[{'b64_json':base64.b64encode(png()).decode()}]}).encode()
        def opener(request,timeout): calls.append(request); return Response()
        for model,low,high in [('doubao-seedream-5-0-pro-260628',921600,4624220),('doubao-seedream-4-5-251128',3686400,16777216),('doubao-seedream-5-0-260128',3686400,16777216)]:
            for ratio in ('1:1','16:9','9:16','21:9'):
                jimeng_edit('key',model,png(),'change',aspect_ratio=ratio,opener=opener)
                w,h=map(int,json.loads(calls[-1].data)['size'].split('x'))
                rw,rh=map(int,ratio.split(':'))
                self.assertTrue(low <= w*h <= high, (model,ratio,w,h))
                self.assertAlmostEqual(w/h,rw/rh,delta=.03)

    def test_ideogram_and_selection_reject_unsupported_ratios(self):
        from image_edit import ImageEditBridge
        class Engine:
            def asset(self,key): return object()
        bridge=ImageEditBridge(Engine())
        base=dict(id='a',image_consent=True,service='mock',prompt='change',aspect_ratio='1:1')
        with self.assertRaisesRegex(ValueError,'选区'): bridge.start(dict(base,selection={'box':[.1,.1,.5,.5]}))
        with self.assertRaisesRegex(ValueError,'比例'): bridge.start(dict(base,service='ideogram',api_key='key'))
        with self.assertRaisesRegex(ValueError,'比例'): call_service('ideogram','key','ideogram-4-5',png(),'change',aspect_ratio='1:1')
