# Kubernetes Cluster Deployment (1 Master + 2 Workers)

這個 Ansible playbook 用於在 Ubuntu Server 上部署 Kubernetes 1.33 叢集，包含 1 個 Master 節點和 2 個 Worker 節點。

## 系統需求

- Ubuntu Server 20.04/22.04/24.04 LTS
- 所有節點需要預先設定固定 IP 和 hostname
- SSH 免密登入已設定
- Ansible 控制節點已安裝 Ansible

## 檔案結構

```
.
├── inventory.ini                           # Ansible inventory 檔案
├── site.yml                              # 主要 playbook
├── tasks/
│   ├── common.yml                         # 通用設定 (時區、時間同步、網路等)
│   ├── containerd.yml                     # containerd 容器運行時安裝
│   ├── kubernetes.yml                     # Kubernetes 套件安裝
│   ├── master.yml                         # Master 節點初始化
│   └── worker.yml                         # Worker 節點加入叢集
├── templates/
│   └── kubeadm-init-config.yaml.j2       # kubeadm 初始化設定模板
└── README.md                             # 說明文件
```

## 設定檔說明

### inventory.ini

修改以下項目以符合您的環境：

- `ansible_host`: 各節點的 IP 位址
- `hostname`: 各節點的主機名稱
- `ansible_user`: SSH 登入使用者
- `ansible_ssh_private_key_file`: SSH 私鑰路徑
- `ansible_become_pass`: sudo 密碼
- `control_plane_endpoint`: Master 節點的 API Server 端點

## 部署步驟

### 1. 前置準備

確保所有節點：
- 已設定固定 IP 位址
- 已設定唯一的 hostname
- SSH 服務已啟動
- 可以從 Ansible 控制節點透過 SSH 連線

### 2. 安裝 Ansible 依賴

在 Ansible 控制節點安裝必要的 collection：

```bash
ansible-galaxy collection install kubernetes.core
```

### 3. 驗證連線

測試 Ansible 是否能連線到所有節點：

```bash
ansible -i inventory.ini all -m ping
```

### 4. 執行部署

執行完整的叢集部署：

```bash
ansible-playbook -i inventory.ini site.yml
```

### 5. 驗證部署

部署完成後，在 Master 節點執行：

```bash
kubectl get nodes -o wide
kubectl get pods -A
```

## 部署內容

此 playbook 將會執行以下動作：

### 所有節點 (common.yml)
- 設定台灣時區 (Asia/Taipei)
- 安裝並設定 chrony 時間同步服務
- 關閉 swap 分割區
- 載入必要的核心模組 (overlay, br_netfilter)
- 設定 sysctl 參數以支援 Kubernetes

### 容器運行時 (containerd.yml)
- 下載並安裝 containerd 2.1.4
- 下載並安裝 runc 1.3.0
- 下載並安裝 CNI plugins
- 設定 containerd 使用 systemd cgroup driver
- 設定 crictl 組態

### Kubernetes 套件 (kubernetes.yml)
- 新增 Kubernetes APT repository
- 安裝 kubelet, kubeadm (所有節點)
- 安裝 kubectl (僅 Master 節點)
- 鎖定套件版本避免自動更新

### Master 節點 (master.yml)
- 產生 kubeadm 初始化設定檔
- 初始化 Kubernetes 叢集
- 設定 kubectl 組態檔
- 部署 Canal CNI (Calico + Flannel)
- 產生 worker 節點加入指令

### Worker 節點 (worker.yml)
- 加入 Kubernetes 叢集
- 等待 kubelet 服務就緒

### 後續設定
- 為 Worker 節點加上適當的標籤
- 顯示最終的叢集狀態

## 叢集資訊

- **Kubernetes 版本**: 1.33
- **容器運行時**: containerd 2.1.4
- **CNI**: Canal (Calico v3.30.2 + Flannel)
- **Pod 網路**: 10.244.0.0/16
- **Service 網路**: 10.96.0.0/16

## 疑難排解

### 常見問題

1. **SSH 連線失敗**
   - 檢查 inventory.ini 中的 IP 位址和 SSH 設定
   - 確認 SSH 私鑰路徑正確

2. **sudo 權限問題**
   - 確認 `ansible_become_pass` 密碼正確
   - 確認使用者有 sudo 權限

3. **網路連線問題**
   - 檢查各節點間的網路連通性
   - 確認防火牆設定允許 Kubernetes 所需的連接埠

4. **kubeadm init 失敗**
   - 檢查 Master 節點的記憶體和 CPU 資源
   - 查看 `/var/log/pods/` 中的錯誤日誌

### 重新部署

如需重新部署，請在所有節點執行：

```bash
# 重置 kubeadm
sudo kubeadm reset -f

# 清理 iptables 規則
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X

# 清理網路介面
sudo ip link delete cni0 || true
sudo ip link delete flannel.1 || true
```

然後重新執行 ansible-playbook。

## 技術支援

如有問題，請檢查：
1. Ansible 執行日誌
2. 各節點的 systemd 服務狀態
3. Kubernetes 叢集事件：`kubectl get events --all-namespaces`