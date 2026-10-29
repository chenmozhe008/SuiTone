"""后台选择建议卡片；运行在独立任务中，不占用对话的任务槽。"""
from copy import deepcopy
import json
from threading import RLock

from assistant import AssistantBridge
from recommendations import candidates, select


class RecommendationBridge:
    def __init__(self, engine, bridge=None):
        self.engine=engine
        self.bridge=bridge or AssistantBridge(engine)
        self.jobs={}
        self.lock=RLock()

    def start(self, data):
        targets=data.get('targets')
        if not isinstance(targets,list) or len(targets)!=1:
            raise ValueError('智能建议仅分析当前照片')
        target=targets[0]
        context,_=self.engine.analysis(target['id'])
        pool=candidates(context)
        # 模型只选现有 ID，参数和实际可用区域均由本地引擎负责。
        choices=[{'id':card['id'],'title':card['title']} for card in pool]
        message=('请依据当前画面，从候选中选择最适合的 3 到 5 个不同建议，兼顾自然调整与风格。'
                 '不要执行照片操作；selection 必须是 none，actions 必须为空。'
                 'reply 必须只包含 JSON 对象，格式为 {"cards":["候选ID",...]}。候选：'
                 +json.dumps(choices,ensure_ascii=False))
        request={key:deepcopy(value) for key,value in data.items()
                 if key in ('provider','api_key','targets','image_consent')}
        request.update(message=message,history=[],reference_ids=[],undo_available=False)
        started=self.bridge.start(request)
        with self.lock:
            self.jobs[started['id']]=pool
            while len(self.jobs)>16:self.jobs.pop(next(iter(self.jobs)))
        return started

    def status(self, key):
        with self.lock:pool=deepcopy(self.jobs.get(key))
        if pool is None:return dict(state='error',error='建议任务不存在')
        result=self.bridge.status(key)
        if result.get('state')!='done':return result
        try:
            if result.get('changes') or result.get('selection')!='none':raise ValueError('建议不能修改照片')
            cards=select(json.loads(result['reply']),pool)
        except (KeyError,TypeError,ValueError):
            return dict(state='error',error='智能建议未返回有效结果，可继续使用本地建议')
        return dict(state='done',cards=cards)

    def cancel(self, key):
        return self.bridge.cancel(key)
