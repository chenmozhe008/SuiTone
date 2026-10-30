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
