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
from smart import STYLES

PARAMETERS=['exposure','contrast','saturation','temperature','tint','highlights','shadows',
            'black_white','dehaze_amt','effect_strength','skin_protect','smooth','bright',
            'match_strength','sky_hue','autumn','water_var',
            'water_enabled','sky_enabled','land_enabled','portrait_enabled']
PARAMETERS += ['shadow_hue','shadow_chroma','highlight_hue','highlight_chroma','fade']
PARAMETERS += [r+'_'+c for r in ['water','sky','land','person'] for c in ['l','a','b']]
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
编辑输出可回退的参数方案。裁切、尺寸和输出格式属于导出工作流，不是永久禁令。
用户只讨论、询问或要求建议时 actions=[]。
仅当用户要求修图时填写 actions，且 id 只能来自当前 targets。整批请求要覆盖 targets 各张，考虑每张自身曝光。
默认温和调整，保留现场光感和肤色。自然不是固定成某种水色；暖调、电影感、复古等根据诉求用通用风格起步再调整。
preset=keep 保留现有设置；smart/clean/soft/warm/cool/mono 为自然微调。
vivid鲜明、airy轻盈也属于自然微调；golden金色时刻、bleach银幕冷调属于创作风格。
cinema青橙电影、film暖胶片、neon霓虹夜色、vintage复古褪色、editorial低饱和叙事、noir高反差黑白为明显创作风格。
shadow_hue/highlight_hue[-180,180]、shadow_chroma/highlight_chroma[0,30] 可分离阴影高光染色，fade[0,1]褪黑。
adjustments 为 set/add/multiply 数值操作：exposure[-3,3]EV、contrast[0,2]、saturation[0,2]、
temperature[-1,1]正暖负冷、tint[-1,1]正洋红负绿、highlights/shadows[-1,1]、black_white[0,1]、
dehaze_amt[0,1]、effect_strength[0,1]、match_strength[0,1]、smooth/bright[0,1]。
skin_protect 和 *_enabled 用 set 0/1。water/sky/land/person 的 _l/_a/_b 是对应区域 Lab 目标，可用 add 微调现有区域，
只在确实存在可靠区域时使用。L[0,100]、a/b[-100,100]，a负绿正红，b负蓝正黄。
要查看选区时 selection 取对应名称，否则 none。曝光/对比/色温/高光/阴影等全局调整适用于任何场景。
operations 是按顺序执行的额外操作：denoise 的 value 为 1 开启或 0 关闭；upscale 的 value 为 1、2、4；
repair 和 match 的 value 都为 0。修复只能在目标有用户提供的 repair_selection 时使用，不能猜选区；
参考匹配只有 reference_count 大于 0 时使用。没有可用选区或参考图时说明如何操作，不填该操作。
undo 的 value 为 0，只能在 undo_available 为 true 时单独使用，preset=keep、adjustments=[]，不能和其他操作混用。
每张照片可先使用 preset 与 adjustments，再依序执行 operations；无需额外操作时 operations=[]。
保存个人风格、液化、美妆、生成内容尚未支持，要如实解释，不返回假操作。
reply 用中文描述建议，不要提前宣称已完成；缺关键审美方向时可以问一个具体问题，actions 留空。'''


class CLIRequestError(ValueError):
    def __init__(self,message,retryable=False):
        super().__init__(message);self.retryable=retryable


def cli_failure(provider,output):
    """只返回固定诊断，避免把 CLI 日志中的凭证、路径或用户输入暴露到界面。"""
    name='Codex' if provider=='codex' else 'Claude Code'
    text=output.lower()
    if any(word in text for word in ['usage limit','rate limit','quota exceeded','insufficient_quota','429']):
        return CLIRequestError(name+' 当前额度或调用频率受限，请稍后重试或切换对话引擎')
    if any(word in text for word in ['unauthorized','not logged in','invalid api key','token expired','refresh token','401']):
        return CLIRequestError(name+' 登录已失效，请在该 CLI 中重新登录后重试')
    if any(word in text for word in ['unexpected argument','unrecognized option','unsupported model','model_not_found']):
        return CLIRequestError(name+' 的版本或模型配置不兼容，请切换对话引擎并检查 CLI 配置')
    if any(word in text for word in ['stream disconnected','connection reset','connection refused','network error','timed out','error sending request','502 bad gateway','503 service unavailable']):
        return CLIRequestError(name+' 连接暂时中断，请重试或切换对话引擎',retryable=True)
    return CLIRequestError(name+' 未完成此次请求，可重试或切换对话引擎；本地调整未改变')


def executable(provider):
    candidates={
        'codex':[shutil.which('codex'),'/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex',
                 str(Path.home()/'.local/bin/codex'),'/opt/homebrew/bin/codex','/usr/local/bin/codex'],
        'claude':[shutil.which('claude'),str(Path.home()/'.local/bin/claude'),'/usr/local/bin/claude','/opt/homebrew/bin/claude'],
    }
    return next((p for p in candidates.get(provider,[]) if p and os.path.isfile(p) and os.access(p,os.X_OK)),None)


def parse_output(provider,text,last_message=None):
    if provider=='codex':return json.loads(last_message or text)
    envelope=json.loads(text)
    if envelope.get('is_error'):raise ValueError('Claude Code 未完成请求，请检查其登录状态或可用额度')
    structured=envelope.get('structured_output')
    if isinstance(structured,dict):return structured
    result=envelope.get('result','').strip()
    if result.startswith('```'):result=result.split('\n',1)[1].rsplit('```',1)[0]
    return json.loads(result)


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
        p,notes=apply_operations(p,action['adjustments'],context)
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
    return dict(reply=plan['reply'],selection=plan['selection'],changes=changes)


class AssistantBridge:
    def __init__(self,engine):
        self.engine=engine;self.jobs={};self.events={};self.lock=RLock()

    def providers(self):
        result=[dict(id=p,title=t,available=bool(executable(p))) for p,t in [('codex','Codex'),('claude','Claude Code')]]
        result.append(dict(id='anthropic',title='Claude API',available=True))
        return result

    def start(self,data):
        from service import parameters,repair_input,quality_settings
        if data.get('provider') not in ['codex','claude','anthropic']:raise ValueError('请选择可用的对话引擎')
        if data['provider'] in ['codex','claude'] and not executable(data['provider']):raise ValueError('找不到这个 CLI，请先在本机安装并登录')
        if data['provider']=='anthropic' and (not isinstance(data.get('api_key'),str) or not 0<len(data['api_key'].strip())<=512):
            raise ValueError('请先配置 Claude API 密钥')
        if not isinstance(data.get('image_consent',False),bool):raise ValueError('图片发送开关无效')
        if data.get('image_consent') and data['provider']=='claude':
            raise ValueError('该对话引擎暂不支持安全发送图片，请关闭看图或选择 Codex')
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
        selected=data.get('repair_selection')
        if selected is not None:
            if not isinstance(selected,dict) or set(selected)!={'id','box'} or selected['id'] not in {t['id'] for t in targets}:
                raise ValueError('修复选区不属于当前范围')
            repair_input(selected['box'])
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
                system+='\n这是唯一一次结果复看：若已符合要求，actions=[]；仅在明显需要修正时微调参数，preset 必须为 keep，operations 必须为空。'
            prompt=system+'\n'+json.dumps(context,ensure_ascii=False)
            if event.is_set():raise InterruptedError()
            with self.lock:self.jobs[key]=dict(state='thinking')
            if data['provider']=='anthropic':
                from anthropic_provider import invoke
                result=invoke(data['api_key'],prompt,SCHEMA,images,
                              image_consent=data.get('image_consent',False),cancel=event)
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
                if images:raise ValueError('Claude Code 暂不支持安全发送图片')
                command=[executable(provider),'-p','--output-format','json','--json-schema',json.dumps(SCHEMA),
                         '--tools','','--strict-mcp-config','--mcp-config','{"mcpServers":{}}',
                         '--settings','{"disableAllHooks":true}','--disable-slash-commands',
                         '--no-session-persistence','--permission-mode','plan']
            environment=os.environ.copy()
            environment.pop('CLAUDECODE',None)
            # 凭证只交给既有 CLI，不落入日志、提示或返回值。
            with TemporaryFile() as stdout,TemporaryFile() as stderr:
                if cancel.is_set():raise InterruptedError()
                child=subprocess.Popen(command,cwd=root,env=environment,stdin=subprocess.PIPE,stdout=stdout,stderr=stderr)
                try:
                    child.stdin.write(prompt.encode());child.stdin.close()
                    while child.poll() is None:
                        if cancel.wait(.2):raise InterruptedError()
                        if monotonic()>deadline:raise ValueError('AI 对话超时，本地调整未改变。可以重试或切换另一个 CLI')
                    if child.returncode:
                        stdout.seek(0);stderr.seek(0)
                        diagnostic=(stdout.read(512*1024)+stderr.read(512*1024)).decode(errors='replace')
                        raise cli_failure(provider,diagnostic)
                    stdout.seek(0);text=stdout.read(2*1024*1024).decode(errors='replace')
                    try:return parse_output(provider,text,output.read_text() if output.exists() else None)
                    except (ValueError,TypeError):raise ValueError('AI 没有返回有效的调整计划，设置未改变')
                finally:
                    if child.poll() is None:
                        child.terminate()
                        try:child.wait(timeout=3)
                        except subprocess.TimeoutExpired:child.kill();child.wait()
