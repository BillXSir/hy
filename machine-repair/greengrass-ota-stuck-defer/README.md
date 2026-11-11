# Greengrass 部署"永久 defer"死锁

AWS IoT job 明明已经派发，`greengrass.log` 里 `service-update-deferred` 每十几秒刷一条，
可是组件版本永远不动，job 一直挂在 `IN_PROGRESS`。**包早就下完了，是设备自己在无限推迟。**

## 症状指纹

三条同时成立，基本可以判定是这个问题：

> 1. `greengrass.log` 里 `service-update-deferred. deferred for 10000 millis with message null` **周期性重复**（每 10~12s 一条，能刷几百条）
> 2. `/userdata/greengrass/v2/deployments/ongoing` 存在但**长时间不消失**
> 3. `packages/artifacts/` 里目标版本的包**已经在位**（下载早就完成了）

```
$ sudo grep -c service-update-deferred /greengrass/v2/logs/greengrass.log
234

$ sudo ls -l /greengrass/v2/deployments/ongoing
ongoing -> /userdata/greengrass/v2/deployments/3eb49626-...   # 37 分钟没动过

$ sudo ls /greengrass/v2/packages/artifacts/yarbo/
3.13.11.3  3.13.8.4  3.14.41.0      # 新包已经在位，而且校验通过
```

**对照**：如果 `artifacts/` 里**没有**目标版本，那是下载/网络问题，不是本问题 —— 先查 S3 连通性和磁盘。

## 一键操作（安全模式）

```bash
sudo ./ota-stuck-defer.sh               # 只读：采集 → 判定 → 给结论
```

**安全边界**（"可以放心无脑跑"的前提）：

| 允许 | 禁止 |
|---|---|
| 读 `greengrass.log` / `effectiveConfig.yaml` / `deployments/` | 写任何 Greengrass 文件 |
| 只读方式查 ota sqlite（`mode=ro`） | 不开机自愈、不装 systemd 服务 |
| 读门禁文件（`DEPLOY_ALLOWED` 等） | 不重启、不动组件 |
| 默认模式**一个字节都不写** | 不动固件 / 不碰 docker |

唯一的写动作藏在显式参数后面，且**写前自动备份**到 `/var/backups/ota-stuck-defer/`：

```bash
sudo ./ota-stuck-defer.sh --diagnose                     # 纯只读（同默认）
sudo ./ota-stuck-defer.sh --allow --deployment-id <id>   # 放行这次部署（改 sqlite）
sudo ./ota-stuck-defer.sh --allow-force                  # 写 DEPLOY_ALLOWED=999 强制放行
sudo ./ota-stuck-defer.sh --restore                      # 还原最近一次 DB 备份
sudo ./ota-stuck-defer.sh --watch                        # 放行后前台跟日志
sudo ./ota-stuck-defer.sh --mqtt                         # 只打印"该发的 MQTT 报文"
sudo ./ota-stuck-defer.sh --snapshot                     # 单行机器可读现状（deploy-remote 用）
# 通用: --quiet  --no-color
```

脚本对路径做了环境变量覆盖，便于自测或非标准安装：
`GG_ROOT` / `OTA_DB` / `ALLOW_FILE` / `DENY_FILE` / `CAM_STATE` / `BACKUP_DIR`。

> 判定逻辑已在离线 fixture 上跑过四种 verdict（`OK` / `IN_PROGRESS` / `DEFER_DEADLOCK` / `GATED`），
> 以及 `--allow` → 自动备份 → `--restore` 的闭环。真机放行请配合 `--watch` 确认。

## 因果链（这是这个问题的全部价值）

问题**不在** Greengrass 本身，是 Yarbo 栈上 `ota_progress` 组件的一个"永久等待"设计。

```
AWS IoT job 派发
   ↓ 设备领取，上报 IN_PROGRESS
下载 artifact  ← 这一步是成功的，且校验通过
   ↓
DeploymentConfigMerger.mergeInNewConfig()
   ↓ 部署策略 NOTIFY_COMPONENTS → 不自己执行，注册成 UpdateAction
   ↓ 交给 UpdateSystemPolicyService，返回一个 Future
DefaultDeploymentTask.call() → future.get()   ← 部署线程阻塞在这里
   ↓
UpdateSystemPolicyService.startup()
   while (state != FINISHED) {
       发 PreComponentUpdateEvent → 组件回 deferComponentUpdate(recheck=10000)
       打日志 service-update-deferred
       sleep(10000)          ← timeout 只约束"单轮"，外层 while 永不退出
   }
   ↓
ota_progress.is_deployment_allowed()
   ↓ _check_deployment_deferred() = False（DEPLOY_ALLOWED 内容合法，窗口没挡）
   ↓ db_confirm_update() 查 /userdata/updates_db/updates.db 的 ota 表
   ↓ action_ 是空字符串
   ↓   if not action: return 0      ← 不允许更新
   ↓ defer_update() 每 10s 一次
```

