# 案例：yarbo 卡在 3.13，云端说 job 早就派了 3.14.41.0

一次真实现场排查的完整证据链。**结论先行：下载是成功的，job 也派到了，是 `ota_progress`
在等一条永远没来的 MQTT 消息，于是无限 defer。**

## 现场描述

- 设备能 SSH，Greengrass 正常跑，组件都在工作
- 云端 App 显示有 3.14.41.0 的更新，但设备版本一直是 3.13.11.3
- 报障人的判断是"greengrass 日志能确定没下载最新版"

## 阶段 1：先证伪"没下载"

这一步是本案例最省时间的一步。查 artifact 落盘情况：

```bash
sudo ls -la /greengrass/v2/packages/artifacts/yarbo/
#  3.13.8.4     3.13.11.3     3.14.41.0    ← 新版本已经在位，mtime 就是刚才
sudo ls -la /greengrass/v2/packages/artifacts/yarbo/3.14.41.0/
#  docker_pkg.zip   2.6 KB
#  docker_upgrade.zip 8.0 MB
#  yarbo_device.zip  37.7 MB      ← 旧包 3.13.11.3 是 121 MB，巨大差异
```

37MB vs 121MB 第一眼很可疑，于是验证完整性：

```bash
sudo unzip -t yarbo_device.zip
#   testing: 3.14.41.0.patch    OK
#   testing: ZipPatch           OK
#   No errors detected in compressed data
```

**是差分包**，不是截断。而且 `artifacts-unarchived/` 里也已经解开好了
（`docker_pkg/` / `docker_upgrade/` / `yarbo_device/` 三个目录齐全）。
→ **"没下载"这个假设被证伪**，方向必须换。

## 阶段 2：从线程栈拿到精确阻塞点

`greengrass.log` 里部署相关的最后一条日志是：

```
BootstrapManager: Found a list of bootstrap tasks in dependency order.
{list=[aws.greengrass.Nucleus, aws.greengrass.Cli, aws.greengrass.LogManager]}
```

之后 37 分钟**零输出**。抓线程栈：

```bash
sudo jcmd <nucleus_pid> Thread.print
```

```
"pool-3-thread-4" ... java.lang.Thread.State: WAITING (parking)
    at java.util.concurrent.CompletableFuture.waitingGet(...)
    at com.aws.greengrass.deployment.DefaultDeploymentTask.call(DefaultDeploymentTask.java:225)
```

反编译确认 225 行是什么（`javap -p -c -l` 拿 LineNumberTable + LocalVariableTable）：

```java
Future<DeploymentResult> f = deploymentConfigMerger.mergeInNewConfig(deployment, newConfig, ts);
DeploymentResult r = f.get();        // ← 行 225，卡在这里
```

再看 `mergeInNewConfig` 的字节码，发现它在部署策略是 `NOTIFY_COMPONENTS` 时**根本不执行**，
只是注册一个 `UpdateAction` 给 `UpdateSystemPolicyService`，然后返回一个 Future：

```
if (componentUpdatePolicyAction == NOTIFY_COMPONENTS) {
    updateSystemPolicyService.addUpdateAction(deploymentId,
        new UpdateAction(deploymentId, ggcRestart, timeout, () -> updateActionForDeployment(...)));
} else {
    executorService.execute(() -> updateActionForDeployment(...));
}
return totallyCompleteFuture;      // 谁来 complete 它？→ UpdateSystemPolicyService
```

→ **部署线程在等一个只有 UpdateSystemPolicyService 才会完成的 Future。**

## 阶段 3：定位 defer 的源头

`UpdateSystemPolicyService.startup()` 的循环（字节码还原）：

