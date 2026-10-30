"""通过已安装的 Claude Code / Codex 返回可校验的调整计划。"""
from copy import deepcopy
import json
import os
from pathlib import Path
import shutil
import subprocess
from tempfile import TemporaryDirectory,TemporaryFile
from threading import Event,RLock,Thread
from time import monotonic
from uuid import uuid4
import math
import re
import base64
from hashlib import sha256
from smart import STYLES

PARAMETERS=['exposure','contrast','saturation','temperature','tint','highlights','shadows',
            'black_white','dehaze_amt','effect_strength','skin_protect','smooth','bright',
            'match_strength','sky_hue','autumn','water_var',
            'water_enabled','sky_enabled','land_enabled','portrait_enabled']
PARAMETERS += ['shadow_hue','shadow_chroma','highlight_hue','highlight_chroma','fade']
PARAMETERS += [r+'_'+c for r in ['water','sky','land','person'] for c in ['l','a','b']]
PARAMETERS += ['whites','blacks','light','vibrance','texture']
PARAMETERS += ['local_'+r+'_'+f for r in ['water','sky','land','person']
               for f in ['exposure','contrast','highlights','temperature','saturation','hue','feather']]
PARAMETERS += ['local_selected_'+f for f in ['exposure','contrast','highlights','temperature','saturation','hue','feather']]
SCHEMA=dict(type='object',additionalProperties=False,required=['reply','selection','actions'],properties=dict(
    reply=dict(type='string'),selection=dict(type='string',enum=['none','water','sky','land','person','skin']),
    actions=dict(type='array',items=dict(type='object',additionalProperties=False,required=['id','preset','adjustments','operations'],properties=dict(
        id=dict(type='string'),preset=dict(type='string',enum=['keep']+[style['id'] for style in STYLES]),
        operations=dict(type='array',items=dict(type='object',additionalProperties=False,required=['kind','value'],properties=dict(
            kind=dict(type='string',enum=['denoise','upscale','repair','match','undo']),value=dict(type='number')))),
        adjustments=dict(type='array',items=dict(type='object',additionalProperties=False,
            required=['parameter','mode','value'],properties=dict(parameter=dict(type='string',enum=PARAMETERS),
            mode=dict(type='string',enum=['set','add','multiply']),value=dict(type='number')))))))))

