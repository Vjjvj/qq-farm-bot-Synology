#!/usr/bin/env bash
# 构建群晖 DSM 原生安装包（.spk）
#
# 用法：synology/build.sh                                    # x86_64，版本号取「当天日期-当天序号」
#       SPK_ARCH=armv8 synology/build.sh                     # armv8（rtd1296/rtd1619/armada37xx）
#       SPK_VERSION=2026.11.17-3 synology/build.sh           # 指定版本号
#       VERSION_ONLY=1 synology/build.sh                     # 只打印将用的版本号，不构建
# 产物：synology/out/qq-farm-bot_<版本>_<架构>.spk（+ .sha256）
#
# 依赖：Linux + GNU tar、Node.js 20+、pnpm 10、curl
# 必须在 Linux 上构建：.spk 外层是不压缩的 tar，内含带可执行位的 node 二进制，
# 在 Windows（Git Bash/MSYS）上打包会丢权限，装到 DSM 上起不来。
#
# 版本号 = 构建日期（Asia/Shanghai）YYYY.MM.DD + 当天的第几个包：2026.11.17-1、2026.11.17-2……
#   序号只按天算，跨天归零重来，第二天出包就是 2026.11.18-1，不会像以前那样一路累加到 -11、-12。
#   DSM 的 version 是「主版本-feature build」两段：主版本放日期、feature build 放当天序号，
#   所以 2026.11.18-1 一定比 2026.11.17-10 新，同一天再出包就在当天序号上 +1。
#   自动选号依据：仓库已发的 spk-* tag（本地 + 远端，取最大者）。
#   可用 SPK_VERSION=2026.11.17-3 指定，但不能低于已发布的版本；本地测试可设 ALLOW_NOT_NEWER=1 跳过检查。
#   VERSION_ONLY=1 只输出将使用的版本号、不构建（不需要 Linux，CI 里也用它取号）。
#   RELEASE_REMOTE 指定查询 tag 的远端，默认 origin。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SYNO_DIR="${ROOT}/synology"

VERSION_RE='^[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[1-9][0-9]*$'
TODAY="$(TZ=Asia/Shanghai date '+%Y.%m.%d')"

# 按 (日期, 当天序号) 逐段比较：$1 > $2 时返回 0
version_gt() {
    local d1="${1%-*}" n1="${1##*-}" d2="${2%-*}" n2="${2##*-}"
    local IFS=. i
    local -a a=($d1) b=($d2)
    for i in 0 1 2; do
        if (( ${a[i]:-0} > ${b[i]:-0} )); then return 0; fi
        if (( ${a[i]:-0} < ${b[i]:-0} )); then return 1; fi
    done
    (( ${n1:-0} > ${n2:-0} ))
}

# 已发布的版本：本地 tag 与远端 tag 合并后取最大者（远端查不到就只用本地的）
LAST_VERSION=""
RELEASE_REMOTE="${RELEASE_REMOTE:-origin}"
while read -r tag_ver; do
    [[ "${tag_ver}" =~ ${VERSION_RE} ]] || continue
    if [ -z "${LAST_VERSION}" ] || version_gt "${tag_ver}" "${LAST_VERSION}"; then
        LAST_VERSION="${tag_ver}"
    fi
done < <(
    git -C "${ROOT}" tag -l 'spk-*' 2>/dev/null | sed -n 's/^spk-//p' || true
    if git -C "${ROOT}" remote get-url "${RELEASE_REMOTE}" >/dev/null 2>&1; then
        # 断网时别把出包卡死在这里
        timeout 30 git -C "${ROOT}" ls-remote --tags --refs "${RELEASE_REMOTE}" 'spk-*' 2>/dev/null \
            | sed -n 's#.*refs/tags/spk-\(.*\)$#\1#p' || true
    fi
)

if [ -n "${SPK_VERSION:-}" ]; then
    APP_VERSION="${SPK_VERSION}"
else
    APP_VERSION="${TODAY}-1"
    if [ -n "${LAST_VERSION}" ]; then
        IFS=- read -r last_date last_n <<<"${LAST_VERSION}"
        if [ "${last_date}" = "${TODAY}" ]; then
            APP_VERSION="${TODAY}-$(( ${last_n:-0} + 1 ))"
            echo "==> 今天已发布 ${LAST_VERSION}，本次使用 ${APP_VERSION}" >&2
        fi
    fi
fi
if ! [[ "${APP_VERSION}" =~ ${VERSION_RE} ]]; then
    echo "版本号格式无效：${APP_VERSION}（应为 YYYY.MM.DD-N，如 2026.11.18-1）" >&2
    exit 1
fi
# 只在「比已发布的更旧」时拦：等于已发布是合法的——push spk-* tag 触发 CI 时这个 tag 本身就在
# LAST_VERSION 里，重跑同一个 tag 也要能过。低了才拦，因为 DSM 不会把它当升级。
if [ -n "${LAST_VERSION}" ] && [ "${ALLOW_NOT_NEWER:-0}" != "1" ] && version_gt "${LAST_VERSION}" "${APP_VERSION}"; then
    echo "版本 ${APP_VERSION} 低于已发布的 ${LAST_VERSION}，DSM 不会把它当作升级。" >&2
    echo "本地测试可设 ALLOW_NOT_NEWER=1；正式出包请换用更高的版本号。" >&2
    exit 1