```java
while (!getState().equals(State.FINISHED)) {
    synchronized (pendingActions) { while (pendingActions.isEmpty()) pendingActions.wait(10000); }

    List<Future<DeferComponentUpdateRequest>> futures =
        lifecycleIPCAgent.sendPreComponentUpdateEvent(event);      // 发 PreComponentUpdate
    long waitTime = getTimeToReCheck(getMaxTimeoutInMillis(), deploymentId, futures);
    if (waitTime > 0) {
        Thread.sleep(waitTime);        // ← 只要有人 defer，睡完再来一轮
    } else {
        lifecycleIPCAgent.discardDeferComponentUpdateFutures();
        executor.submit(() -> runUpdateActions(deploymentId)).get();   // ← 真正执行的唯一出口
    }
}
```

`getTimeToReCheck()` 里就是那条日志：

```java
if (req.getDeploymentId().equals(deploymentId)) {
    long t = now + req.getRecheckAfterMs();
    if (t > maxTimeToReCheck) {
        maxTimeToReCheck = t;
        logger.atInfo().kv("...", ...)
              .log("deferred for {} millis with message {}", req.getRecheckAfterMs(), req.getMessage());
    }
}
```

**`timeout`（部署文档里是 60s）只约束单轮循环**：60 秒到了就返回一个负数 → 但那只让
`getTimeToReCheck` 返回 ≤0，外层 `while` 立刻又发一轮 `PreComponentUpdate`，组件再 defer 一次。
**没有任何终止条件。**

那谁在 defer？先看谁有权限、谁用这个 API：

```bash
sudo grep -rla "SubscribeToComponentUpdates" /greengrass/v2/packages/
#  aws.greengrass.SecureTunneling/...-all.jar
#  ota_progress/1.2.41/ota_progress/progress.py        ← 是它
#  ota_progress/1.2.33.1/ota_progress/progress.py
sudo grep -a "delay debug defer" /greengrass/v2/logs/ota_progress.log | tail -2
#  21:52:43  delay debug defer: 10000
```

`ota_progress` 的判定链（`progress.py`）：

```python
def is_deployment_allowed(self):
    defer = _check_deployment_deferred(verbose=True)
    if defer is None: return 1     # 强制放行
    if defer:         return 0     # 延迟部署生效
    return self.db_confirm_update()   # ← 走到这里

def db_confirm_update(self):
    result = cursor.fetchone()      # SELECT action_, timezone, min_version, update_version, status
    ...
    if status != UpdateStatus.WAITING_FOR_UPDATE: return 1
    if is_v1_greater(min_version, update_version): return 1
    if not action:
        print("No action found in database")
        return 0                    # ← 不允许更新
```

日志完美对上：

```
延迟部署未生效：允许内容 1                                    ← 门禁文件 DEPLOY_ALLOWED = "1"，没拦
db query result: ('', 0, '', '3.14.41.0', 'WAITING_FOR_UPDATE')  ← action_ 是 ''
No action found in database.
delay debug defer: 10000
```

## 阶段 4：为什么 `action_` 是空的

`action_` 只有一个写入点：

```python
if topic.endswith('/app/set_ota_config'):
    d_id, state, tz = response.get("deployment_id"), response.get("state"), response.get("timezone")
    update_db_from_response(d_id, ActionStatus.get_status(state), tz)
```

也就是云端/App 要往 `snowbot/<SN>/app/set_ota_config` 发一条带 `state` 的消息
（`state` 1=立即 / 2=稍后 / 3=下次）。

查日志证明**从来没收到过**：

```bash
sudo grep -c "Attempting to subscribe to topic: .*set_ota_config" /greengrass/v2/logs/ota_progress.log*
#   2       ← 订阅是成功的
sudo grep -c "Processing action" /greengrass/v2/logs/ota_progress.log*
#   0       ← 一条更新动作都没收到
```

DB 实物（`/userdata/updates_db/updates.db`）：

```
id=5 | deployment_id=3eb49626-... | action_=''          | 3.14.41.0   | WAITING_FOR_UPDATE   ← 这次
id=4 | deployment_id=ba97036c-... | action_='immediate' | 3.13.11.3   | DONE                ← 上一次成功的
```

→ **这次的 job 派到了、包也下了，但云端没跟着发 `set_ota_config`，于是设备端永远"不允许更新"。**

## 阶段 5：放行，验证整条链路

