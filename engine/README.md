# photo-edit engine

本地修图引擎。纯 Python，全部本地推理（ONNX，CPU），不联网、不上传照片。

## 安装

```bash
python3 -m venv ~/.cache/photo-edit/venv
~/.cache/photo-edit/venv/bin/pip install -r requirements.txt
```

模型放在 `~/.cache/photo-edit/` 下，不进 git，共约 530 MB：

| 路径 | 用途 | 下载 |
|---|---|---|
| `segformer/model.onnx` + `config.json` | 分区遮罩（ADE20K 150 类：水/天/人/建筑…） | `https://huggingface.co/Xenova/segformer-b2-finetuned-ade-512-512/resolve/main/onnx/model.onnx`（config.json 在仓库根目录） |
| `lama/lama_fp32.onnx` | 去杂物 | `https://huggingface.co/Carve/LaMa-ONNX/resolve/main/lama_fp32.onnx` |
| `sr/swin2SR-classical-sr-x2-64.onnx` | 2 倍放大 | `https://huggingface.co/Xenova/swin2SR-classical-sr-x2-64/resolve/main/onnx/model.onnx` |
| `sr/swin2SR-realworld-sr-x4-64-bsrgan-psnr.onnx` | 4 倍放大 | `https://huggingface.co/Xenova/swin2SR-realworld-sr-x4-64-bsrgan-psnr/resolve/main/onnx/model.onnx` |

国内网络下载要走代理：`curl -x http://127.0.0.1:7897 -L -o ...`

## 模块

| 文件 | 功能 | 主要函数 |
|---|---|---|
| `grade.py` | 节点式分区调色：黑白点、去雾、对比、水/天/土地分区 | `grade(img, water, dehaze_amt, ...)`、`load()`、`seg_classes()` |
| `inpaint.py` | 去杂物（LaMa，滑窗按接近原分辨率修补） | `remove(img, classes, box, keep)` |
| `portrait.py` | 肤色保护、轻修饰 | `skin_mask()`、`protect_skin()`、`retouch()` |
| `lut.py` | 从「原图→调后」学出 3D LUT（.cube） | `fit()`、`write_cube()`、`read_cube()`、`apply()` |
| `raw.py` | 读 RAW（DNG/CR2/NEF/ARW…），保留高光余量 | `load_raw()` |
| `enhance.py` | 降噪、放大 | `denoise()`、`upscale(scale=2\|4)` |
| `info_bar.py` | 底部 iPhone 式出片信息条（读 EXIF） | `with_bar()`、`meta()` |
| `cli.py` | 命令行入口，参数用 JSON，结果输出一行 JSON（给 App 调用） | 见文件头 |

## 已知局限（实测过）

- LUT 只能表达「同一个颜色映射到同一个颜色」：灰蓝的水和灰蓝的雾山分不开，所以分区调色导不进 LUT。实际做法是导一个「底子 LUT」，水和天在达芬奇里用 Magic Mask 单独建节点调。
- 细小的物体，或者模型叫不出名字的东西（比如被认成 building 的信号塔），要用 `box` + `keep=['sky']` 来框选。
- 4 倍放大在手机远景上会有涂抹感，只适合救急。
- 人像只做肤色保护和轻修饰，精修还是交给像素蛋糕。
- 运行速度（M 系列 CPU）：4032px 调色约 10 秒；去杂物每个 640px 的窗口约 1 秒。