fi
if [ "${VERSION_ONLY:-0}" = "1" ]; then echo "${APP_VERSION}"; exit 0; fi

case "$(uname -s)" in
    Linux) ;;
    *)
        echo "只能在 Linux 上构建（需要 GNU tar 保留 node 可执行位），当前系统：$(uname -s)" >&2
        exit 1
        ;;
esac

OUT_DIR="$(mkdir -p "${1:-${SYNO_DIR}/out}" && cd "${1:-${SYNO_DIR}/out}" && pwd)"
CACHE_DIR="${NODE_CACHE_DIR:-${OUT_DIR}/cache}"
STAGE_DIR="${OUT_DIR}/stage"
PAYLOAD_DIR="${OUT_DIR}/payload"

PKG_NAME="qq-farm-bot"
SPK_ARCH="${SPK_ARCH:-x86_64}"
NODE_VERSION="${NODE_VERSION:-v22.23.3}"
MAINTAINER_NAME="${MAINTAINER:-$(git -C "${ROOT}" config user.name 2>/dev/null || echo unknown)}"

case "${SPK_ARCH}" in
    x86_64) NODE_ARCH="linux-x64" ;;
    armv8) NODE_ARCH="linux-arm64" ;;
    armv7) NODE_ARCH="linux-armv7l" ;;
    *)
        echo "不支持的 SPK_ARCH：${SPK_ARCH}（可选 x86_64 / armv8 / armv7）" >&2
        exit 1
        ;;
esac

SPK_FILE="${PKG_NAME}_${APP_VERSION}_${SPK_ARCH}.spk"
NODE_DIST="node-${NODE_VERSION}-${NODE_ARCH}"

# 后端两个产物的共同打包参数，与 fnos/sea/build-sea.sh 保持一致
EXTERNALS=(--external:bufferutil --external:utf-8-validate --external:encoding)
ESBUILD_OPTS=(--bundle --platform=node --target=node22 --format=cjs --legal-comments=none --log-level=warning "${EXTERNALS[@]}")

echo "==> ${PKG_NAME} ${APP_VERSION}（${SPK_ARCH} → ${NODE_ARCH}，Node ${NODE_VERSION}）"

echo "==> 1/6 安装依赖"
cd "${ROOT}"
if [ "${SKIP_INSTALL:-0}" != "1" ]; then
    pnpm install --frozen-lockfile
fi

echo "==> 2/6 构建前端与后端"
# 群晖版挂在站点根路径（入口直接转发到本机 3007，不改写路径）：
# VITE_BASE 留空即 base="/"，运行时也不设 QQ_FARM_GATEWAY_PREFIX。
# FPK_VERSION 是上游 web 里的版本注入位（vite define __FPK_VERSION__），群晖版复用它写 spk 版本号
FPK_VERSION="${APP_VERSION}" pnpm -C web build
pnpm -C core build:ts

echo "==> 3/6 打包后端为单文件 JS"
rm -rf "${STAGE_DIR}" "${PAYLOAD_DIR}"
mkdir -p "${STAGE_DIR}" "${PAYLOAD_DIR}/server/bin" "${PAYLOAD_DIR}/server/resources/utils" "${PAYLOAD_DIR}/server/web"
pnpm exec esbuild "${ROOT}/fnos/sea/entry.js" "${ESBUILD_OPTS[@]}" --outfile="${PAYLOAD_DIR}/server/bin/main.js"
pnpm exec esbuild "${ROOT}/core/dist/core/worker.js" "${ESBUILD_OPTS[@]}" --outfile="${PAYLOAD_DIR}/server/bin/worker.js"

# 飞牛用 --banner:js 把 QQ_FARM_NO_TCP='1' 编进产物，带上去群晖版永远无法监听 TCP
if grep -q "QQ_FARM_NO_TCP = " "${PAYLOAD_DIR}/server/bin/main.js" "${PAYLOAD_DIR}/server/bin/worker.js"; then
    echo "产物中混入了 QQ_FARM_NO_TCP 赋值，群晖版将拒绝监听 TCP" >&2
    exit 1
fi
# 依赖必须全是纯 JS，否则要随包提供对应架构的 .node 预编译文件
if [ -n "$(find -L "${ROOT}/core/node_modules" -name '*.node' -print -quit 2>/dev/null)" ]; then
    echo "检测到原生 .node 模块，需随包提供 ${NODE_ARCH} 预编译文件" >&2
    exit 1
fi

