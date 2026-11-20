# iOS发行源码归档

`scripts/release/archive_source.py --platform ios`从发行构建使用的完整Git提交SHA生成对应源码ZIP。默认不传`--platform`时仍生成原Android范围的归档。

## 源码范围

iOS归档保留主仓库已提交文件、固定proot源码，并展开主仓库gitlink固定的iSH源码及其递归依赖。每一层都从本地Git对象库读取固定提交，不使用子模块当前HEAD，不拷贝工作树文件，不自动联网获取缺失对象。

`SOURCE_RELEASE.json`记录主提交、每层子模块路径与提交、展开状态，以及每个文件的模式、大小和SHA256。iOS使用`status: ios-release-source`和`scope: iOS corresponding source`。缺少独立子仓库、固定对象或必需递归依赖时归档失败，不用父仓库或其他版本补齐。

仅有一个明确的可选范围：`android/deps/ish/deps/linux`。只有固定iSH提交的`.gitmodules`将它设置为`update=none`，且固定主提交的`android/deps/build_ish.sh`明确选择`-Dkernel=ish`时，才保留其gitlink而不展开Linux备选内核。清单会记录固定提交和原因。配置变化后不再自动排除；其他递归依赖没有通用跳过规则。

归档沿用私密路径、秘密内容、路径穿越、跨平台名称冲突、符号链接范围与悬空链接校验。失败不生成正式ZIP；已有输出不允许覆盖。Git元数据、签名配置、运行记录和未提交文件不会作为源码输入。公开上游源码如触发严格校验，也应先审查具体文件，不能全局关闭扫描。

## 固定公开源码例外

部分公开源码名称与通用运行文件规则相同。归档器只允许`REVIEWED_PUBLIC_FILES`中逐项列出的精确路径，且从Git对象读取的原始字节必须等于表中SHA256；内容变化即失败，不依据当前工作树或同名文件判断。例外不能是符号链接，仍执行秘密扫描和其余路径规则；`.log`后缀及`build`目录没有通用放行规则。

当前72个例外来自以下两个固定上游提交，许可证及文件头均随源码原样保留：

- libapps`b8cacae35e5b11d64bb736a053921c16ca7faf9e`：3个hterm终端回放数据`hterm/test_data/charsets.log`、`vttest-01.log`、`vttest-02.log`，以及22个名为`build`的公开构建脚本。固定`hterm/test_data/README.md`说明这些日志由Vttest生成，`hterm/js/hterm_vt_canned_tests.js`加载它们验证字符集、光标位置及终端输出。libapps的`LICENSE`和构建脚本头部保留Chromium OS Authors的BSD许可说明。
- libarchive`fc6563f5130d8a7ee1fc27c0e55baef35119f26c`：47个提交在`build/`下的构建源码，包含Autoconf宏、CMake检查、CI脚本和发行说明；固定`build/README.txt`与`COPYING`明确描述这些文件的用途与逐文件许可要求。不会把它们误当成此次构建产生的运行目录，也不会删除原许可声明。

例如`charsets.log`原始文件为4255字节，SHA256为`009fbdd735339cf516e9452ab52120adede4a5a4cc4a285742747b306ee68ed4`。新版依赖如果改变例外文件，需要重新审查固定对象并更新对应哈希，不能只改路径或关闭校验。

## 准备固定源码

在独立检出目录准备对象，替换下面的`<sourceCommit>`为对应发行构建的完整SHA：

```bash
git clone --no-checkout https://github.com/sherlockerX/Nivo-Bot.git nivo-source
git -C nivo-source checkout --detach <sourceCommit>
git -C nivo-source submodule update --init --recursive
```

不要使用`git submodule update --remote`，它可能改用上游分支的新提交。默认递归初始化遵循固定`.gitmodules`中的`update=none`，不需要下载未参与本次iSH构建的Linux备选内核。归档器会再次核对每一层的固定对象；工作树已有变更不影响选定提交的归档字节。

## 生成与验证

```bash
python scripts/release/archive_source.py \
  --root nivo-source \
  --commit <sourceCommit> \
  --platform ios \
  --output Nivo-Bot-v2.0.8-source.zip
```

脚本先执行全部安全检查和ZIP CRC校验，再以不覆盖方式生成最终文件；输出JSON给出实际大小、SHA256、文件数和源提交。下载目录的`sourceCommit`、`sourceSha256`和`sourceSizeBytes`必须使用本次实际结果。旧Android或iOS版本的源码ZIP和哈希保持原发行身份，不改名复用。

测试命令：

```bash
python -m unittest discover -s scripts/release -p test_archive_source.py -v
```

测试使用临时Git仓库和人工构造数据，覆盖递归固定提交、子模块HEAD与工作树漂移、缺失依赖、秘密拦截、可选Linux判定、真实CLI和Android兼容行为。

## 构建边界

归档提供固定的对应源码，但不包含Apple工具链、签名身份、SwiftPM下载缓存、FFmpeg下载包等构建环境。依赖准备与构建命令以同一提交的`.github/workflows/ios-check.yml`、`android/deps/*.sh`和[原生iOS构建说明](ios.md)为准；Release发行应选择工作流的Release配置。

源码ZIP不带`.git`。现有`build_ish.sh`含Git子模块初始化逻辑，直接从ZIP解压目录运行不等于已验证的全新构建。重建时优先使用上面的固定提交检出及递归初始化流程，与ZIP的`SOURCE_RELEASE.json`逐项比对源码身份。本归档不宣称IPA字节可复现，也不代替设备安装与运行验收。
