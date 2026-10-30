# 随心调色发行准备

核查日期：2026-10-30。当前 `dist/SuiTone.app` 是本机开发构建，不是可独立分发的安装包。

## 本次发行前验证

- 已在临时目录打包独立引擎（PyInstaller）；隔离工作目录中验证了服务启动、34 款风格、公开样片导入和预览。
- 临时应用候选包使用包内引擎，移除项目路径配置后在本机独立窗口导入公开样片成功；仍使用这台电脑已有模型和系统环境，尚未在干净机器验收，不应发布为安装包。
- 机器当前只有 Apple Development 签名，未发现 Developer ID 签名；候选包为临时签名，未进行公证。
- 模型文件没有随候选包打入；SegFormer 权重的适用和再分发授权仍需明确。模型缺失的首次启动、下载安装流程和多架构尚未完成。

## 必须解决

1. **分区模型授权**：当前 ONNX 仓库声明其基础模型是 NVIDIA SegFormer B2。NVIDIA 的 [SegFormer 源码许可证](https://github.com/NVlabs/SegFormer/blob/master/LICENSE) 第 3.3 条限定非商业研究或评估用途；[上游模型页](https://huggingface.co/nvidia/segformer-b2-finetuned-ade-512-512)只标注 `other`，没有给出明确的权重商业授权。不能根据转换仓库的存在认定权重可商用。发行前取得权利人明确授权，或更换权利链清楚的模型，并重验天空、水、人物、土地及物体选区。
2. **运行环境**：当前开发构建从 Info.plist 的 `PhotoEditProjectRoot` 找引擎，Python 指向用户目录下的专用虚拟环境；该环境的解释器又链接到本机 pyenv。换一台 Mac 或移动项目后不能视为可运行。应用代码已支持从包内 `Resources/engine` 和 `Resources/python/bin/python3` 启动，并将会话放在用户的 `Library/Application Support/SuiTone`，但构建脚本尚未提供可迁移的 Python 和依赖。还需完成打包、嵌套签名和干净机器验证。
3. **分发签名与公证**：本机开发构建用 Apple Development 签名；对外分发还需适用的 Developer ID、嵌套代码签名、加固运行时、公证及干净机器验证。当前构建成功不等于完成这些步骤。
4. **模型与依赖随包或下载**：确定各文件来源、版本、校验和、许可证与告知文件；模型下载和存储位置应对用户明确。必须验证缺失、损坏、下载中断及重试，不能依赖开发机已有缓存。
5. **最终验收**：阶段 2 固定案例原有未通过记录仍保留；真实对话、参考匹配、修复、RAW、导出和首次启动需在最终分发构建上验证。不能将单元测试或本机开发包构建视为视觉验收和发行验收。

## 其他模型的已查证据

- [Carve LaMa ONNX](https://huggingface.co/Carve/LaMa-ONNX) 标注 Apache-2.0，称其为原始 big-lama 的转换；[上游 LaMa 仓库](https://github.com/advimman/lama/blob/main/LICENSE)采用 Apache-2.0。分发前仍应固定具体文件版本并随包提供适用许可与声明。
- [Swin2SR 官方项目](https://github.com/mv-lab/swin2sr)及其 [2 倍](https://huggingface.co/caidas/swin2SR-classical-sr-x2-64)、[4 倍](https://huggingface.co/caidas/swin2SR-realworld-sr-x4-64-bsrgan-psnr)模型页标注 Apache-2.0；现用的是转换版，需固定版本并核对转换来源和附带许可。
- 第三方模型卡上的许可标签不能自动解决其训练数据、基础权重和转换过程的权利问题。替代方案必须覆盖本产品所需类别，且实际验证遮罩质量与速度。
