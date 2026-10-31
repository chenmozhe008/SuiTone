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


class SelectionBlendTests(unittest.TestCase):
    def test_connected_generated_detail_survives_outside_selection_without_changing_unrelated_area(self):
        import numpy as np
        from PIL import ImageDraw
        from image_edit import composite_guided_selection
        original = Image.new('RGB', (400, 300), (110, 130, 160))
        generated = original.copy()
        draw = ImageDraw.Draw(generated)
        draw.rectangle((190, 35, 210, 175), fill=(220, 50, 20))
        draw.rectangle((15, 15, 50, 50), fill=(220, 50, 20))
        hard = np.zeros((300, 400), dtype=bool); hard[140:180, 170:230] = True
        result = np.asarray(composite_guided_selection(original, generated, hard))
        self.assertGreater(result[40, 200, 0], 200)
        np.testing.assert_array_equal(result[25, 25], [110, 130, 160])

    def test_large_global_change_does_not_expand_selection(self):
        import numpy as np
        from image_edit import composite_guided_selection
        original = Image.new('RGB', (400, 300), (60, 70, 80))
        generated = Image.new('RGB', (400, 300), (200, 180, 160))
        hard = np.zeros((300, 400), dtype=bool); hard[140:180, 170:230] = True
        result = np.asarray(composite_guided_selection(original, generated, hard))
        np.testing.assert_array_equal(result[0, 0], [60, 70, 80])

    def test_guided_blend_matches_surroundings_and_preserves_distant_pixels(self):
        import numpy as np
        from image_edit import composite_guided_selection
        original = Image.new('RGB', (400, 300), (120, 130, 160))
        generated = Image.new('RGB', (400, 300), (130, 146, 146))
        hard = np.zeros((300, 400), dtype=bool); hard[110:190, 140:260] = True
        out = np.asarray(composite_guided_selection(original, generated, hard))
        np.testing.assert_array_equal(out[0, 0], [120, 130, 160])
        self.assertLess(np.abs(out[150, 200].astype(int) - [120, 130, 160]).sum(), 5)

    def test_color_mismatch_is_softened_without_changing_outside_or_center(self):
        import numpy as np
        from image_edit import composite_selection
        original = Image.new('RGB', (400, 300), (110, 140, 180))
        generated = Image.new('RGB', (400, 300), (150, 165, 195))
        result = np.asarray(composite_selection(original, generated, {'box': [.2, .2, .8, .8]}))
        source = np.asarray(original)
        np.testing.assert_array_equal(result[:60], source[:60])
        np.testing.assert_array_equal(result[:, :80], source[:, :80])
        np.testing.assert_array_equal(result[150, 200], np.array([150, 165, 195], dtype=np.uint8))
        self.assertLess(abs(int(result[63, 200, 0]) - 110), 20)
        self.assertGreater(int(result[90, 200, 0]), int(result[63, 200, 0]))

    def test_nonrectangular_selection_preserves_other_pixels(self):
        import numpy as np
        from image_edit import composite_selection
        original = Image.new('RGB', (256, 256), (100, 110, 120))
        generated = Image.new('RGB', (256, 256), (180, 190, 200))
        result = np.asarray(composite_selection(original, generated, {'polygon': [[.1,.1],[.9,.1],[.5,.9]]}))
        np.testing.assert_array_equal(result[200, 20], np.array([100, 110, 120], dtype=np.uint8))
        self.assertGreater(int(result[100, 128, 0]), 100)

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

    def test_precise_edit_sends_black_edit_mask_and_limits_references(self):
        from email.parser import BytesParser
        from email import policy
        image = png()
        stencil = Image.new('L', (8, 8), 255)
        stencil.putpixel((3, 4), 0)
        out = BytesIO(); stencil.save(out, 'PNG'); mask = out.getvalue()
        calls = []
        class Response:
            def __init__(self, data): self.data = data
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self, limit): return self.data[:limit]
        def opener(request, timeout):
            calls.append(request)
            if len(calls) == 1: return Response(json.dumps({'data': [{'url': 'https://ideogram.ai/api/images/direct/test'}]}).encode())
            return Response(image)
        ideogram_edit('key', 'ideogram-4-5', image, '改变选区', references=[image]*3, mask=mask, opener=opener)
        content_type = calls[0].get_header('Content-type')
        message = BytesParser(policy=policy.default).parsebytes(('Content-Type: ' + content_type + '\r\nMIME-Version: 1.0\r\n\r\n').encode() + calls[0].data)
        parts = list(message.iter_parts())
        sent_mask = next(part.get_payload(decode=True) for part in parts if part.get_param('name', header='content-disposition') == 'mask')
        with Image.open(BytesIO(sent_mask)) as observed:
            self.assertEqual(observed.getpixel((3,4)), 0)
            self.assertEqual(observed.getpixel((0,0)), 255)
            self.assertEqual(observed.size, (8,8))
        self.assertEqual(sum(p.get_param('name', header='content-disposition') == 'reference_images' for p in parts), 3)
        with self.assertRaisesRegex(ValueError, '3 张'): ideogram_edit('key','ideogram-4-5',image,'edit',references=[image]*4,mask=mask,opener=opener)
        all_white = BytesIO(); Image.new('L',(8,8),255).save(all_white,'PNG')
        with self.assertRaisesRegex(ValueError, '选区'): ideogram_edit('key','ideogram-4-5',image,'edit',mask=all_white.getvalue(),opener=opener)

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

