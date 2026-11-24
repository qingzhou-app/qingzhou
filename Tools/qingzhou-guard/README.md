# qingzhou-guard —— 断网开关（当前状态：已实现、**未安装**）

目标：代理崩了、被退出、虚拟网卡没了的时候，普通程序一个包都出不去，只剩局域网能通；
开机自动生效，被别的程序清掉会自己补回来；一条命令解除。

## 为什么需要 root 中继（这是本方案的地基）

实测（`diagnose.sh` 第 3 节，可复现）：

```
pid=20651 uid=501  Qingzhou-Tunnel       ← 轻舟的 xray 跑在这里
```

隧道扩展和普通程序是**同一个 uid（501）**。macOS 的 pf 只能按 uid / 网段 / 端口匹配，
**没有进程名匹配**。于是：

- 写 `block out all user != root` → 连 xray 自己的出站也被拦，整机断网；
- 写「按检测结果切换规则」→ 检测有窗口，做不到"一条都不漏"。

所以只能让**代理的出站由一个 root 进程代为拨号**：

```
App ──▶ utun ──▶ xray(uid 501) ──▶ 127.0.0.1:10808 (root 中继) ──▶ 外网
                      │
                      └─ 只连回环，pf 放行

代理挂了 / TUN 没了：普通程序的包从 en0 直接出去 ──▶ uid 501 ──▶ pf 丢弃
```

规则是**静态常驻**的，没有检测、没有切换，所以没有窗口。

## 组件

| 文件 | 作用 |
|---|---|
| `relay/main.swift` | root 中继：SOCKS5 CONNECT + 用户名密码认证，只听 127.0.0.1 |
| `build-relay.sh` | 编译中继（不需要 sudo） |
| `pf/qingzhou-guard.conf` | pf 规则（回环 / 局域网 / root 放行，其余拒绝） |
| `guard-run.sh` | 守护脚本：起中继 + 每 10 秒补一次规则 |
| `install.sh` | 装文件、生成凭据、注册 LaunchDaemon（**不启用拦截**） |
| `enable.sh` | 三项检查通过后启用拦截 |
| `off.sh` | 一条命令解除拦截（不动中继，避免把 VPN 弄断） |
| `uninstall.sh` | 彻底卸载 |
| `diagnose.sh` | 只读体检（不加 sudo 也能跑大半） |

名字固定，急救命令按这两个写：

- pf 锚点：`com.apple/qingzhou_guard`（挂在 `/etc/pf.conf` 已有的 `anchor "com.apple/*"` 下，
  **不改 pf.conf**）
- LaunchDaemon Label：`com.sbraveyoung.qingzhou.guard`
- 解除脚本：`/Library/Application Support/qingzhou-guard/off.sh`

## 安装与启用（顺序不能颠倒）

```sh
# 1) 编译（免 sudo）
sh Tools/qingzhou-guard/build-relay.sh

# 2) 安装（免启用，此时机器网络与之前完全一样）
sudo sh Tools/qingzhou-guard/install.sh

# 3) 自测中继能出网
U=$(sudo grep -v '^#' "/Library/Application Support/qingzhou-guard/relay-auth" | cut -d: -f1)
P=$(sudo grep -v '^#' "/Library/Application Support/qingzhou-guard/relay-auth" | cut -d: -f2)
curl -sS -o /dev/null -w '%{http_code}\n' --proxy "socks5h://$U:$P@127.0.0.1:10808" https://example.com/

# 4) ⚠️ 只有把代理出站串到中继、并确认代理仍能上网之后，才启用拦截
sudo sh "/Library/Application Support/qingzhou-guard/enable.sh"
```

**第 4 步之前必须先做的事**：让轻舟的 `exit` / `hop` / `direct` 三个出站都串到中继
（xray 里是新增一个 `relay` 出站 + 每个出站的 `streamSettings.sockopt.dialerProxy`），
**这一步代码里还没做**。串之前启用 = 立刻断网。

## 断网时怎么自救

```sh
sudo sh "/Library/Application Support/qingzhou-guard/off.sh"
```

它只停拦截、不杀中继，所以不影响正在跑的 VPN。

## 已知限制（如实列出）

1. **中继已本地验证，未在 root 下装过**：`install.sh` 需要你执行；我没跑过任何 sudo 安装。
2. **代理还没串到中继**：这是启用前的硬前提，尚未实现。
3. **IPv6**：当前机器上除轻舟外还有别的 utun 声明了 IPv6 默认路由（`utun0`–`utun5`、`utun7`）。
   规则里对 `fe80::/10`、`fc00::/7`、`ff00::/8` 放行（局域网必须能通），
   但这些放行**也可能被用于 IPv6 侧信道**，需要在启用前单独验证。
4. **`block out quick all` 会拦掉 `_mdnsresponder` 等系统用户的非局域网流量**：
   局域网（224.0.0.0/4、fe80::/10、ff00::/8）已放行，AirDrop / Bonjour 不受影响；
   但其它依赖外网的系统服务会一起被挡。这是"不漏"的代价。
5. **pf 是全局的**：`off.sh` 里的 `pfctl -d` 会关掉整台机器的 pf，
   如果将来还有别的程序用它，需要改成只清锚点。
