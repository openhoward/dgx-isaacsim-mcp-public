---
name: franka-motion
description: 在 Isaac Sim 裡執行預先定義的機器手臂動作示範，給人即時觀看（WebRTC 串流）。當使用者說「執行 <任務名稱>」、「跑關節掃描」、「做增益對比」、「列出可用的任務」、「用 <機器人> 執行 <任務>」時使用。任務定義放在 sweeptask/ 目錄，每個一個檔案。適用任何有 articulation 的手臂，不限 Franka。
---

# 手臂動作示範

透過 `isaacsim` MCP 工具在 Isaac Sim 裡驅動機器手臂，執行 `sweeptask/` 底下定義的任務。

## 怎麼選任務

使用者說「執行 X」時，讀 `sweeptask/X.md`。找不到就列出 `sweeptask/` 裡有哪些檔案請他選，
**不要自己編一個任務出來**。

使用者只說「跑個示範」而沒指定，先列清單問他要哪一個。

## 怎麼選機器人

機器人是**執行時參數**，不是寫死在任務檔裡的。

- 使用者說「用 UR10 執行 joint_sweep」→ 機器人是 UR10
- 使用者沒指定 → 用 `frankapanda`

拿到名稱後先 `list_available_robots` 確認資產庫裡有沒有（`create_robot` 支援模糊比對）。
找不到就把相近的選項列給使用者，**不要隨便挑一台代替**。

`prim_path` 用 `/World/<機器人 key>`。

## 執行前一定要做的事

這幾條每一條都對應一個會安靜給錯答案的失效模式，不要跳過。

### 1. 清場前先 `stop_simulation`

時間軸還在跑的時候刪除 prim，physics view 會變成孤兒，而系統拒絕在時間軸活著時重建它。
之後每一次讀取都會退回 `drive_targets`，誤差印出漂亮的 0.0000，**但機器人根本沒動**。

### 2. 讀取後檢查 `position_source`

`get_joint_positions` 的回應帶這個欄位：

- `physics` — 真的量到的位置，可以用
- `drive_targets` — 讀到的是你剛寫進去的指令回聲

**看到 `drive_targets` 就停下來回報使用者，不要繼續跑完整套動作。**
那代表物理視圖沒接上，接下來所有的「誤差」都是假的。

### 3. 展示用 `play_simulation`，不要用 `step_simulation`

`step_simulation` 推進物理但不觸發畫面更新，串流上會一格一格跳。而且時間軸在播放時
呼叫 `step_simulation` 會直接報錯。

例外：使用者明講要精確控制步數的除錯情境，那才用 step，而且要先確認時間軸是停的。

### 4. 單位

- revolute 關節：**弧度**
- prismatic 關節（夾爪、滑軌）：**公尺**

`get_robot_info` 的 `joint_limits` 每一筆都自帶 `units` 欄位。**同一個回應裡兩種單位
並存是正常的**，照每一筆自己的 `units` 走。不要自己換算成角度，也不要假設所有關節同單位。

### 5. 關節順序與完整姿勢

`get_robot_info` 回傳的 `joint_names` 順序**就是** `set_joint_positions` 的索引順序。
不要用別的順序，也不要假設某一類關節排在前面。

`set_joint_positions` 要送**完整的一整組值**，長度等於 `get_robot_info` 回傳的 `num_dof`。
只想動一個關節時，其餘的填目前的 home 值。

**不要假設 DOF 數**。Franka Panda 是 9，UR 系列是 6，別的機器人又不一樣。每次都讀。

### 6. 目標一律夾在極限內，而且限制絕對幅度

每個目標都要夾進該關節的 `lower` / `upper`。超出極限的指令不會被拒絕，
機器人會撞上停止點。

**光是夾在極限內還不夠。** 有些機器人的關節極限非常寬（UR 的手腕常常是 ±2π），
「行程的 25%」在那種關節上是接近半圈的猛甩。任務檔給的幅度比例要再套一個絕對上限，
預設 **1.0 弧度**（prismatic 則是行程的 100%，因為那本來就很短）。

## 標準流程

1. `stop_simulation`
2. `delete_object` 清掉上一次的機器人 prim、`/PhysicsScene`、`/World/groundPlane`
   （不存在就略過，不算錯誤）
3. `create_physics_scene`
4. `create_robot` — 用使用者指定的機器人
5. `get_robot_info` — 取得 `joint_names`、`num_dof`、`joint_limits`，把順序列給使用者。
   **`num_dof` 是 0 就停下來**：那代表資產沒解析成功，回應裡會有警告說明。
6. `play_simulation`
7. `get_joint_positions` 記下 home 姿勢，**檢查 `position_source`**（見上方第 2 條）
8. 照任務檔的內容執行
9. 回到完整 home 姿勢
10. `stop_simulation`（會回到 spawn 姿勢）
11. 給使用者一張表：關節名稱、指令值、實際值、誤差、`position_source`

任務檔可以覆寫第 4 到第 8 步，但**第 1、2、5、7 步不可跳過**。

## 回報

每個姿勢送出後讀回實際值並回報誤差。合理的誤差在 0.01 ～ 0.5 弧度之間，
取決於你下一個指令來得多快。

**整排 0.0000 是警訊不是好消息** —— 檢查 `position_source`。

## 可用的任務

執行 `sweeptask/` 目錄列表來看目前有哪些。目前包含：

| 名稱 | 用途 | 前提 |
|---|---|---|
| `joint_sweep` | revolute 關節逐一動作，最基本的可視化檢查 | 任何手臂 |
| `gain_compare` | 同一目標、兩種 drive 增益，展示 `set_drive_params` | 任何手臂 |
| `grip_cycle` | 夾爪開合，驗證 prismatic 的公尺單位 | **需要 prismatic 關節** |

前提不符時直接回報使用者，**不要硬跑**。

## 新增一個任務

在 `sweeptask/` 放一個新的 `.md`，照 `sweeptask/README.md` 的格式寫，
然後重新 `nemoclaw <sandbox> skill install`。不需要改這個檔案，也不需要寫任何程式。

**新增一台機器人不需要任何檔案** —— 直接在 prompt 裡指定就好。