class NativeSelectionJobTests(unittest.TestCase):
    def test_marked_selection_is_a_separate_copy_and_preserves_inner_holes(self):
        import numpy as np
        from image_edit import marked_selection_image, jimeng_interactive_prompt
        original = Image.new('RGB', (200, 100), (20, 40, 60))
        mask = np.zeros((100, 200), dtype=bool)
        mask[20:80, 40:160] = True; mask[40:60, 80:120] = False
        marked = marked_selection_image(original, mask)
        self.assertEqual(original.getpixel((40, 20)), (20, 40, 60))
        self.assertEqual(marked.getpixel((40, 20)), (0, 230, 255))
        self.assertEqual(marked.getpixel((80, 40)), (0, 230, 255))
        self.assertEqual(marked.getpixel((5, 5)), (20, 40, 60))
        text = jimeng_interactive_prompt('添加小船', mask, {'box': [.2,.2,.8,.8]}, 'doubao-seedream-5-0-flash-260915', 'marked')
        self.assertIn('删除所有青色标记', text)
        self.assertNotIn('<bbox>', text)

    def test_rejects_marked_mode_for_unsupported_service_before_generation(self):
        from types import SimpleNamespace
        from image_edit import ImageEditBridge
        bridge = ImageEditBridge(SimpleNamespace(asset=lambda _: object()))
        base = dict(id='p', service='gemini', api_key='test', prompt='修改', image_consent=True,
                    selection={'box':[.1,.1,.4,.4]}, selection_guidance='marked')
        with self.assertRaisesRegex(ValueError, '不支持'): bridge.start(base)
        with self.assertRaisesRegex(ValueError, '不支持'):
            bridge.start(dict(base, service='jimeng', model='doubao-seedream-4-5-251128'))

    def test_marked_mode_sends_marked_copy_but_composites_onto_clean_original(self):
        from tempfile import TemporaryDirectory
        from types import SimpleNamespace
        from threading import RLock
        from time import monotonic, sleep
        from unittest.mock import patch
        from image_edit import ImageEditBridge
        with TemporaryDirectory() as folder:
            path = Path(folder) / 'rendered.png'
            Image.new('RGB', (200, 100), (30, 60, 90)).save(path)
            engine = SimpleNamespace(folder=Path(folder), lock=RLock(), asset=lambda _: object(),
                                     render_full_png=lambda *args: {'path': str(path)})
            bridge = ImageEditBridge(engine); calls = []
            def fake_call(service, key, model, image, prompt, **kwargs):
                with Image.open(BytesIO(image)) as img:
                    calls.append((img.convert('RGB').getpixel((40, 20)), prompt))
                out = BytesIO(); Image.new('RGB', (200, 100), (30, 60, 90)).save(out, 'PNG')
                return [{'data': out.getvalue(), 'mime': 'image/png'}]
            payload = dict(id='p', service='jimeng', model='doubao-seedream-5-0-flash-260915', api_key='test',
                           prompt='添加', image_consent=True, selection={'box':[.2,.2,.8,.8]}, selection_guidance='marked')
            with patch('image_edit.call_service', side_effect=fake_call):
                job = bridge.start(payload)['id']; deadline = monotonic() + 5
                while monotonic() < deadline and bridge.status(job)['state'] == 'running': sleep(.01)
                state = bridge.status(job)
            self.assertEqual(state['state'], 'done', state)
            self.assertGreater(calls[0][0][1], 150)
            self.assertIn('删除所有青色标记', calls[0][1])
            with Image.open(path) as original, Image.open(state['paths'][0]) as output:
                self.assertEqual(original.getpixel((40,20)), (30,60,90))
                self.assertEqual(output.getpixel((40,20)), (30,60,90))

    def test_jimeng_supported_models_use_official_coordinates(self):
        import numpy as np
        from image_edit import jimeng_interactive_prompt
        mask = np.zeros((100, 200), dtype=bool); mask[20:80, 50:150] = True
        for model in ('doubao-seedream-5-0-flash-260915', 'doubao-seedream-5-0-pro-260628'):
            prompt = jimeng_interactive_prompt('添加云朵', mask, {'box': [.25, .2, .75, .8]}, model)
            self.assertTrue(prompt.startswith('添加云朵'))
            self.assertIn('<bbox>250 200 750 800</bbox>', prompt)
        point = jimeng_interactive_prompt('修改', mask, {'parts': [{'point': [1.0, .23]}]}, 'doubao-seedream-5-0-flash-260915')
        self.assertIn('<point>999 230</point>', point)
        multipart = jimeng_interactive_prompt('修改', mask, {'parts': [{'point': [.3, .4]}, {'subtract': True, 'box': [.1,.1,.2,.2]}]}, 'doubao-seedream-5-0-flash-260915')
        self.assertIn('<bbox>250 200 750 800</bbox>', multipart)
        older = jimeng_interactive_prompt('修改', mask, {'box': [.25,.2,.75,.8]}, 'doubao-seedream-4-5-251128')
        self.assertNotIn('<bbox>', older)
        self.assertIn('25%–75%', older)
        with self.assertRaisesRegex(ValueError, '过长'):
            jimeng_interactive_prompt('字' * 4000, mask, {'box': [.25,.2,.75,.8]}, 'doubao-seedream-5-0-pro-260628')

    def test_semantic_selection_hint_uses_mask_bounds_and_keeps_user_text(self):
        import numpy as np
        from image_edit import prompt_for_selection
        mask = np.zeros((100, 200), dtype=bool); mask[20:80, 50:150] = True
        prompt = prompt_for_selection('换成云朵', mask)
        self.assertTrue(prompt.startswith('换成云朵'))
        self.assertIn('25%–75%', prompt); self.assertIn('20%–80%', prompt)
        self.assertEqual(prompt_for_selection('字' * 4000, mask), '字' * 4000)

    def test_mask_and_crop_are_sent_in_visible_coordinates(self):
        from tempfile import TemporaryDirectory
        from types import SimpleNamespace
        from threading import RLock
        from time import monotonic, sleep
        from unittest.mock import patch
        import numpy as np
        from image_edit import ImageEditBridge
        source = Image.new('RGB', (120, 80), (40, 80, 120))
        with TemporaryDirectory() as folder:
            engine = SimpleNamespace(folder=Path(folder), lock=RLock(), asset=lambda _: object())
            rendered_path = Path(folder) / 'rendered.png'
            source.crop((30, 0, 90, 80)).save(rendered_path)
            engine.render_full_png = lambda key, params, quality: {'path': str(rendered_path)}
            bridge = ImageEditBridge(engine); calls = []
            def fake_call(service, key, model, image_bytes, prompt, **kwargs):
                calls.append((image_bytes, kwargs))
                with Image.open(BytesIO(image_bytes)) as sent:
                    output = Image.new('RGB', sent.size, (220, 120, 30))
                buffer = BytesIO(); output.save(buffer, 'PNG')
                return [{'data': buffer.getvalue(), 'mime': 'image/png'}]
            payload = dict(id='photo', service='ideogram', api_key='test', model='ideogram-4-5',
                           image_consent=True, prompt='修改', params={'crop': [.25, 0, .5, 1]},
                           selection={'box': [.25, .25, .75, .75]})
            with patch('image_edit.call_service', side_effect=fake_call):
                job = bridge.start(payload)['id']; deadline = monotonic() + 5
                while monotonic() < deadline and bridge.status(job)['state'] == 'running': sleep(.01)
                state = bridge.status(job)
            self.assertEqual(state['state'], 'done', state)
            self.assertEqual(state['before_path'], str(rendered_path))
            self.assertTrue(Path(state['raw_paths'][0]).is_file())
            sent, options = calls[0]
            with Image.open(BytesIO(sent)) as photo, Image.open(BytesIO(options['mask'])) as mask:
                self.assertEqual(photo.size, (60, 80))
                self.assertEqual(mask.size, photo.size)
                self.assertEqual(mask.getpixel((30, 40)), 0)
                self.assertEqual(mask.getpixel((0, 0)), 255)
            with Image.open(state['paths'][0]) as output:
                result = np.asarray(output)
            self.assertEqual(result.shape, (80, 60, 3))
            np.testing.assert_array_equal(result[0, 0], [40, 80, 120])
            self.assertGreater(int(result[40, 30, 0]), 100)

    def test_jimeng_and_gemini_keep_complete_generated_object_beyond_selection(self):
        from tempfile import TemporaryDirectory
        from types import SimpleNamespace
        from threading import RLock
        from time import monotonic, sleep
        from unittest.mock import patch
        from PIL import ImageDraw
        from image_edit import ImageEditBridge
        source = Image.new('RGB', (200, 100), (60, 100, 140))
        with TemporaryDirectory() as folder:
            for service in ('jimeng', 'gemini'):
                engine = SimpleNamespace(folder=Path(folder), lock=RLock(), asset=lambda _: object())
                rendered_path = Path(folder) / 'rendered.png'; source.save(rendered_path)
                render_calls = []
                def render(key, params, quality):
                    render_calls.append((params, quality)); return {'path': str(rendered_path)}
                engine.render_full_png = render
                bridge = ImageEditBridge(engine); calls = []
                def fake_call(service, key, model, image_bytes, prompt, **kwargs):
                    with Image.open(BytesIO(image_bytes)) as sent:
                        self.assertEqual(sent.size, (200, 100))
                        self.assertTrue(all(abs(a-b) <= 2 for a, b in zip(sent.getpixel((5, 5)), (60, 100, 140))))
                    calls.append((prompt, kwargs))
                    output = Image.new('RGB', source.size, (90, 130, 170))
                    ImageDraw.Draw(output).rectangle((72, 40, 128, 60), fill=(200, 50, 20))
                    out = BytesIO(); output.save(out, 'PNG')
                    return [{'data': out.getvalue(), 'mime': 'image/png'}]
                payload = dict(id='photo', service=service, api_key='test', image_consent=True,
                               prompt='在水面加一条船', params={'exposure': .5}, quality={'denoise':False,'scale':1}, selection={'box':[.4,.3,.6,.7]})
                with patch('image_edit.call_service', side_effect=fake_call):
                    job = bridge.start(payload)['id']; deadline = monotonic() + 5
                    while monotonic() < deadline and bridge.status(job)['state'] == 'running': sleep(.01)
                    state = bridge.status(job)
                self.assertEqual(state['state'], 'done', state)
                self.assertIn('结合整张照片', calls[0][0])
                if service == 'jimeng': self.assertIn('<bbox>400 300 605 710</bbox>', calls[0][0])
                self.assertIn('保持完整' if service == 'jimeng' else '保持物体完整', calls[0][0])
                self.assertEqual(render_calls[0][0]['exposure'], .5)
                with Image.open(state['paths'][0]) as result:
                    self.assertGreater(result.getpixel((73, 50))[0], 170)
                    self.assertGreater(result.getpixel((127, 50))[0], 170)
                    self.assertEqual(result.getpixel((5, 5)), (60, 100, 140))

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