**关键两点**：

1. `action_` 唯一的写入来源是 MQTT 下发：`snowbot/<SN>/app/set_ota_config`
   （`state` 1=立即 / 2=稍后 / 3=下次）。云端派了 job 却**没发这条消息**，就会永久卡死。
2. Greengrass 这个 loop **不会超时回滚**：不失败、不重试、不放弃，job 永远 `IN_PROGRESS`。所以从云图上看只是"迟迟不更新"，没有任何报错可循。

实测证据（`ota_progress.log`）：

```
延迟部署未生效：允许内容 1                                    ← 门禁没挡
db query result: ('', 0, '', '3.14.41.0', 'WAITING_FOR_UPDATE') ← action_ 是空的
No action found in database.                                  ← 落进 return 0
delay debug defer: 10000                                      ← 推迟 10 秒
```

## 判定表

| verdict | 含义 | 下一步 |
|---|---|---|
| `OK` | 没卡住的部署，也没 defer 风暴 | 问题不在本机：先确认 IoT job 真派到了这台 thing |
| `IN_PROGRESS` | 有 ongoing 但没风暴 | 正常在跑，`--watch` 等它；长时间无进展再复诊 |
| `DEFER_DEADLOCK` | 有 ongoing + defer 风暴 | 走下面的"放行三层" |
| `GATED` | 被门禁文件挡住 | 先确认那几个文件是否该存在，再谈放行 |

## 放行三层（按代价从低到高）

| 层 | 操作 | 评价 |
|---|---|---|
| **L1 云端/App** | 往 `snowbot/<SN>/app/set_ota_config` 发 `{"deployment_id":"<id>","state":1,"timezone":0}` | **正规做法，优先**。治的是触发点 |
| **L2 改库** | `UPDATE ota SET action_='immediate' WHERE deployment_id='<id>'` | 设备侧最快验证；脚本 `--allow` 就是这个，自动备份 |
| **L3 强制** | `echo 999 > /home/firefly/.ros/DEPLOY_ALLOWED` | 绕过 DB 判定，最粗暴；脚本 `--allow-force` |

L2 生效后 12 秒内就能看到日志转向：

```
update immediate
delay debug defer 0
Acknowledged update for deployment <id>
```

> ⚠️ 放行 = **真的开始 OTA**。Yarbo 栈上一轮通常包含 Nucleus 升级 + 十几个组件 + 整机重启，
> 机器人正在干活时别放。

## 验证成功的标志

```bash
# 1. ongoing 消失，previous-success 指向这次部署
sudo ls -l /greengrass/v2/deployments/
#   previous-success -> /userdata/greengrass/v2/deployments/<这次部署 id>
#   （ongoing 链接已不在）

# 2. 版本真的变了
sudo /greengrass/v2/bin/greengrass-cli -V            # Nucleus 版本
sudo awk '/^  yarbo:$/{f=1;next} f&&/^    version:/{print;exit}' \
        /greengrass/v2/config/effectiveConfig.yaml

# 3. ota 表置为 DONE
sudo sqlite3 /userdata/updates_db/updates.db \
  "SELECT id,action_,update_version,status FROM ota ORDER BY id DESC LIMIT 3;"
#   ... | immediate | 3.14.41.0 | DONE
```

> `greengrass-cli` 在部署高峰期会 `Unable to create ipc client (TimeoutException)`，
> **别拿它当唯一判据** —— 直接读 `effectiveConfig.yaml` 最稳。

## 回滚

```bash
sudo ./ota-stuck-defer.sh --restore        # 还原最近一次 ota DB 备份
# 或手工:
sudo cp -a /var/backups/ota-stuck-defer/updates.db.<时间戳> /userdata/updates_db/updates.db
printf '1' | sudo tee /home/firefly/.ros/DEPLOY_ALLOWED    # L3 的回滚
```

