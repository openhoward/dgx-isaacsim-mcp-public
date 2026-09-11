# TODO — 讓 Agent 寫得了 DriveAPI / MassAPI / RigidBodyAPI

狀態：**未開始**。上游 repo 原始碼未被修改（`git status` 乾淨，branch `main`）。

## 問題

37 個透出工具裡，寫入類的只有這 13 個：

```
create_physics_scene  create_object       create_light    modify_light
create_robot          set_joint_positions create_camera   create_lidar
create_material       apply_material      import_urdf     set_physics_params
create_action_graph
```

**沒有一個能寫 USD 物理 schema 的 prim 屬性。**

- `set_joint_positions` 只下 ArticulationAction **目標值**，不動 drive 增益
- `set_physics_params` 只管**全域**（gravity / time step / GPU）
- `transform_object` 只動位姿

讀取側倒是齊全：`get_joint_config` 回傳 stiffness、damping、limits、position_error；
`get_physics_state` 回傳 rigid body 狀態與 mass（僅當 prim 帶 MassAPI）。

所以 `dfbot` joint1 的 Damping 53.0 / Stiffness 10000.0 / Max Force 30.0，
**Agent 讀得到、改不了**。唯一的寫入路徑是 `execute_script`，而那個在閘道被擋。

## 好消息：難的部分上游已經寫好

`adapters/v6.py` 的 `_set_joint_drive_targets()`（632–665 行）已經做完所有麻煩事：

```python
for desc in Usd.PrimRange(root_prim):
    if desc.IsA(UsdPhysics.RevoluteJoint) or desc.IsA(UsdPhysics.PrismaticJoint):
        joints.append(desc)
...
is_revolute = joint_prim.IsA(UsdPhysics.RevoluteJoint)
drive_type = "angular" if is_revolute else "linear"
drive = UsdPhysics.DriveAPI.Get(joint_prim, drive_type)
if not drive:
    drive = UsdPhysics.DriveAPI.Apply(joint_prim, drive_type)
drive.GetTargetPositionAttr().Set(...)          # ← 只差改這一行
```

遍歷、型別判斷、multiple-apply 的 instance name、Get/Apply 全都有了。

## 要改的四個位置

```
isaac.sim.mcp_extension/isaac_sim_mcp_extension/
  adapters/v6.py        新增 set_drive_params()（仿 _set_joint_drive_targets）
  adapters/v5.py        同上（只跑 6.0 可暫緩，但 base.py 宣告成抽象就得補）
  handlers/robots.py    registry["robots.set_drive"] = lambda **p: ...

isaac_mcp/tools/robots.py   @mcp.tool 定義 set_drive_params
```

`handlers/__init__.py` **不用動** —— 它只呼叫各子模組的 `register()`。

改完重啟：`systemctl --user restart isaacsim-mcp`

## 三個會咬人的地方

**1. 單位不是 MCP 層的慣例。** 上游那段的最後兩行透露了：

```python
drive.GetTargetPositionAttr().Set(float(np.degrees(value)))   # revolute → 度
drive.GetTargetPositionAttr().Set(float(value * 100.0))       # prismatic → 公分
```

MCP 層用弧度／公尺，**USD 屬性層是度／公分**。angular drive 的 stiffness 是「每度」。

決定：**採 USD 原生值，不換算**。GUI Property 面板顯示 10000.0，工具就吃 10000.0。
偷偷除以 57.3 會讓工具與 GUI 對不起來，那比不一致更難查。docstring 必須寫明。

**2. multiple-apply 寫錯 instance name 會靜默失敗。** 屬性寫進不存在的命名空間，
USD 不報錯也不生效。務必沿用 `IsA(RevoluteJoint)` 自動判斷 —— `dfbot` joint1 是
revolute（`angular`），但 Franka 的兩個夾爪手指是 prismatic（`linear`）。

**3. 用 `CreateXxxAttr()` 不要用 `GetXxxAttr()`。** 屬性不存在時 `Get` 回傳無效物件，
`Set` 就靜默失敗；`Create` 沒有的話會建。

## 一併值得做的

```
set_mass(prim_path, mass, density, center_of_mass)        → UsdPhysicsMassAPI
set_joint_limits(prim_path, lower, upper, break_force, break_torque)
apply_rigid_body(prim_path, enabled, kinematic)           → UsdPhysicsRigidBodyAPI
```

`dfbot` 的 Break Force / Torque 是 `3.4028e+38`（FLT_MAX，等於永不斷裂），
那也是 schema 屬性，同樣值得能從 Agent 調。

## 建議順序

1. `git checkout -b feat/set-drive-params`
2. 先在閘道（`app.py`）做一個能動的版本驗證語意與單位 —— 不用 fork、不用重啟 Isaac Sim
3. 確認無誤後移植到上游 adapter，開 PR
4. 上游合併後把閘道那個拿掉

驗收方式：用 Franka 跑 `get_joint_config` → `set_drive_params` → `get_joint_config`，
確認回報的數值真的改變（讀回值，不要只信寫入呼叫的回應）。

## 參考

- [UsdPhysicsDriveAPI](https://openusd.org/release/api/class_usd_physics_drive_a_p_i.html) — multiple-apply，instance name 為 `linear` / `angular` / `transX…rotZ`
- [Omniverse USD Python API](https://docs.omniverse.nvidia.com/usd/latest/technical_reference/python_api.html)
- 上游 repo：<https://github.com/whats2000/isaacsim-mcp-server>（維護活躍，commit 間隔以天計，值得開 feature request）

**不適用**的路徑（查證過）：

- `NVIDIA/skills` —— 500+ 個 skill 全是純文字提示檔，不能產生工具能力；且無任何 Isaac Sim / Omniverse / USD 相關 skill
- carb settings —— 應用程式組態層，管不到單一 prim 的屬性
