from io import BytesIO
from pathlib import Path
import base64,json,sys,unittest
from PIL import Image
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from image_edit import gemini_edit


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