按 L2（改库）放行，因为要立刻验证 A 的逻辑是否通：

```bash
sudo cp -a /userdata/updates_db/updates.db /userdata/updates_db/updates.db.bak.$(date +%Y%m%d_%H%M%S)
sudo sqlite3 /userdata/updates_db/updates.db \
  "UPDATE ota SET action_='immediate' WHERE id=5;"
```

12 秒内日志转向：

```
21:54:55  db query result: ('immediate', 0, '', '3.14.41.0', 'WAITING_FOR_UPDATE')
21:54:55  update immediate
21:54:55  delay debug defer 0
21:54:55  Acknowledged update for deployment 3eb49626-...
21:54:56  📊 Progress 1.0% sent successfully
21:54:58  ota_progress: Run script exited (exitCode=143)      ← 被部署停掉准备升级
```

Greengrass 侧随即正常推进：

```
21:55:00  Bootstrap task list is saved to file
21:55:00  Nucleus restart requested to complete bootstrap task
21:55:33  Execute component bootstrap step: aws.greengrass.Cli
21:55:34  Execute component bootstrap step: aws.greengrass.LogManager
21:55:35  Completed all bootstrap tasks. Continue to activate deployment changes
21:55:37  KernelLifecycle: system-start. Launch Nucleus. ... version=2.17.0
21:55:40  Nucleus update workflow waiting for services to complete update
```

之后设备**整机重启、掉网约 14 分钟**（ping 不通，ARP 是 `(incomplete)`），回来后确认：

```bash
sudo /greengrass/v2/bin/greengrass-cli -V     # 2.17.0
sudo readlink -f /greengrass/v2/alts/current/distro
#  /userdata/greengrass/v2/packages/artifacts-unarchived/aws.greengrass.Nucleus/2.17.0/aws.greengrass.nucleus
sudo ls -l /greengrass/v2/deployments/
#  previous-success -> .../3eb49626-...        ← 部署成功，ongoing 已消失
```

`effectiveConfig.yaml` 里目标版本全部到位：`yarbo 3.14.41.0`、`yarbo-baseline 3.13.31`、
`ota_progress 1.2.41`、`installer 1.3.42.3`、`aws.greengrass.Nucleus 2.17.0`，
外加 7 个首次安装的新组件。

## 失败假设（下次少走弯路的记录）

| 当时的假设 | 实际 |
|---|---|
| "greengrass 日志能确定没下载最新版" | **错**。包 37 分钟前就下完并校验通过了；只是差分包体积小容易误判 |
| "是不是磁盘满了 / S3 拉不动" | 错。`/userdata` 用了 36%，23G 可用 |
| "job 派发了但设备没领" | 错。`Added the job to the queue` + 上报 `IN_PROGRESS` 都正常 |
| "等一等，Greengrass 有 60s timeout，应该会回滚" | **错**。timeout 只约束单轮；外层 while 无终止条件，永不回滚 |
| "卡在 bootstrap 执行阶段" | 部分错。日志最后一句确实在 bootstrap 附近，但线程栈证明它卡在 `future.get()`，连 bootstrap 都没开始跑 |
| "升级 ota_progress 到新版应该就修好了" | **错**。1.2.31.1/1.2.33.1/1.2.41 的 `if not action: return 0` 三份代码一模一样 |

## 遗留问题（要改代码，不是改设备）

1. **云端**：派发 Greengrass job 后必须确保 follow-up 下发 `set_ota_config`。
   现在两个系统的时序完全解耦，云端漏发就永久卡死，且**没有任何告警面**。
2. **`ota_progress`**：`action_` 为空时不要无限 defer。应该加超时兜底
   （超过 N 分钟按立即处理，或主动 cancel-job-execution 把 job 标记失败），
   让它在云图上表现为"失败"而不是"永远进行中"。
3. **可观测性**：`service-update-deferred` 只打 INFO 且不带组件名，
   现场根本看不出是谁在 defer。这条日志至少要 `kv("componentName", ...)`。