注意：`--restore` 只能还原**数据库**。一旦部署已经 `Acknowledged` 并开始执行，
回滚 DB 拦不住它（那时该用 Greengrass 自己的 deployment rollback）。

## 平台注意事项

这几条是在 Yarbo（Rockchip / 内核 6.1 / Greengrass 2.15→2.17）上踩出来的。

### 1. 部署线程卡在哪，用线程栈直接看，别猜

```bash
sudo jcmd <nucleus_pid> Thread.print | grep -A12 'pool-3-thread'
#   at com.aws.greengrass.deployment.DefaultDeploymentTask.call(DefaultDeploymentTask.java:225)
#   → 就是 future.get()，等 DeploymentConfigMerger 那个永远不会完成的 Future
```

本机有 JDK（`jcmd` / `javap` / `jstack`），可以继续往下挖到具体行号：

```bash
cd /tmp && sudo mkdir -p ggjar && \
  sudo unzip -o -q /greengrass/v2/alts/current/distro/lib/Greengrass.jar \
       "com/aws/greengrass/deployment/*" "com/aws/greengrass/lifecyclemanager/Update*" -d /tmp/ggjar
sudo javap -p -c -l /tmp/ggjar/com/aws/greengrass/deployment/DeploymentConfigMerger.class
```

### 2. 日志里"最后一句话"就是卡住的位置

`greengrass.log` 的**最后一条**部署相关日志，往往正好是阻塞点：

| 最后一条日志 | 含义 |
|---|---|
| `Found a list of bootstrap tasks in dependency order` | 已进入 activator 选择，随后交给 UpdateSystemPolicyService → 查 defer |
| `Bootstrap task list is saved to file` + `Nucleus restart requested` | 正常：Nucleus 升级要重启续跑 |
| `Nucleus update workflow waiting for services to complete update` | 正常：在逐个等组件 |
| 长时间完全无输出 | 回去看 `ota_progress.log` / 组件自己的日志 |

### 3. Nucleus 升级 = 内核重启 + 大概率整机重启，设备会掉网

`bootstrap` 脚本以 `exit 100` 结束表示"需要重启"，然后
`Nucleus restart requested to complete bootstrap task` → 新 Nucleus 起来接着跑。
之后 `installer` / `system_updater` 之类还可能再重启整机。

所以**远程操作必须容忍掉网**：这次实测设备离线约 14 分钟，SSH/ping 全无响应，
ARP 都是 `(incomplete)`。别以为它变砖了，轮询等回来即可。

### 4. `thingName` 就是 SN，注意脱敏

`effectiveConfig.yaml` 里的 `thingName` 是设备序列号，写文档/贴日志前记得打码。
MQTT topic 里也带它（`snowbot/<SN>/app/set_ota_config`）。

### 5. 装完新版也治不了根

`ota_progress` 从 **1.2.31.1 → 1.2.33.1 → 1.2.41** 这段 `db_confirm_update()` 逻辑**一模一样**：

```python
if not action:
    print("No action found in database")
    return 0        # 不允许更新
```

也就是说升级组件本身不解决问题。真正要改的是这里加超时兜底（例如超过 N 分钟仍未收到
动作就按立即处理或把 job 标记失败），以及云端保证"派 job 必跟 `set_ota_config`"。

## 误判清单

| 现象 | 不要下的结论 |
|---|---|
| `yarbo_device.zip` 只有 37MB，旧包 116MB | **不是没下完**。新版是差分包（内含 `*.patch` + `ZipPatch`），`unzip -t` 通过就是完整的 |
| `deployments/ongoing` 里有 `deployment_metadata.json` | 不代表部署在推进 —— 可能从创建起就再没变过（看 mtime） |
| `deployments/ongoing` 里没有 `rollback_snapshot.tlog` | 不代表回滚坏了；它还没走到写快照那一步 |
| 云图上 job 一直 `IN_PROGRESS` | 不是"云端没超时处理"，是设备每 10s 主动续着，云端看到的永远是活的 |
| 组件 `State: FINISHED` | 不等于组件挂了；Greengrass 里常规进程正常退出就是 `FINISHED`，`ERRORED` 才是异常 |
| `greengrass-cli` 报 `Unable to create ipc client` | 高峰期 IPC 握手超时，不代表 greengrass 坏了；改用读文件 |
| `service-update-deferred` 反复出现 | 不要以为"它在重试，等等就好" —— 这个 loop 没有终止条件 |
