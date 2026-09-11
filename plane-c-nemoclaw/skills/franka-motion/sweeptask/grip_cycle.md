# grip_cycle

夾爪（或任何 prismatic 關節）開合三次。其餘關節全程不動。

用途是驗證 prismatic 那條路徑——它的單位、極限、驅動方式都跟 revolute 不一樣，
而且歷史上出過錯（目標值曾經被寫成 100 倍，讀回來卻看起來正常）。

## 前提

**需要至少一個 prismatic 關節。**

用 `get_robot_info` 檢查 `joint_limits` 裡有沒有 `type` 是 `prismatic` 的項目。

一個都沒有——UR 系列、以及大多數不含夾爪的手臂都是這樣——就直接回報使用者：

> 這台機器人沒有 prismatic 關節，`grip_cycle` 不適用。
> 可以改跑 `joint_sweep` 或 `gain_compare`。

**不要為了跑完而去找最接近的 revolute 關節替代。**

## 動作

只動 prismatic 關節，全部同步同值。其餘關節整個過程維持 home。

重複三次：

1. 全開：每個 prismatic 關節都設成它自己的 `upper`
2. 全關：每個 prismatic 關節都設成它自己的 `lower`

每個姿勢送出後讀回實際值。

各關節的 `upper` / `lower` 可能不同，**逐關節取自己的值**，不要拿第一個的套用到全部。

## 單位陷阱

prismatic 的單位是**公尺**，不是弧度。Franka 夾爪的 `0.04` 就是四公分，
是那個關節的整個行程。

`get_robot_info` 的 `joint_limits` 裡，prismatic 那幾筆的 `units` 是 `meters`，
revolute 那些是 `radians`。**同一個回應裡兩種單位並存是正常的**，
照每一筆自己的 `units` 走。

## 回報

每次開合的指令值、實際值、誤差。

**誤差要換算成行程百分比，不要只給絕對值。** prismatic 的行程通常只有幾公分，
數量級跟 revolute 完全不同——0.005 在 4 公分的夾爪上是行程的 12%，
放在手臂關節上根本看不出來。

## 觀看重點

有些夾爪的第二根指頭是 mimic joint，沒有自己的 drive，靠耦合跟著第一根動
（Franka Panda 的 `panda_finger_joint2` 就是）。

如果看到兩根指頭動得不一致，先用 `get_joint_config` 看那根有沒有被誰加上了 drive
（`drive_type` 不是 null 就是有）——那會跟原本的耦合打架。
