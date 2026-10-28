"""为视觉验收结果生成本地逐条对照和人工评分页面。"""
from html import escape
from pathlib import Path
import json
import shutil
import sys
from visual_acceptance import CASES

if len(sys.argv)!=2:
    raise SystemExit('用法: python -B script/visual_review_gallery.py <results.json>')
path=Path(sys.argv[1]).resolve(strict=True)
report=json.loads(path.read_text())
root=path.parent
for side, name in [('before','01-suggestions-actual.png'),('after','03-codex-vision-night.png')]:
    source=root.parent/'stage2-20261028'/name
    destination=root/('05-'+side+'.png')
    if source.exists() and not destination.exists():shutil.copyfile(source,destination)
cards=[]
existing={case['id']:case for case in report.get('cases',[])}
planned=[existing.get(key,dict(id=key,scene=scene,prompt=prompt,initial=dict(state='error',error='尚未运行')))
         for key,scene,prompt in CASES if key!='05']
for case in planned:
    key=case['id'];state=case['initial']['state']
    before=root/(key+'-before.png');after=root/(key+'-after.png')
    available=before.exists() and after.exists()
    if available:
        pictures=f'<div class="pair"><figure><img src="{key}-before.png"><figcaption>调整前</figcaption></figure><figure><img src="{key}-after.png"><figcaption>调整后</figcaption></figure></div>'
    else:
        message=escape(case['initial'].get('error',case.get('execution_error','未生成可比较的结果')))
        pictures=f'<p class="error">此条未完成：{message}</p>'
    disabled='' if available else ' disabled'
    changes=case['initial'].get('changes',[])
    notes=[note for change in changes for note in change.get('notes',[])]
    review=case.get('review') or {}
    if review.get('state')=='done' and not case.get('review_skipped'):
        notes += [note for change in review.get('changes',[]) for note in change.get('notes',[])]
    details=escape('；'.join(notes) or '没有参数变动')
    reply=escape(case['initial'].get('reply',''))
    review_status=('未复看' if not review else '已复看' if review.get('state')=='done' else '复看未完成')
    if case.get('review_skipped'):review_status+='；复看调整已跳过'
    cards.append(f'''<article data-id="{key}"><h2>{key} · {escape(case['scene'])}</h2><p>{escape(case['prompt'])}</p><p>模型回复：{reply or '无回复'}</p><p>实际调整：{details} · {escape(review_status)}</p>{pictures}<div class="grade"><label><input type="radio" name="g{key}" value="pass"{disabled}>方向和区域正确</label><label><input type="radio" name="g{key}" value="fail"{disabled}>不符合要求</label><label><input type="radio" name="g{key}" value="pending" checked>尚未评分</label></div><textarea placeholder="可填写原因（选填）"></textarea></article>''')
case05='''<article data-id="05"><h2>05 · 夜景</h2><p>保留夜景氛围，稍微打开暗部，不要把灯光压灭。</p><p>这条是在实际 App 中运行的首条测试，当时复看功能尚未接入。</p><div class="pair"><figure><img src="05-before.png"><figcaption>调整前 · 实际界面</figcaption></figure><figure><img src="05-after.png"><figcaption>调整后 · 实际界面</figcaption></figure></div><div class="grade"><label><input type="radio" name="g05" value="pass">方向和区域正确</label><label><input type="radio" name="g05" value="fail">不符合要求</label><label><input type="radio" name="g05" value="pending" checked>尚未评分</label></div><textarea placeholder="可填写原因（选填）"></textarea></article>'''
cards.insert(min(4,len(cards)),case05)
html='''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>随心调色 · 视觉验收</title><style>body{background:#202020;color:#eee;font:15px -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;margin:0}header{position:sticky;top:0;background:#282828ee;padding:16px 5%;z-index:2;display:flex;align-items:center;gap:20px}header h1{font-size:19px;margin:0;margin-right:auto}button{padding:8px 16px;border:0;border-radius:7px}main{max-width:1200px;margin:auto;padding:20px}article{background:#2e2e2e;padding:18px;margin:18px 0;border-radius:10px}h2{font-size:16px}.pair{display:flex;gap:12px}figure{flex:1;margin:0;min-width:0}img{width:100%;object-fit:contain;background:#111}figcaption{font-size:12px;color:#aaa}.grade{display:flex;gap:20px;margin:18px 0}textarea{width:100%;height:55px;box-sizing:border-box;background:#222;color:#eee;border:1px solid #666;padding:8px}.error{color:#ffb4a8}p{line-height:1.6}</style><body><header><h1>随心调色 · 视觉验收</h1><span id="count">尚未评分</span><button onclick="download()">下载评分</button></header><main><p>请对照前后图，检查调色方向、受影响的区域和用户话术。没有结果的条目保持未评分。评分仅保存在本浏览器，完成后下载评分文件。</p>''' + ''.join(cards) + '''</main><script>const cards=[...document.querySelectorAll('article')];function values(){return cards.map(c=>({id:c.dataset.id,grade:c.querySelector('input:checked').value,note:c.querySelector('textarea').value}))}function update(){let v=values();document.querySelector('#count').textContent='已评分 '+v.filter(x=>x.grade!=='pending').length+' / '+v.length+' · 通过 '+v.filter(x=>x.grade==='pass').length;localStorage.setItem('suitone-visual-review-'+location.pathname,JSON.stringify(v))}let saved=JSON.parse(localStorage.getItem('suitone-visual-review-'+location.pathname)||'[]');for(const x of saved){let c=cards.find(c=>c.dataset.id===x.id);if(!c)continue;let r=c.querySelector('input[value="'+x.grade+'"]');if(r)r.checked=true;c.querySelector('textarea').value=x.note}document.addEventListener('change',update);document.addEventListener('input',update);function download(){const a=document.createElement('a');a.href=URL.createObjectURL(new Blob([JSON.stringify({source:'manual',cases:values()},null,2)],{type:'application/json'}));a.download='视觉验收评分.json';a.click();URL.revokeObjectURL(a.href)}update()</script></body></html>'''
output=root/'review.html'
output.write_text(html,encoding='utf-8')
print(output)
