# joint_sweep

revolute 關節逐一動作，其餘維持 home。最基本的可視化檢查：
每個關節都動得了、動的是對的那一個、而且真的在追蹤目標。

## 前提

任何有 revolute 關節的手臂。

一個 revolute 關節都沒有就回報使用者這台不適用，不要硬跑。

## 動作

依 `joint_names` 的順序，只處理 **revolute** 關節，**跳過所有 prismatic 關節**
（夾爪、滑軌那些留給 `grip_cycle`）。

每個關節的幅度：

```
span      = upper - lower
amplitude = min(span × 0.25, 1.0)      # 1.0 弧度的絕對上限
```

那個上限不是裝飾。UR 的手腕關節極限常常是 ±2π，`span × 0.25` 會變成 3.1 弧度，
串流上看起來是手臂猛甩。

對第 i 個 revolute 關節，送兩個姿勢，每送一個就讀回實際值：

1. `home[i] + amplitude`，夾在該關節的 `lower` / `upper` 之內
2. 回到 `home[i]`

其餘所有關節在整個過程中維持 home 值。

全部做完之後送一次完整 home 姿勢。

## 回報

一張表，每列一個關節：關節名稱、指令值、實際值、誤差、`position_source`。

被跳過的 prismatic 關節也列出來，標明「已跳過（prismatic）」，
讓使用者知道不是漏掉了。

最後說明一句：這個順序就是 `set_joint_positions` 的索引順序，
也是 `get_robot_info` 回報的順序。

## 觀看重點

告訴使用者從基座往末端看。第一個關節通常是整支手臂繞底座旋轉，
越往末端的關節動作幅度看起來越小。

**如果動的順序看起來不對，那是真的有問題**，不是視角錯覺——
回報使用者並建議用 `get_joint_config` 對照關節名稱與實際位置。
