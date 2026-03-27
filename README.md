# Binaries Powerful

自动化构建 Impacket `examples` 工具的 Windows `exe`。

## 已实现的 GitHub Action

工作流文件：`.github/workflows/build-impacket-exe.yml`

能力如下：

- 从 `https://github.com/fortra/impacket` 拉取源码（`master`）
- 使用 `script/impacket-examples.txt` 维护待打包脚本清单
- 构建逻辑集中在 `script/build-impacket-examples.ps1`
- 同时使用两种打包技术：
  - `pyinstaller`
  - `nuitka`
- 同时使用两个 Python 版本：
  - `3.9`
  - `3.12`

即总共会跑 4 组矩阵任务（`2 x 2`）。

## EXE 命名规则

输出文件名遵循：

`impacket_{py_name}_{python_version}_{package_tech}.exe`

说明：

- `{py_name}` 来自脚本文件名（去除 `.py`），并将非字母数字下划线字符替换为 `_`
- `{python_version}` 例如 `3.9`、`3.12`
- `{package_tech}` 为 `pyinstaller` 或 `nuitka`

## 触发方式

- 手动触发：`workflow_dispatch`
- 代码推送触发：推送到 `main` 或 `master`

## 产物下载

每个矩阵任务都会上传对应 EXE 到 Actions Artifacts，命名格式：

- `impacket-exes-py3.9-pyinstaller`
- `impacket-exes-py3.9-nuitka`
- `impacket-exes-py3.12-pyinstaller`
- `impacket-exes-py3.12-nuitka`

此外，工作流结束后会自动将所有 EXE 同步到固定 Release：

- Tag: `impacket-latest`
- Release 名称: `Impacket Latest Build`
- 同名资源会被覆盖（始终保持最新一批构建结果）

## 注意事项

- 推荐只在 `script/impacket-examples.txt` 中维护你关心的工具（每行一个脚本）。
- 当 `script/impacket-examples.txt` 为空（仅注释/空行）时，会回退为全量打包 `impacket/examples/*.py`。
- 如果某些工具脚本在特定版本/打包器下不兼容，工作流会在日志里列出失败脚本名。