SYSTEM='''你是随心调色 SuiTone 的修图助手。理解用户任意自然语言，延续对话，给出可执行的本地修图参数或审美建议。
你拿到的是本地分析摘要和当前参数，没有看到照片本身，不得声称看过细节或把统计推断当成事实。
只能输出规定的 JSON；不执行工具、命令、不读取文件、不联网。不要编程、修改 App 或其他项目。
编辑输出可回退的参数方案。当前版本尚不支持裁切或比例导出，也不能覆盖原文件；导出会另存为新文件。
用户只讨论、询问或要求建议时 actions=[]。
仅当用户要求修图时填写 actions，且 id 只能来自当前 targets。整批请求要覆盖 targets 各张，考虑每张自身曝光。
默认温和调整，保留现场光感和肤色。自然不是固定成某种水色；暖调、电影感、复古等根据诉求用通用风格起步再调整。
用户明确要求明显的电影感、胶片感或其他创作风格时，应让变化在整张预览中清晰可见，而不是只做难以察觉的微调。
使用创作风格预设时，以预设参数作为风格基础，除非画面或用户要求需要，不要把构成风格的染色、对比、褪色等参数大幅削弱；整体强度通常保持 1。
如果用户要求轻微、自然或保留特定区域，则按要求克制调整，不夸大效果；暗部无法恢复的细节要如实说明。
“稍微”约束风格力度，不等于变化可以难以察觉；应根据照片中目标区域的实际问题，调整到前后预览可辨认，同时避免破坏雾气、边缘和亮部渐变。
用户明确要求变化能看出来时，自然与可见须同时满足：重点区域要有可辨认的改善，同时保留色彩、质感和高光细节。
preset=keep 保留现有设置；其余 preset 见文末风格清单（自然＝微调求真，出片＝明显风格并带质感）。
shadow_hue/highlight_hue[-180,180]、shadow_chroma/highlight_chroma[0,30] 可分离阴影高光染色，fade[0,1]褪黑。
adjustments 为 set/add/multiply 数值操作：exposure[-3,3]EV、contrast[0,2]、saturation[0,2]、
temperature[-1,1]正暖负冷、tint[-1,1]正洋红负绿、highlights/shadows[-1,1]、black_white[0,1]、
dehaze_amt[0,1]、effect_strength[0,1]、match_strength[0,1]、smooth/bright[0,1]。
light[-1,1] 光线总滑块（只推中间调）、vibrance[-1,1] 颜色总滑块（优先补淡色）、texture[0,1] 质感（暗角＋柔光＋颗粒，出片感）、
whites/blacks[-1,1] 白色和黑色。局部调整用 local_<区域>_<项>，区域为 water/sky/land/person，项为 exposure/contrast/highlights/temperature/saturation[-1,1]、hue[-180,180]、feather[0,1]（羽化），只在该区域生效，适合“天空太灰”“人脸偏暗”这类要求，优先于 _l/_a/_b 区域目标色。
contrast 是引擎对比增强的强度，0 为无调整；小数值如 0.08 往往非常轻，不能把它误当成常规照片软件里 8% 的可见对比提升。根据画面需求选择力度，不要为了明显而牺牲高光或制造色阶断层。
skin_protect 和 *_enabled 用 set 0/1。water/sky/land/person 的 _l/_a/_b 是对应区域 Lab 目标，可用 add 微调现有区域，
只在确实存在可靠区域时使用。L[0,100]、a/b[-100,100]，a负绿正红，b负蓝正黄。
要查看选区时 selection 取对应名称，否则 none。曝光/对比/色温/高光/阴影等全局调整适用于任何场景。
operations 是按顺序执行的额外操作：denoise 的 value 为 1 开启或 0 关闭；upscale 的 value 为 1、2、4；
repair 和 match 的 value 都为 0。修复只能在目标有用户提供的 repair_selection 时使用，不能猜选区；
参考匹配只有 reference_count 大于 0 时使用。使用参考图前先对比参考图和目标照片的场景、光线方向、时段和主体；差别很大（如夜景配白天、逆光配顺光、室内配风光）时要在 reply 里直说哪里不合适、效果可能生硬，建议换参考或只学部分区域，并且不要执行 match。差别不大时可以执行 match，引擎会按差异自动定强度。没有可用选区或参考图时说明如何操作，不填该操作。
undo 的 value 为 0，只能在 undo_available 为 true 时单独使用，preset=keep、adjustments=[]，不能和其他操作混用。
每张照片可先使用 preset 与 adjustments，再依序执行 operations；无需额外操作时 operations=[]。
修复工具支持画笔、套索、点选物体和方框；点选无法用于大片背景。没有选区时可建议用户先用这些工具选择，但不能替用户猜测选区。用户可在调整面板保存个人风格，对话不能直接执行保存；液化、美妆和生成内容尚未支持，要如实解释，不返回假操作。
用户指定的框选、画笔、套索或点选区域可通过 local_selected_exposure/contrast/highlights/temperature/saturation/hue/feather 调整，只有 repair_selection 对应的照片可使用；只要求调整选区时不要改全局参数。用户明确要求对整个画面调整时可使用全局参数。
用户提到画面中的人物或其他具体对象时，先核对已有信息：有预览图且对象明显不存在时，说明没有看到，别指示用户框选不存在的对象；
看不到照片、对象过小或无法确定时，说明无法确认并请用户指出位置，不把用户描述当作已经验证的画面事实。
视觉上若用户对当前画面颜色、明暗或主体的事实判断与预览明显不一致，要礼貌指出所见及不确定性；若方向因此不明确，先问用户想变暖还是变冷等具体问题，actions=[]。如果用户明确指定了创作方向，即使原片本来偏暖或偏冷也可按指定方向调整，不要擅自反转。
不要把中间色或微弱变化描述成饱和的具体色彩，也不要在目标方向、区域或变化幅度没有把握时说已经符合要求。
reply 用中文描述建议，不要提前宣称已完成；缺关键审美方向时可以问一个具体问题，actions 留空。'''


