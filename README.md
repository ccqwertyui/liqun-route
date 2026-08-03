# 利群路由切换改进版脚本

特别声明：本脚本基于利群主机 (Leikwan Host) 官方原版策略路由脚本修改。

对比官方原版，本增强版主要增加了以下核心功能：

1. **精确端口分流**：官方原版脚本仅支持将一整个目标 IP 绑定到一个线路上。本增强版加入了端口级别的精准控制，允许同一个目标 IP 根据不同的端口走不同的路由。例如，你可以让通往海外机器的 443 端口走 CN2 线路，同时让 4443 端口走 9929 线路，实现更灵活的分流。

2. **全局快捷指令**：为了方便日常运维，首次使用一键命令安装脚本后，系统会自动注册快捷指令。以后在服务器的任何目录下，只需要输入 `ly` 并回车，就可以直接唤出图形化管理菜单，无需再手动执行繁琐的文件路径。

3. **智能调度与故障转移 (MWAN) [v4.10 新增]**：自带全自动后台守护进程，支持多线负载与故障自动容灾。包含纯故障转移、纯丢包容灾、综合稳定、极限电竞四种模式，并支持自定义防抖缓冲，彻底告别手动切线与满载断流。

---

## 📥 一键安装与使用指令

请根据需求选择对应的版本，在服务器终端复制并执行即可：

### 🚀 最新版本：v4.10 (改进版) - 推荐
* **核心特性**：内置全自动智能调度引擎（MWAN）、四种高可用选路模式、自定义防抖缓冲机制及可视化任务列表。
* **一键安装指令**：
```bash
curl -fsSL https://raw.githubusercontent.com/ccqwertyui/liqun-route/refs/heads/main/dual-route.sh -o /usr/local/bin/dual-route.sh && chmod +x /usr/local/bin/dual-route.sh && /usr/local/bin/dual-route.sh
```

### 📜 历史版本：v4.5 (经典纯净版)
* **核心特性**：仅包含基础多出口策略路由、端口精准分流、NAT 地址伪装与 DDNS 功能，不含后台智能调度，极致轻量。
* **一键安装指令**：
```bash
curl -fsSL https://raw.githubusercontent.com/ccqwertyui/liqun-route/refs/heads/main/dual-route-v4.5.sh -o /usr/local/bin/dual-route.sh && chmod +x /usr/local/bin/dual-route.sh && /usr/local/bin/dual-route.sh
```