echo "==> 4/6 获取并校验官方 Node.js ${NODE_DIST}"
mkdir -p "${CACHE_DIR}"
if [ ! -x "${CACHE_DIR}/${NODE_DIST}/bin/node" ]; then
    curl -fsSL -o "${CACHE_DIR}/${NODE_DIST}.tar.gz" "https://nodejs.org/dist/${NODE_VERSION}/${NODE_DIST}.tar.gz"
    curl -fsSL -o "${CACHE_DIR}/SHASUMS256-${NODE_VERSION}.txt" "https://nodejs.org/dist/${NODE_VERSION}/SHASUMS256.txt"
    (cd "${CACHE_DIR}" && grep " ${NODE_DIST}\.tar\.gz$" "SHASUMS256-${NODE_VERSION}.txt" | sha256sum -c -)
    tar -xzf "${CACHE_DIR}/${NODE_DIST}.tar.gz" -C "${CACHE_DIR}"
fi
mkdir -p "${PAYLOAD_DIR}/node/bin"
cp "${CACHE_DIR}/${NODE_DIST}/bin/node" "${PAYLOAD_DIR}/node/bin/node"
cp "${CACHE_DIR}/${NODE_DIST}/LICENSE" "${PAYLOAD_DIR}/node/LICENSE"
chmod 755 "${PAYLOAD_DIR}/node/bin/node"

echo "==> 5/6 组装应用目录"
cp -a "${ROOT}/core/src/gameConfig" "${PAYLOAD_DIR}/server/resources/gameConfig"
cp -a "${ROOT}/core/src/proto" "${PAYLOAD_DIR}/server/resources/proto"
rm -f "${PAYLOAD_DIR}/server/resources/proto/"*.bak
cp -a "${ROOT}/core/src/utils/tsdk.wasm" "${ROOT}/core/src/utils/tsdk-wx.wasm" "${PAYLOAD_DIR}/server/resources/utils/"
cp -a "${ROOT}/web/dist" "${PAYLOAD_DIR}/server/web/dist"

cat >"${PAYLOAD_DIR}/BUILD_INFO" <<INFO
app_version=${APP_VERSION}
bot_version=$(node -p "require('${ROOT}/core/package.json').version")
source_commit=$(git -C "${ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)
spk_arch=${SPK_ARCH}
runtime=node ${NODE_VERSION} ${NODE_ARCH}
built_at=$(date '+%Y-%m-%d %H:%M:%S %z')
INFO

# 内层 package.tgz 解到 /var/packages/<pkg>/target
EXTRACT_SIZE_KB="$(du -sk "${PAYLOAD_DIR}" | cut -f1)"
(cd "${PAYLOAD_DIR}" && tar cf - --owner=0 --group=0 --numeric-owner . | gzip -n -9 >"${STAGE_DIR}/package.tgz")

cat >"${STAGE_DIR}/INFO" <<INFO
package="${PKG_NAME}"
version="${APP_VERSION}"
arch="${SPK_ARCH}"
os_min_ver="7.0-40000"
displayname="QQ 农场"
description="QQ 农场智能助手（qq-farm-bot）群晖原生版：内置 Node.js 运行环境，无需应用中心套件。"
maintainer="${MAINTAINER_NAME}"
maintainer_url="https://github.com/Vjjvj/qq-farm-bot-Synology"
distributor="${MAINTAINER_NAME}"
distributor_url="https://github.com/Vjjvj/qq-farm-bot-Synology"
support_url="https://github.com/Vjjvj/qq-farm-bot-Synology/issues"
checksum="$(cd "${STAGE_DIR}" && md5sum package.tgz | cut -d' ' -f1)"
extractsize="${EXTRACT_SIZE_KB}"
ctl_stop="yes"
beta="no"
INFO

cp -a "${SYNO_DIR}/scripts" "${STAGE_DIR}/scripts"
cp -a "${SYNO_DIR}/conf" "${STAGE_DIR}/conf"
chmod 755 "${STAGE_DIR}"/scripts/*
# 飞牛图标正好是 DSM 需要的 64×64 与 256×256
cp -a "${ROOT}/fnos/qq-farm-bot/ICON.PNG" "${STAGE_DIR}/PACKAGE_ICON.PNG"
cp -a "${ROOT}/fnos/qq-farm-bot/ICON_256.PNG" "${STAGE_DIR}/PACKAGE_ICON_256.PNG"

echo "==> 6/6 打包 SPK"
# 外层 .spk 是不压缩的 tar，INFO 必须在最前面
cd "${STAGE_DIR}"
rm -f "${OUT_DIR}/${SPK_FILE}"
tar cf "${OUT_DIR}/${SPK_FILE}" --format=ustar --owner=0 --group=0 --numeric-owner \
    INFO package.tgz conf scripts PACKAGE_ICON.PNG PACKAGE_ICON_256.PNG
cd "${OUT_DIR}"
sha256sum "${SPK_FILE}" | tee "${SPK_FILE}.sha256"

echo "完成：${OUT_DIR}/${SPK_FILE}（$(du -h "${SPK_FILE}" | cut -f1)，${APP_VERSION} / ${SPK_ARCH}）"
echo "装机前请在群晖上确认 glibc：/lib/libc.so.6 | head -1（Node 22 需要 ≥ 2.28；DSM 上 /usr/bin/ldd --version 无输出）"
echo "安装后默认监听 0.0.0.0:3007（局域网可直接访问）；收回回环改 synology/scripts/postinst 或装机后的 settings.conf"