STYLE_GUIDE='风格清单：\n'+'\n'.join(
    f"{style['id']}｜{style['title']}｜{'自然' if style['family']=='natural' else '出片'}｜{style['detail']}" for style in STYLES)
SYSTEM+='\n'+STYLE_GUIDE


class CLIRequestError(ValueError):
    def __init__(self,message,retryable=False):
        super().__init__(message);self.retryable=retryable


def cli_failure(provider,output):
    """只返回固定诊断，避免把 CLI 日志中的凭证、路径或用户输入暴露到界面。"""
    name='Codex' if provider=='codex' else 'Claude Code'
    text=output.lower()
    if any(word in text for word in ['usage limit','rate limit','rate_limit','quota','insufficient_quota','429','too many requests','credit balance','billing']):
        return CLIRequestError(name+' 额度已用完或调用太频繁，请稍后再试，或在上方换一个对话引擎')
    if any(word in text for word in ['unauthorized','not logged in','please log in','please login','invalid api key','token expired','refresh token','401']):
        return CLIRequestError(name+' 登录已失效，请在该 CLI 中重新登录后重试')
    if any(word in text for word in ['unexpected argument','unrecognized option','unsupported model','model_not_found']):
        return CLIRequestError(name+' 的版本或模型配置不兼容，请切换对话引擎并检查 CLI 配置')
    if any(word in text for word in ['stream disconnected','connection reset','connection refused','network error','timed out','error sending request','502 bad gateway','503 service unavailable']):
        return CLIRequestError(name+' 连接暂时中断，请重试或切换对话引擎',retryable=True)
    return CLIRequestError(name+' 未完成此次请求，可重试或切换对话引擎；本地调整未改变')


# CLI 运行中一出现这些字样就停下报错：没额度、限流、未登录时 CLI 往往会反复重试而不退出。
# 只认文字，不认 429/401 这类裸数字（提示词里的数值可能撞上）。
FATAL_SIGNS=['usage limit','quota','insufficient_quota','rate limit','rate_limit','too many requests',
             'unauthorized','not logged in','please log in','please login','invalid api key','token expired',
             'credit balance','billing']


def early_failure(provider,output):
    text=output.lower()
    return cli_failure(provider,text) if any(sign in text for sign in FATAL_SIGNS) else None


def executable(provider):
    candidates={
        'codex':[shutil.which('codex'),'/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex',
                 str(Path.home()/'.local/bin/codex'),'/opt/homebrew/bin/codex','/usr/local/bin/codex'],
        'claude':[shutil.which('claude'),str(Path.home()/'.local/bin/claude'),'/usr/local/bin/claude','/opt/homebrew/bin/claude'],
    }
    return next((p for p in candidates.get(provider,[]) if p and os.path.isfile(p) and os.access(p,os.X_OK)),None)


def parse_output(provider,text,last_message=None,stream=False):
    if provider=='codex':return json.loads(last_message or text)
    if stream:
        events=[json.loads(line) for line in text.splitlines() if line.strip()]
        envelope=next((event for event in reversed(events) if event.get('type')=='result'),None)
        if envelope is None:raise ValueError('Claude Code 未返回最终结果')
    else:envelope=json.loads(text)
    if envelope.get('is_error'):raise ValueError('Claude Code 未完成请求，请检查其登录状态或可用额度')
    structured=envelope.get('structured_output')
    if isinstance(structured,dict):return structured
    result=envelope.get('result','').strip()
    if result.startswith('```'):result=result.split('\n',1)[1].rsplit('```',1)[0]
    return json.loads(result)


