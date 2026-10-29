"""生成补充样片的人工视觉验收页，不修改原始报告或评分。"""
from html import escape
import json
from pathlib import Path
import sys

path=Path(sys.argv[1]).resolve(strict=True);report=json.loads(path.read_text());cards=[]
names={'portrait':'彩色人像','food':'美食','night':'夜间街景','interior':'室内',
       'haze':'远山灰霾','fog':'雾中秋景','backlit-person':'窗边逆光人物',
       '05':'05 · 夜景暗部','07':'07 · 蓝色电影夜景','10':'10 · 山体提亮',
       '11':'11 · 山景通透','13':'13 · 逆光人物','14':'14 · 日出暖调'}
for row in report['cases']:
    key=row['id'];before=path.parent/(key+'-before.png');after=path.parent/(key+'-after.png')
    if not (before.exists() and after.exists()):continue
    notes=[note for change in row['initial'].get('changes',[]) for note in change.get('notes',[])]
    if row.get('quality',{}).get('denoise'):notes.append('开启降噪')
    if row.get('rendered_with_new_engine'):notes.append('使用本地更新后的引擎重新渲染原有 AI 参数；未重新请求 AI')
    if not row.get('review_skipped') and (row.get('review') or {}).get('state')=='done':
        notes += ['复看：'+note for change in row['review'].get('changes',[]) for note in change.get('notes',[])]
    if row.get('review_skipped'):notes.append(row['review_skipped'])
    cards.append(f'''<article data-id="{escape(key)}"><h2>{names.get(key,key)}</h2>
    <p><strong>要求：</strong>{escape(row['prompt'])}</p><p><strong>AI 首轮回复：</strong>{escape(row['initial'].get('reply',''))}</p>
    <p><strong>实际调整：</strong>{escape('；'.join(notes) or '无参数变动')}</p>
    <p><strong>复看：</strong>{escape((row.get('review') or {}).get('reply') or (row.get('review') or {}).get('error') or '未完成')}</p>
    <div class="pair"><figure><img src="{escape(before.name)}"><figcaption>调整前</figcaption></figure><figure><img src="{escape(after.name)}"><figcaption>调整后</figcaption></figure></div>
    <div class="grade"><label><input type="radio" name="g{escape(key)}" value="pass">符合要求</label><label><input type="radio" name="g{escape(key)}" value="fail">不符合要求</label><label><input type="radio" name="g{escape(key)}" value="pending" checked>尚未评分</label></div><textarea placeholder="可填写原因（选填）"></textarea></article>''')
page='''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>随心调色 · 补充案例</title><style>body{background:#202020;color:#eee;font:15px -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;margin:0}header{position:sticky;top:0;background:#282828ee;padding:16px 5%;z-index:2;display:flex;align-items:center;gap:20px}header h1{font-size:19px;margin:0;margin-right:auto}button{padding:8px 16px;border:0;border-radius:7px}main{max-width:1200px;margin:auto;padding:20px}article{background:#2e2e2e;padding:18px;margin:18px 0;border-radius:10px}h2{font-size:16px}.pair{display:flex;gap:12px}figure{flex:1;margin:0;min-width:0}img{width:100%;object-fit:contain;background:#111}figcaption{font-size:12px;color:#aaa}.grade{display:flex;gap:20px;margin:18px 0}textarea{width:100%;height:55px;box-sizing:border-box;background:#222;color:#eee;border:1px solid #666;padding:8px}p{line-height:1.6}</style><body><header><h1>随心调色 · 补充案例</h1><span id="count"></span><button onclick="download()">下载评分</button></header><main><p>请检查调整是否看得出来、是否符合要求，以及肤色和细节。评分保存在当前浏览器，请下载评分文件。</p>'''+''.join(cards)+'''</main><script>const cards=[...document.querySelectorAll('article')];function values(){return cards.map(c=>({id:c.dataset.id,grade:c.querySelector('input:checked').value,note:c.querySelector('textarea').value}))}function update(){let v=values();document.querySelector('#count').textContent='已评分 '+v.filter(x=>x.grade!=='pending').length+' / '+v.length;localStorage.setItem('suitone-expanded-review-'+location.pathname,JSON.stringify(v))}let saved=JSON.parse(localStorage.getItem('suitone-expanded-review-'+location.pathname)||'[]');for(const x of saved){let c=cards.find(c=>c.dataset.id===x.id);if(!c)continue;let r=c.querySelector('input[value="'+x.grade+'"]');if(r)r.checked=true;c.querySelector('textarea').value=x.note}document.addEventListener('change',update);document.addEventListener('input',update);function download(){const a=document.createElement('a');a.href=URL.createObjectURL(new Blob([JSON.stringify({source:'manual',cases:values()},null,2)],{type:'application/json'}));a.download='补充案例评分.json';a.click();URL.revokeObjectURL(a.href)}update()</script></body></html>'''
if path.parent.name.startswith('retested-visual-'):
    page=page.replace('补充案例','六条重测案例')
elif path.parent.name.startswith('highlight-rerender-review-'):
    page=page.replace('补充案例','高光修复重渲染')
elif path.parent.name.startswith('backlit-review-retry-'):
    page=page.replace('补充案例','逆光人像复看')
out=path.parent/'review.html';out.write_text(page,encoding='utf-8');print(out)
