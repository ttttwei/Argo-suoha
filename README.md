---

## 💻 一键安装 (Quick Start)

在您的 VPS 终端中执行以下命令即可（支持 Debian / Ubuntu / CentOS / Alpine）：

```bash
bash <(curl -sL suoha.ggff.net | tr -d '\r')

备用链接
```bash
bash <(curl -sL https://raw.githubusercontent.com/ttttwei/Agro-suoha/main/suoha.sh | tr -d '\r')






# Agro-suoha

> TT Cloudflare Tunnel 一键suoha脚本  无需公网 IP | 无需端口转发 Agro隧道 | 支持 VMess/VLESS | 自动优选伪装域名

# 🚀 Agro-suoha (TT 优化版)

> **基于 Cloudflare Tunnel 的新一代轻量级穿透工具**
>
> 无需公网 IP | 无需端口转发 | 极致隐藏 | 专为 NAT VPS 打造

![License](https://img.shields.io/badge/License-MIT-green.svg)
![Language](https://img.shields.io/badge/Language-Bash-blue.svg)
![Platform](https://img.shields.io/badge/Platform-Linux-lightgrey.svg)
![Powered By](https://img.shields.io/badge/Powered%20By-Cloudflare%20Tunnel-orange)

---

## 📖 项目简介

**Agro-suoha** 是一个基于 Cloudflare Tunnel (Argo) 技术的全自动化一键部署脚本。

它旨在解决无公网 IP、防火墙严格或 NAT 机器（如 HAX, IPv6 only VPS）无法对外提供服务的难题。通过建立出站隧道，无需任何端口映射，即可实现从公网到本地服务的安全访问。

本项目由 **tt** 进行二次开发与深度优化，集成了最新的 Xray 内核，并修复了原版逻辑，实现了更稳定的连接与更完美的伪装。

## ✨ 核心功能

* **⚡️ 零门槛部署**：无需公网 IP，无需配置复杂的防火墙规则，一行命令即可“梭哈”。
* **🛡️ 极致伪装**：自动配置 `www.visa.com.sg` 等高信誉域名作为连接伪装（SNI/Host 分离技术），有效防止主动探测。
* **🛠 多协议支持**：灵活选择 **VMess** 或 **VLESS** 协议，满足不同客户端需求。
* **🌍 全架构兼容**：完美支持 `x86_64` (AMD64), `arm64` (Mac M1/VPS), `armv7` 等多种 CPU 架构。
* **🚀 智能优选**：内置 Argo 隧道优选逻辑，自动寻找最佳 Cloudflare 接入点。


---

## ⚠️ 免责声明

本免责声明适用于 GitHub 上的 “Agro-suoha” 项目（以下简称“本项目”）。

### 用途
本项目仅供教育、研究和安全测试目的而设计和开发。旨在为安全研究人员、学术界人士及技术爱好者提供一个探索和实践网络通信技术的工具。

### 合法性
在下载和使用本项目代码时，必须遵守使用者所适用的法律和规定。使用者有责任确保其行为符合所在地区的法律框架、规章制度及其他相关规定。

### 免责
作为本项目的二次开发作者（以下简称“作者”），我 tt 强调本项目仅应用于合法、道德和教育目的。  
作者不认可、不支持亦不鼓励任何形式的非法使用。如果发现本项目被用于任何非法或不道德的活动，作者将对此强烈谴责。  
作者对任何人或组织利用本项目代码从事的任何非法活动不承担责任。使用本项目代码所产生的任何后果，均由使用者自行承担。  
作者不对使用