def safe_advice(reply):
    """拦截已知的不存在的导出操作指引。"""
    if '覆盖原' in reply:
        return ('当前版本不能覆盖原文件，导出会保存为新文件。'
                + ('目前也不支持裁切或比例导出。' if any(word in reply for word in ('裁切','裁剪','比例','3:4')) else ''))
    if re.search(r'(导出|保存).{0,36}(裁切|裁剪|比例)|(裁切|裁剪|比例).{0,36}(导出|保存)',reply,re.S):
        return '当前版本尚不支持裁切或比例导出；可以导出为新文件后再用其他工具处理。'
    return reply


def validate_plan(plan,targets,engine,available_context=None):
    from service import parameters
    from smart import suggest,apply_operations
    if not isinstance(plan,dict) or not isinstance(plan.get('reply'),str) or len(plan['reply'])>12000:
        raise ValueError('AI 回复格式不正确，设置未改变')
    if plan.get('selection') not in SCHEMA['properties']['selection']['enum']:
        raise ValueError('AI 选区名称无效，设置未改变')
    actions=plan.get('actions')
    if not isinstance(actions,list) or len(actions)>len(targets):raise ValueError('AI 调整范围无效，设置未改变')
    available={t['id']:t for t in targets};seen=set();changes=[]
    available_context=available_context or {}
    for action in actions:
        key=action['id']
        if key not in available or key in seen:raise ValueError('AI 请求了当前范围外的照片，设置未改变')
        seen.add(key);context,_=engine.analysis(key)
        preset=action['preset']
        if preset not in SCHEMA['properties']['actions']['items']['properties']['preset']['enum']:
            raise ValueError('AI 风格无效，设置未改变')
        if available_context.get('review_only') and (preset!='keep' or action.get('operations')):
            raise ValueError('复看仅支持微调参数，不能应用风格或其他操作')
        p=parameters(available[key]['params']) if preset=='keep' else suggest(context,preset)['params']
        selected=available_context.get('repair_selection')
        if selected and selected['id']==key:
            shape={k:deepcopy(v) for k,v in selected.items() if k in ('box','strokes','radius','polygon','point')}
            digest=sha256(json.dumps(shape,sort_keys=True,separators=(',',':')).encode()).hexdigest()[:12]
            selected=('selection-'+digest,shape)
        else:selected=None
        p,notes=apply_operations(p,action['adjustments'],context,selected=selected)
        if preset!='keep':notes.insert(0,'应用自适应风格：'+preset)
        operations=action.get('operations',[])
        if not isinstance(operations,list) or len(operations)>4:raise ValueError('AI 操作数量无效')
        for op in operations:
            if not isinstance(op,dict) or set(op)!={'kind','value'}:raise ValueError('AI 操作格式无效')
            kind,value=op['kind'],op['value']
            if not isinstance(value,(int,float)) or isinstance(value,bool) or not math.isfinite(value):raise ValueError('AI 操作数值无效')
            if kind=='denoise' and value in [0,1]:continue
            if kind=='upscale' and value in [1,2,4]:continue
            if kind=='repair' and value==0 and (available_context.get('repair_selection') or {}).get('id')==key:continue
            if kind=='match' and value==0 and available_context.get('reference_ids'):continue
            if kind=='undo' and value==0 and available_context.get('undo_available') is True and len(actions)==1 and len(operations)==1 and preset=='keep' and not action['adjustments']:continue
            raise ValueError('AI 请求的操作不可用或缺少选区、参考图')
        changes.append(dict(id=key,params=p,notes=notes,operations=operations))
    return dict(reply=safe_advice(plan['reply']) if not changes else plan['reply'],selection=plan['selection'],changes=changes)


