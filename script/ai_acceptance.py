"""真实 CLI 行为验收：只发送公开样本的数值摘要，不发送照片，不改 App 会话。"""
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
from datetime import datetime
import json
from pathlib import Path
import sys
from time import monotonic, sleep

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'engine'))
from assistant import AssistantBridge
from service import Engine
from smart import neutral


def run_provider(provider, engine, targets):
    bridge = AssistantBridge(engine)
    checks = []

    def run(name, message, items, verify, history=None, cancel=False, context=None):
        original = deepcopy(items)
        start = monotonic()
        request = dict(provider=provider, message=message, targets=deepcopy(items), history=history or [])
        request.update(context or {})
        job_id = bridge.start(request)['id']
        cancellation_sent = False
        while True:
            job = bridge.status(job_id)
            if cancel and job['state'] == 'thinking' and not cancellation_sent:
                bridge.cancel(job_id)
                cancellation_sent = True
            if job['state'] in ['done', 'error', 'cancelled']:
                break
            if monotonic() - start > 260:
                bridge.cancel(job_id)
                job = dict(state='error', error='验收等待超时')
                break
            sleep(.1)
        errors = []
        try:
            assert items == original, '请求修改了传入的照片记录'
            if cancel:
                assert cancellation_sent and job['state'] == 'cancelled', '取消没有在应用结果前生效'
            else:
                assert job['state'] == 'done', job.get('error', job['state'])
                verify(job)
        except AssertionError as exc:
            errors.append(str(exc))
        check = dict(name=name, passed=not errors, seconds=monotonic()-start, errors=errors, result=job)
        checks.append(check)
        print(provider, name, 'PASS' if check['passed'] else 'FAIL', flush=True)
        return job

    def no_changes(job):
        assert job['changes'] == [], '咨询或不支持的要求产生了照片修改'

    def exposure_only(items, amount):
        def verify(job):
            assert len(job['changes']) == len(items), '没有覆盖准确的目标数量'
            changes = {change['id']: change['params'] for change in job['changes']}
            for item in items:
                actual = changes[item['id']]
                expected = deepcopy(item['params'])
                expected['exposure'] += amount
                assert abs(actual['exposure']-expected['exposure']) < .00001, '曝光数值不符合请求'
                actual = {k:v for k,v in actual.items() if k != 'exposure'}
                expected = {k:v for k,v in expected.items() if k != 'exposure'}
                assert actual == expected, '只要求曝光却改了其他参数'
        return verify

    def requested_operation(kind, value):
        def verify(job):
            assert len(job['changes']) == 1, '没有返回当前照片的操作'
            ops = job['changes'][0].get('operations', [])
            assert any(op['kind'] == kind and op['value'] == value for op in ops), '没有返回请求的操作'
            assert job['changes'][0]['params'] == one[0]['params'], '仅请求工具操作时改变了调色参数'
        return verify

    one = deepcopy(targets[:1])
    run('consultation', '只讨论调色建议，不要修改照片。请用一句话说明自然微调方向。', one, no_changes)
    first = run('single_exact', '只将当前照片曝光提高 0.15 EV，其他参数完全保持不变。直接调整。', one, exposure_only(one, .15))
    run('batch_exact', '把当前 targets 的两张照片各自曝光提高 0.10 EV，其他参数完全保持不变。直接调整两张。', deepcopy(targets), exposure_only(targets, .1))
    if first['state'] == 'done' and len(first.get('changes', [])) == 1:
        followup = [dict(id=one[0]['id'], params=first['changes'][0]['params'])]
        history = [dict(role='user', text='只把当前照片曝光提高 0.15 EV。'), dict(role='assistant', text=first['reply'])]
        run('followup_relative', '在刚才基础上再降低曝光 0.05 EV，其他不动。直接调整。', followup, exposure_only(followup, -.05), history)
    else:
        checks.append(dict(name='followup_relative', passed=False, errors=['前置精确调整失败，未测试后续上下文']))
    run('unsupported_repair', '请现在自动去掉画面右侧的人。没有框选，我不想先框选。', one, no_changes)
    run('denoise', '只打开当前照片的降噪，其他参数保持不变，直接处理。', one, requested_operation('denoise', 1))
    run('upscale', '只将当前照片放大到 2 倍，其他不变，直接处理。', one, requested_operation('upscale', 2))
    run('reference_match', '请用已添加的参考图匹配当前照片的颜色，其他不动。', one,
        requested_operation('match', 0), context=dict(reference_ids=[targets[1]['id']]))
    run('repair_selection', '请修复我已框选的区域，其他不动。', one,
        requested_operation('repair', 0), context=dict(repair_selection=dict(id=one[0]['id'],box=[.2,.2,.4,.4])))
    run('undo', '撤销上一步调整，不做其他修改。', one, requested_operation('undo', 0),
        context=dict(undo_available=True))
    run('cancel', '请认真考虑几种电影调色方案并给出详细分析，但暂时不要修改照片。', one, no_changes, cancel=True)
    return dict(provider=provider, passed=all(check['passed'] for check in checks), checks=checks)


def main():
    folder = ROOT / 'output' / ('ai-review-' + datetime.now().astimezone().strftime('%Y%m%d-%H%M%S'))
    folder.mkdir(parents=True)
    engine = Engine(ROOT)
    names = ['Chateau Frontenac illuminated at night in Quebec City.jpg', 'Portrait Christian Bolt.jpg']
    targets = []
    for index, name in enumerate(names):
        asset = engine.import_one(ROOT / 'tmp/ui-review-input' / name)
        engine.analysis(asset.id)
        params = neutral(); params['exposure'] = .2 + index*.15
        targets.append(dict(id=asset.id, params=params))
    providers = engine.assistant.providers()
    available = [p['id'] for p in providers if p['available'] and p['id'] in ('codex', 'claude')]
    report = dict(status='running', image_pixels_sent=False, providers=providers, results=[])
    path = folder / 'results.json'
    path.write_text(json.dumps(report, ensure_ascii=False, indent=2))
    with ThreadPoolExecutor(max_workers=2) as executor:
        futures = [(p, executor.submit(run_provider, p, engine, targets)) for p in available]
        for provider, future in futures:
            try: report['results'].append(future.result())
            except Exception as exc: report['results'].append(dict(provider=provider, passed=False, error=type(exc).__name__))
            path.write_text(json.dumps(report, ensure_ascii=False, indent=2))
    report['status'] = 'passed' if len(available) == 2 and all(p['passed'] for p in report['results']) else 'incomplete_or_failed'
    path.write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print('验收报告', path, report['status'], flush=True)
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
