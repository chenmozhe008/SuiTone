"""共享 SegFormer 概率缓存；缩略图、调色、肤色保护复用一次识别。"""
from collections import OrderedDict
from hashlib import sha256
from pathlib import Path
from threading import RLock
import json
import os
from zipfile import BadZipFile
from uuid import uuid4
import numpy as np
from PIL import Image
from paths import ASSETS

MODEL_DIR = ASSETS / 'segformer'
_session = None
_cache = OrderedDict()
_lock = RLock()
inference_count = 0
cache_dir = None


def probabilities(image):
    global _session, inference_count
    signature = str(((MODEL_DIR / 'model.onnx').stat().st_mtime_ns,
                     (MODEL_DIR / 'config.json').stat().st_mtime_ns,'imagenet-512-bicubic-v1'))
    digest = sha256(image.tobytes() + signature.encode()).hexdigest()
    key = (image.size, digest)
    with _lock:
        if key in _cache:
            _cache.move_to_end(key)
            return _cache[key]
        labels = {int(k): v for k, v in json.loads((MODEL_DIR / 'config.json').read_text())['id2label'].items()}
        disk = Path(cache_dir) / (digest + '.npz') if cache_dir else None
        if disk and disk.exists():
            try:
                with np.load(disk) as stored:
                    probabilities = stored['p']
                    if probabilities.ndim != 3 or probabilities.shape[0] != len(labels) or not np.isfinite(probabilities).all():
                        raise ValueError('invalid segmentation cache')
                    result = (probabilities, labels)
                _cache[key] = result
                while len(_cache) > 8: _cache.popitem(last=False)
                return result
            except (OSError, ValueError, KeyError, EOFError, BadZipFile):
                pass
        import onnxruntime as ort
        if _session is None:
            opts = ort.SessionOptions()
            opts.intra_op_num_threads = 4
            _session = ort.InferenceSession(str(MODEL_DIR / 'model.onnx'), opts,
                                           providers=['CPUExecutionProvider'])
        x = np.asarray(image.resize((512, 512), Image.Resampling.BICUBIC), np.float32) / 255
        x = ((x - [0.485, 0.456, 0.406]) / [0.229, 0.224, 0.225]).transpose(2, 0, 1)[None].astype(np.float32)
        logits = _session.run(None, {_session.get_inputs()[0].name: x})[0][0]
        exp = np.exp(logits - logits.max(0))
        result = (exp / exp.sum(0), labels)
        inference_count += 1
        _cache[key] = result
        if disk:
            disk.parent.mkdir(parents=True, exist_ok=True)
            temporary=disk.with_name(digest+'-'+uuid4().hex+'.npz')
            np.savez_compressed(temporary, p=result[0])
            os.replace(temporary,disk)
        while len(_cache) > 8:
            _cache.popitem(last=False)
        return result


def mask(image, names, result=None):
    p, labels = result if result is not None else probabilities(image)
    ids = [i for i, name in labels.items() if any(n in name.split(', ') for n in names)]
    small = p[ids].sum(0) if ids else np.zeros(p.shape[1:], np.float32)
    return np.clip(np.asarray(Image.fromarray(small).resize(image.size, Image.Resampling.BICUBIC)), 0, 1)