class AssistantBridge:
    def __init__(self,engine):
        self.engine=engine;self.jobs={};self.events={};self.lock=RLock()

    def providers(self):
        from api_providers import public_catalog
        result=[dict(id=p,title=t,kind='account',available=bool(executable(p))) for p,t in [('codex','Codex'),('claude','Claude Code')]]
        result+=[dict(item,kind='api',available=True) for item in public_catalog()]
        return result

    def start(self,data):
        from service import parameters,repair_input,quality_settings
        if data.get('provider') in ['codex','claude']:
            if not executable(data['provider']):raise ValueError('找不到这个 CLI，请先在本机安装并登录')
        else:
            from api_providers import resolve
            resolve(data)
        if not isinstance(data.get('image_consent',False),bool):raise ValueError('图片发送开关无效')
        if not isinstance(data.get('message'),str) or not 0<len(data['message'].strip())<=8000:
            raise ValueError('请输入要讨论或调整的内容')
        targets=data.get('targets')
        if not isinstance(targets,list) or not 0<len(targets)<=100:raise ValueError('请选择 1–100 张照片')
        if len({t['id'] for t in targets})!=len(targets):raise ValueError('目标照片重复')
        for item in targets:
            self.engine.asset(item['id']);item['params']=parameters(item['params'])
            item['quality']=quality_settings(item.get('quality'))
        reference_ids=data.get('reference_ids',[])
        if not isinstance(reference_ids,list) or len(reference_ids)>10 or not all(isinstance(x,str) for x in reference_ids):
            raise ValueError('参考图列表无效')
        for reference_id in reference_ids:self.engine.asset(reference_id)
        if not isinstance(data.get('undo_available',False),bool):raise ValueError('撤销状态无效')
        if not isinstance(data.get('review_only',False),bool):raise ValueError('复看状态无效')
        before=data.get('review_before',[])
        if not isinstance(before,list) or len(before)>len(targets) or (before and not data.get('review_only',False)):
            raise ValueError('复看前的照片状态无效')
        target_ids={item['id'] for item in targets};seen=set()
        for item in before:
            if not isinstance(item,dict) or item.get('id') not in target_ids or item['id'] in seen or not isinstance(item.get('source_id'),str):
                raise ValueError('复看前的照片不属于当前范围')
            seen.add(item['id']);self.engine.asset(item['source_id'])
            item['params']=parameters(item['params']);item['quality']=quality_settings(item.get('quality'))
        selected=data.get('repair_selection')
        if selected is not None:
            if not isinstance(selected,dict) or set(selected)-{'id','box','strokes','radius','polygon','point'} or 'box' not in selected or selected.get('id') not in {t['id'] for t in targets}:
                raise ValueError('修复选区不属于当前范围')
            repair_input(selected['box'])
            from service import shape_input
            shape_input(selected.get('strokes'),selected.get('radius'),selected.get('polygon'),selected.get('point'))
        history=data.get('history',[])
        if not isinstance(history,list) or len(history)>16:raise ValueError('对话上下文过长')
        for item in history:
            if item.get('role') not in ['user','assistant'] or not isinstance(item.get('text'),str) or len(item['text'])>12000:
                raise ValueError('对话上下文格式不正确')
        with self.lock:
            if any(j['state'] in ['preparing','thinking'] for j in self.jobs.values()):raise ValueError('请等当前对话完成，或先取消')
            key=uuid4().hex;self.jobs[key]=dict(state='preparing');self.events[key]=Event()
            completed=[k for k,v in self.jobs.items() if v['state'] in ['done','error','cancelled']]
            for old in completed[:-15]:self.jobs.pop(old);self.events.pop(old,None)
        Thread(target=self._run,args=(key,deepcopy(data)),daemon=True).start()
        return dict(id=key)

    def status(self,key):
        with self.lock:return deepcopy(self.jobs.get(key,dict(state='error',error='对话任务不存在')))

    def cancel(self,key):
        with self.lock:
            if key in self.events:self.events[key].set()
        return dict(cancelled=True)

    def _run(self,key,data):
        event=self.events[key]
        try:
            from smart import describe
            targets=[]
            for item in data['targets']:
                if event.is_set():raise InterruptedError()
                with self.engine.lock:
                    analysis,_=self.engine.analysis(item['id'])
                    targets.append(dict(id=item['id'],analysis=describe(analysis),params=item['params'],quality=item.get('quality',{})))
            selected=data.get('repair_selection')
            context=dict(targets=targets,conversation=data.get('history',[]),request=data['message'],
                         reference_count=len(data.get('reference_ids',[])),
                         repair_selection={'id':selected['id']} if selected else None,
                         undo_available=data.get('undo_available',False),review_only=data.get('review_only',False))
            images=[]
            if data.get('image_consent',False):
                from vision import prepare_images
                with self.engine.lock:images=prepare_images(self.engine,data,event)
                context['images']=[image['label'] for image in images]
                system=SYSTEM.replace('你拿到的是本地分析摘要和当前参数，没有看到照片本身，不得声称看过细节或把统计推断当成事实。',
                    '你能看到按顺序附带的预览图，图像标签在 images 列表中；只能依据可见内容和本地分析判断。')
            else:system=SYSTEM
            if data.get('review_only'):
                system+='\n这是唯一一次结果复看：比较调整前后对应区域的色相、亮度和变化幅度，判断实际方向是否符合用户指定；不能仅凭参数或首轮描述认定成功。方向不符、变化不足或有不确定性时要明确说明，不要夸大效果；仅在明显需要修正时微调参数，preset 必须为 keep，operations 必须为空。若确实符合要求，actions=[]。'
                if images and data.get('review_before'):
                    system+='\n每张对照图左侧为调整前、右侧为调整后。比较用户要求的重点区域和整体变化，不要仅因右图本身好看就判定完成；要求变化可见时若两侧差别难以辨认，应在允许范围内适度加强已有调整，同时保留自然细节。'
            prompt=system+'\n'+json.dumps(context,ensure_ascii=False)
            if event.is_set():raise InterruptedError()
            with self.lock:self.jobs[key]=dict(state='thinking')
            if data['provider'] not in ['codex','claude']:
                from api_providers import invoke
                result=invoke(data,prompt,SCHEMA,images,cancel=event)
            else:
                result=(self._invoke(data['provider'],prompt,event,images) if images
                        else self._invoke(data['provider'],prompt,event))
            if event.is_set():raise InterruptedError()
            with self.engine.lock:result=validate_plan(result,data['targets'],self.engine,data)
            with self.lock:
                if event.is_set():raise InterruptedError()
                self.jobs[key]=dict(state='done',**result)
        except InterruptedError:
            with self.lock:self.jobs[key]=dict(state='cancelled')
        except Exception as exc:
            message=str(exc) if isinstance(exc,ValueError) else '对话未完成，请检查 CLI 登录、网络或额度后重试'
            with self.lock:self.jobs[key]=dict(state='error',error=message)

    def _invoke(self,provider,prompt,cancel,images=None):
        deadline=monotonic()+240
        for attempt in range(2):
            try:
                if images:return self._invoke_once(provider,prompt,cancel,deadline,images)
                return self._invoke_once(provider,prompt,cancel,deadline)
            except CLIRequestError as exc:
                if not exc.retryable or attempt==1:raise
                if cancel.wait(.6):raise InterruptedError()

    def _invoke_once(self,provider,prompt,cancel,deadline,images=None):
        # 空工作目录；不读取项目的提示文件或在原照片目录启动代理。
        with TemporaryDirectory(prefix='assistant-',dir=self.engine.folder) as folder:
            root=Path(folder);schema=root/'schema.json';schema.write_text(json.dumps(SCHEMA))
            output=root/'response.json'
            if provider=='codex':
                command=[executable(provider),'exec','--sandbox','read-only','--ephemeral','--skip-git-repo-check',
                         '--ignore-user-config','--disable','shell_tool','--disable','unified_exec',
                         '--disable','apps','--disable','browser_use','--disable','browser_use_external',
                         '--disable','browser_use_full_cdp_access','--color','never','--output-schema',str(schema),
                         '--output-last-message',str(output),'-']
                for index,image in enumerate(images or []):
                    attachment=root/('image-'+str(index)+'.jpg')
                    attachment.write_bytes(image['data'])
                    command.extend(['--image',str(attachment)])
            else:
                command=[executable(provider),'-p','--output-format','stream-json' if images else 'json','--json-schema',json.dumps(SCHEMA),
                         '--tools','','--strict-mcp-config','--mcp-config','{"mcpServers":{}}',
                         '--settings','{"disableAllHooks":true}','--disable-slash-commands',
                         '--no-session-persistence','--permission-mode','plan']
                if images:command.extend(['--input-format','stream-json','--verbose'])
            environment=os.environ.copy()
            environment.pop('CLAUDECODE',None)
            # 凭证只交给既有 CLI，不落入日志、提示或返回值。
            with TemporaryFile() as stdout,TemporaryFile() as stderr:
                if cancel.is_set():raise InterruptedError()
                child=subprocess.Popen(command,cwd=root,env=environment,stdin=subprocess.PIPE,stdout=stdout,stderr=stderr)
                try:
                    if provider=='claude' and images:
                        content=[dict(type='text',text=prompt)]
                        for image in images:
                            content.append(dict(type='text',text=image['label']))
                            content.append(dict(type='image',source=dict(type='base64',media_type='image/jpeg',
                                                data=base64.b64encode(image['data']).decode('ascii'))))
                        message=dict(type='user',message=dict(role='user',content=content),parent_tool_use_id=None,session_id=None)
                        payload=(json.dumps(message,ensure_ascii=False)+'\n').encode()
                    else:payload=prompt.encode()
                    input_errors=[]
                    def send_input():
                        try:
                            child.stdin.write(payload)
                            child.stdin.close()
                        except (OSError,ValueError) as exc:input_errors.append(exc)
                    writer=Thread(target=send_input,daemon=True);writer.start()
                    checked=0
                    while child.poll() is None:
                        if cancel.wait(.2):raise InterruptedError()
                        if monotonic()>deadline:raise ValueError('AI 对话超时，本地调整未改变。可以重试或切换另一个对话引擎')
                        checked+=1
                        if checked%3==0:
                            # pread 不移动文件偏移，不会打乱 CLI 正在写的输出。
                            seen=b''.join(os.pread(f.fileno(),256*1024,0) for f in (stderr,stdout)).decode(errors='replace')
                            failure=early_failure(provider,seen.replace(prompt,''))
                            if failure:raise failure
                    writer.join(timeout=1)
                    if child.returncode:
                        stdout.seek(0);stderr.seek(0)
                        diagnostic=(stdout.read(512*1024)+stderr.read(512*1024)).decode(errors='replace')
                        raise cli_failure(provider,diagnostic)
                    if writer.is_alive() or input_errors:
                        raise ValueError('AI 输入未能完整发送，本地调整未改变。请重试')
                    stdout.seek(0);text=stdout.read(2*1024*1024).decode(errors='replace')
                    try:return parse_output(provider,text,output.read_text() if output.exists() else None,stream=provider=='claude' and bool(images))
                    except (ValueError,TypeError):raise ValueError('AI 没有返回有效的调整计划，设置未改变')
                finally:
                    if child.poll() is None:
                        child.terminate()
                        try:child.wait(timeout=3)
                        except subprocess.TimeoutExpired:child.kill();child.wait()
