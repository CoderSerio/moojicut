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
   大小，匹配后才显示镜像链接。
