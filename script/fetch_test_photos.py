"""按需取公开许可样本，写入案例库；不上传、不安装依赖、不覆盖。"""
from concurrent.futures import ThreadPoolExecutor
from hashlib import sha256
import json
from pathlib import Path
import re
from urllib.parse import urlencode
from urllib.request import Request, urlopen

ROOT=Path(__file__).resolve().parents[1]
FOLDER=ROOT/'cases/2026-10-27_公开测试样本/原图'
HEADERS={'User-Agent':'PhotoEdit-TestCorpus/0.1 (local image editor development)'}


def get(url):
    with urlopen(Request(url,headers=HEADERS),timeout=25) as response:
        data=response.read(65*1024*1024+1)
        if len(data)>65*1024*1024: raise ValueError('样本超过单文件预算')
        return data


def commons(query):
    request=dict(action='query',format='json',generator='search',gsrsearch=query+' incategory:CC-Zero filetype:bitmap',
                 gsrnamespace=6,gsrlimit=12,prop='imageinfo',iiprop='url|extmetadata|size',iiurlwidth=1600)
    data=json.loads(get('https://commons.wikimedia.org/w/api.php?'+urlencode(request)))
    result=[]
    for page in data.get('query',{}).get('pages',{}).values():
        info=page.get('imageinfo',[{}])[0];meta=info.get('extmetadata',{})
        if meta.get('LicenseShortName',{}).get('value')!='CC0':continue
        if info.get('width',0)<600 or info.get('height',0)<400:continue
        url=info.get('thumburl') or info.get('url')
        name=page['title'].removeprefix('File:')
        if not name.lower().endswith(('.jpg','.jpeg','.png')):continue
        result.append(dict(name=name,url=url,source=info['descriptionurl'],license='CC0 1.0',
                           author=re.sub('<[^>]+>','',meta.get('Artist',{}).get('value','')),scene=query))
        if len(result)==2:break
    return result


def download(item):
    try:
        name=re.sub(r'[^\w. -]','_',item['name'])
        path=FOLDER/name
        if not path.exists():
            data=get(item['url'])
            with path.open('xb') as handle:handle.write(data)
        item.update(path=str(path.relative_to(ROOT)),sha256=sha256(path.read_bytes()).hexdigest(),bytes=path.stat().st_size)
        print('取得',name,flush=True)
        return item
    except Exception as exc:
        print('未取得',item['name'],str(exc),flush=True)
        return None


def main():
    FOLDER.mkdir(parents=True,exist_ok=True)
    queries=['tropical beach','forest landscape -painting -drawing -engraving -MET','city night',
             'portrait photograph -painting -drawing -engraving -MET','snow mountain','city street','sunset landscape']
    sources=[]
    manifest=FOLDER.parent/'sources.json'
    if manifest.exists():sources.extend(json.loads(manifest.read_text()))
    with ThreadPoolExecutor(max_workers=3) as pool:
        for query,result in zip(queries,pool.map(safe_commons,queries)):
            print('查找',query,len(result),flush=True);sources.extend(result)
    for name,scene in [('astronaut.png','portrait'),('chelsea.png','animal texture'),('rocket.jpg','night sky'),('camera.png','grayscale')]:
        sources.append(dict(name=name,url='https://raw.githubusercontent.com/scikit-image/scikit-image/v0.25.2/skimage/data/'+name,
                            source='https://scikit-image.org/docs/0.25.x/api/skimage.data.html',
                            license='Public domain / CC0 (per-image documentation)',author='see source',scene=scene))
    sources.append(dict(name='Tropical-beach.jpg',url='https://upload.wikimedia.org/wikipedia/commons/0/0b/Tropical-beach.jpg',
                        source='https://commons.wikimedia.org/wiki/File:Tropical-beach.jpg',license='CC0 1.0',author='Brodie Vissers',scene='tropical beach reference'))
    # 发布者提供逐文件 CC0 说明与校验和，原始来源 raw.pixls.us。
    for name in ['Ricoh-GR-III.DNG','Canon-5D-Mark-IV.CR2']:
        sources.append(dict(name=name,url='https://github.com/tellodaniel/revelraw-sample-raw-files/releases/download/v1/'+name,
                            source='https://github.com/tellodaniel/revelraw-sample-raw-files',license='CC0 1.0',author='raw.pixls.us contributor',scene='RAW decode'))
    unique={s['name']:s for s in sources}
    with ThreadPoolExecutor(max_workers=3) as pool: downloaded=[r for r in pool.map(download,unique.values()) if r]
    with manifest.open('w') as handle:json.dump(downloaded,handle,ensure_ascii=False,indent=2)
    print('样本',len(downloaded),'合计 MiB',round(sum(r['bytes'] for r in downloaded)/1024/1024,1),flush=True)


def safe_commons(query):
    try:return commons(query)
    except Exception as exc:print('检索失败',query,str(exc),flush=True);return []


if __name__=='__main__':main()
