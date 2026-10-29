# photo-edit 项目

修图工具的**唯一代码源 + 案例库**。`photo-edit` skill（`~/.claude/skills/photo-edit`）只放使用说明和红线，干活时调用这里的 `engine/`。

## 结构

```
photo-edit/
├── CLAUDE.md
├── engine/                    ← 修图引擎（Python，入 git）；说明见 engine/README.md
├── app/                       ← SwiftUI 原生界面（SwiftPM，入 git）
├── script/                    ← 构建、运行与验收入口（入 git）
├── docs/HANDOFF.md            ← 随心调色 App 开发移交：第 0 节＝当前进度与下一步，接手先读
├── docs/APP_SPEC.md           ← 数据边界与验收用例（第 5、6 节有效）
├── docs/archive/              ← 旧审阅记录、阶段 2 评分过程，只查历史证据
├── cases/                     ← 每次修图一个目录：日期_地点/主题
│   └── 2026-10-27_西吉震湖/
│       ├── 原图/              ← 只放照片，视频不放
│       └── 定稿_xxx/          ← 交付给用户的版本（不覆盖，改就另开新目录）
├── tmp/                       ← 中间稿（gitignore 习惯：用完即删）
└── output/                    ← LUT 等工具产物（output/luts/）
```

## 约定

- 新任务：在 `cases/` 下新建 `YYYY-MM-DD_主题/`，原图**复制**进 `原图/`，不动用户原始位置。
- 只保留原图和定稿，过程稿放 `tmp/`，任务结束后清掉。
- 视频不进来。
- 每个案例的选片、参数、被否方向记在 skill 的 `references/cases.md`，不在这里重复写。

## 运行

- Python：`~/.cache/photo-edit/venv/bin/python`；模型在 `~/.cache/photo-edit/`（不入 git，下载地址见 engine/README.md）。
- 改了 engine 先跑 `cli.py grade` 冒烟测试，再跑 docs/APP_SPEC.md 第 6 节验收用例里相关的那几条。
- 测试只用 `./script/test.sh`（Swift＋Python）；构建 `./script/build_and_run.sh --build-only`。本机没有 Xcode，直接 `swift test` 会失败，原因和截图验收方法见 HANDOFF 第 0 节「开发环境的坑」。
- git 管 `engine/`、`app/`、`script/`、`docs/`、`.codex/` 和项目约定；`cases/`、`output/`、`tmp/`、`dist/`、构建缓存不入库。
