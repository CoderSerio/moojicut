# 独立下载源

公开入口为 `https://moojicut-downloads.pages.dev`。Cloudflare Pages Function 通过
`RELEASES` 绑定直接读取私有 R2 桶 `moojicut-releases`，下载独立于 GitHub。

下载支持 GET 和 HEAD。版本号同时出现在目录和文件名中。

```text
/v<version>/moojicut-<version>-macos-arm64.zip
/v<version>/moojicut-<version>-windows-x64.zip
/v<version>/moojicut-<version>-linux-x64.tar.gz
```

加上 `.sha256` 可下载原始校验文件。版本支持正式版和 `alpha.N`、`beta.N`、`rc.N`。
服务直接流式传输 R2 对象，支持单区间 Range、后缀区间、If-Range 和条件 GET。

## 部署下载服务

使用已获授权的 Wrangler v4 账户。多账户时通过 `CLOUDFLARE_ACCOUNT_ID` 选择
项目所在账户。下面的命令更新已创建的 Pages 项目并复用现有 R2 桶。

```sh
cd website/download-mirror
mkdir -p dist
cp worker.mjs dist/_worker.js
npx wrangler pages deploy dist --project-name moojicut-downloads --branch main
```

运行 `npm test --prefix website` 检查下载协议。修改服务后，用本地 workerd 和 R2 测试
GET、HEAD、断点续传、无效路径和写入拒绝。生产桶仅用于正式发布文件。

## 镜像新版本

1. 核对 GitHub Release 对应提交、三端安装包的 SHA-256 以及原始 `.sha256` 文件。
2. R2 key 使用公开路径去掉开头斜杠。对每个精确地址发 HEAD。只有 404 才创建对象。
   地址已存在时，下载并校验大小和 SHA-256。内容相同可跳过。不同则选择新版本号。
3. 用 `wrangler r2 object put moojicut-releases/<key> --remote --file <file>` 上传
   原始安装包及对应校验文件，并设置 Content-Type、attachment 文件名与不可变缓存。
   每个版本由同一发布者写入一次。
4. 从公开入口完整下载六个文件并重新计算 SHA-256。核对 HEAD 的 Content-Length
   和 Range 的 206、Content-Range 与分段内容。
5. 更新 `website/verified-mirrors.json`。官网构建会再比较 GitHub Release 的摘要和
   大小，匹配后将该平台的下载按钮指向 Cloudflare。

## 应用内更新

发布后，先按上面的流程同步并验证安装包。对 macOS ZIP 用
`python3 scripts/generate_update_feed.py <archive.zip> --mirror --output <staging>/macos.xml`
生成单独签名的镜像更新源，放到 `v<version>/macos.xml`。它引用同一份已验证的
Cloudflare ZIP，GitHub Release 继续附上指向 GitHub 的签名更新源。

用 `python3 scripts/build_update_index.py <staging>/releases.json` 从已公开的 GitHub
Release 生成更新清单，最后上传到 R2 的 `updates/releases.json`。应用优先读取该清单，
并在无法读取或使用镜像时尝试 GitHub。索引缓存在边缘一分钟，超过七天未同步时，
镜像会返回 503，让客户端检查 GitHub 上的最新记录。

## Beta 多源交付计划

- CI 对每个平台和架构生成一次产物，以版本化路径上传同一份字节到 GitHub、Cloudflare R2 和已配置的阿里云 OSS。每个公开源通过外网长度、完整 SHA-256 和断点请求检查后才能加入发布清单。清单按版本记录文件名、长度、摘要和候选地址。发布应用更新时，连同签名过的更新清单一起同步。
- 官网由访问者浏览器对已启用跨域读取的镜像并行发出小段 Range 请求。用首包耗时和实测吞吐估算剩余下载时间，限时取消慢请求，并在当前会话短暂缓存结果。候选镜像不可用时回到同版本 GitHub 下载。浏览器接管文件下载后，页面无法切换一次已经开始的传输。[OSS CDN 配置](https://www.alibabacloud.com/help/en/oss/user-guide/cdn-acceleration)
- 应用内更新需要同时支持更新清单和包文件的镜像，按候选地址重试。只有能确认版本、大小与摘要匹配时才尝试跨源继续下载。macOS 保留 Sparkle 的签名验证，安装前验证完整产物。手动下载的 DMG 和自动更新的 ZIP 可以分别发布。Alpha 仍手动发布镜像，应用内更新沿用现有签名流程。[Sparkle 发布更新](https://sparkle-project.org/documentation/publishing/)
