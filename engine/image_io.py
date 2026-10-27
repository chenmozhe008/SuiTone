"""本地解码、色彩管理和独占写入；不裁切、不覆盖。"""
from io import BytesIO
from pathlib import Path
import subprocess
import tempfile
from PIL import Image, ImageCms, ImageOps

RAW_EXTENSIONS = {'.dng', '.cr2', '.cr3', '.nef', '.arw', '.raf', '.rw2', '.orf', '.pef'}
EXTENSIONS = RAW_EXTENSIONS | {'.jpg', '.jpeg', '.png', '.heic', '.heif', '.tif', '.tiff'}
SRGB = ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes()


def load_pixels(path,long=None):
    path=Path(path)
    if path.suffix.lower() in RAW_EXTENSIONS:
        import numpy as np
        from raw import load_raw_array
        rgb=load_raw_array(str(path),long=long)
        return Image.fromarray(np.uint8(rgb*255+.5)),rgb
    return load_image(path,long),None


def load_image(path, long=None):
    path = Path(path).expanduser().resolve(strict=True)
    if path.suffix.lower() in RAW_EXTENSIONS:
        from raw import load_raw
        return load_raw(str(path), long=long)
    if path.suffix.lower() in {'.heic', '.heif'}:
        with tempfile.TemporaryDirectory(prefix='photo-edit-heic-') as folder:
            target = Path(folder) / 'decoded.tiff'
            subprocess.run(['/usr/bin/sips', '-s', 'format', 'tiff', str(path), '--out', str(target)],
                           check=True, capture_output=True)
            return load_image(target, long=long)
    with Image.open(path) as source:
        im = ImageOps.exif_transpose(source)
        profile = source.info.get('icc_profile')
        if profile:
            im = ImageCms.profileToProfile(im.convert('RGB'), ImageCms.ImageCmsProfile(BytesIO(profile)),
                                          ImageCms.createProfile('sRGB'), outputMode='RGB')
        else:
            im = im.convert('RGB')
        if long and max(im.size) > long:
            im.thumbnail((long, long), Image.Resampling.LANCZOS)
        return im.copy()


def save_new(image, path):
    """O_EXCL 在检查与写入之间也不会覆盖已有文件。"""
    path = Path(path)
    fmt = 'PNG' if path.suffix.lower() == '.png' else 'JPEG'
    with path.open('xb') as handle:
        image.save(handle, format=fmt, icc_profile=SRGB, **({'quality': 94, 'subsampling': 0} if fmt == 'JPEG' else {'compress_level':1}))
    return str(path)
