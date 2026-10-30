"""资源目录：AI 模型放在哪里。

默认 `~/.cache/photo-edit`（源码安装时由 install.sh 下载到这里）；
发行版把模型放进 App 包内，由 App 通过环境变量 `PHOTO_EDIT_ASSETS` 指过来。
"""
import os
from pathlib import Path


def assets() -> Path:
    override = os.environ.get('PHOTO_EDIT_ASSETS')
    return Path(override).expanduser() if override else Path.home() / '.cache/photo-edit'


ASSETS = assets()
