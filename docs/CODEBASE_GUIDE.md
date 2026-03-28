# BIT101-iOS 代码说明

这份文档对应当前 iOS 端的代码基线，目标不是重复代码，而是帮助后续维护时快速定位职责、数据流和扩展点。

## 总体结构

- `BIT101-iOS/BIT101-iOS/BIT101_iOSApp.swift`
  应用入口，只负责挂载根视图并应用全局主题。
- `BIT101-iOS/BIT101-iOS/ContentView.swift`
  根容器，目前直接进入登录流程。
- `BIT101-iOS/BIT101-iOS/Shell/AppShellView.swift`
  登录后的 tab 壳层，决定底部栏展示顺序、默认页和颜色。

当前底部栏默认结构为：

1. `日程`
2. `地图`
3. `话题`
4. `成绩`
5. `我的`

## 登录模块

- `BIT101-iOS/BIT101-iOS/Login/LoginViews.swift`
  登录界面、启动检查页和登录表单。
- `BIT101-iOS/BIT101-iOS/Login/LoginViewModel.swift`
  登录页状态机，管理启动检查、登录提交和退出登录。
- `BIT101-iOS/BIT101-iOS/Login/LoginService.swift`
  学校 CAS、BIT101 登录、Keychain 凭据和 fake-cookie 持久化。

登录链路分三段：

1. 学校统一身份认证页面拉取 salt 和 execution。
2. 学校登录成功后，补走一次 SSO 重定向链，保证学校 cookie 落地。
3. 调用 BIT101 的 `webvpn_verify_init -> webvpn_verify -> register(loginMode=true)` 拿到 `fake-cookie`。

## 日程模块

- `BIT101-iOS/BIT101-iOS/Schedule/ScheduleModels.swift`
  课表、考试、DDL、空教室、本地缓存和时间表模型。
- `BIT101-iOS/BIT101-iOS/Schedule/ScheduleService.swift`
  教务、乐学和空教室相关的网络请求与数据解析。
- `BIT101-iOS/BIT101-iOS/Schedule/ScheduleViewModel.swift`
  日程页状态机，本地缓存读写、同步入口和自定义数据 CRUD。
- `BIT101-iOS/BIT101-iOS/Schedule/ScheduleRootView.swift`
  课表 / DDL / 空教室三页的 SwiftUI 视图实现。

日程模块的数据优先级：

1. 先从本地缓存恢复，保证页面秒开。
2. 用户手动同步时再刷新远端数据。
3. 自定义课程和自定义 DDL 与远端数据混合展示，但保存在同一份缓存里。

## 成绩模块

- `BIT101-iOS/BIT101-iOS/Score/ScoreModels.swift`
  原生成绩页使用的数据模型和统计逻辑。
- `BIT101-iOS/BIT101-iOS/Score/ScoreService.swift`
  使用已保存的学号和统一认证密码直接请求成绩接口。
- `BIT101-iOS/BIT101-iOS/Score/ScoreRootView.swift`
  原生成绩查询页、筛选页和统计展示。

成绩模块的原则：

1. `成绩` tab 现在完全走原生查询页，不再依赖网页自动填充。
2. 成绩查询始终复用已保存的统一认证账号密码。
3. 学期与种类筛选均支持 `全选 / 全不选 / 0 选项`。

## 地图模块

- `BIT101-iOS/BIT101-iOS/Map/CampusMapScreen.swift`
  基于 `MapKit` 的地图页，加载自定义瓦片图层并支持校区快速跳转。

## 话题模块

- `BIT101-iOS/BIT101-iOS/Gallery/GalleryModels.swift`
  帖子流、搜索、用户和图片模型。
- `BIT101-iOS/BIT101-iOS/Gallery/CommunityModeration.swift`
  本地敏感词检测、隐藏规则和举报上报逻辑。
- `BIT101-iOS/BIT101-iOS/Gallery/GalleryComposerView.swift`
  原生发帖页和标签交互。
- `BIT101-iOS/BIT101-iOS/Gallery/GalleryService.swift`
  话题流和搜索接口请求。
- `BIT101-iOS/BIT101-iOS/Gallery/GalleryViewModel.swift`
  四个 feed 和搜索页的状态机，负责刷新、分页和取消态处理。
- `BIT101-iOS/BIT101-iOS/Gallery/GalleryRootView.swift`
  话题首页、帖子卡片、详情页、图片查看器。
- `BIT101-iOS/BIT101-iOS/Gallery/GalleryDebug.swift`
  仅在环境变量开启时输出调试日志。

话题页目前的关键设计：

- `关注 / 推荐 / 最新 / 最热` 通过轻扫手势切换，不再依赖 `TabView(.page)`。
- 搜索页首次打开会自动加载一组预览结果，行为向 Android 搜索页对齐。
- 图片点击与帖子点击分离，避免图片查看器和详情页抢手势。
- 刷新和分页要显式处理取消态，不能把 `cancelled` 误报成失败。
- 敏感词检测分两层：
  1. 发帖前本地校验。
  2. 服务端返回后、本地展示前再次过滤。
- 带 `bot / 机器人 / 通知 / 新闻` tag 的帖子会跳过本地自动屏蔽，但仍允许手动举报或隐藏。

## 我的模块

- `BIT101-iOS/BIT101-iOS/Mine/MineModels.swift`
  我的页需要的个人信息和分页状态模型。
- `BIT101-iOS/BIT101-iOS/Mine/MineService.swift`
  个人主页、粉丝、关注、我的帖子接口。
- `BIT101-iOS/BIT101-iOS/Mine/MineViewModel.swift`
  个人资料、粉丝、关注、帖子三个分页列表的状态机。
- `BIT101-iOS/BIT101-iOS/Mine/MineRootView.swift`
  我的页主界面和内部子页面。

我的页当前的约定：

1. “我的帖子”直接复用话题卡片和详情页实现，避免两套帖子 UI 分叉。
2. 设置入口不再只藏在右上角，而是直接平铺在“我的”页底部。

## 设置模块

- `BIT101-iOS/BIT101-iOS/Settings/AppSettingsStore.swift`
  全局设置存储，落地到 `UserDefaults`；账号相关设置会按学号隔离。
- `BIT101-iOS/BIT101-iOS/Settings/SettingsServices.swift`
  设置中心会复用的网络请求。
- `BIT101-iOS/BIT101-iOS/Settings/SettingsRootView.swift`
  设置首页和各个子设置页。

设置模块的约束：

- “我的”页和日程页进入的设置页，要尽量复用同一套菜单。
- 会影响运行时显示的设置，修改后应尽量立即反映到界面。

## 小组件与灵动岛

- `BIT101-iOS/BIT101-iOS/Schedule/ScheduleWidgetSupport.swift`
  主 App 向 App Group 共享容器导出精简课表快照。
- `BIT101-iOS/BIT101-iOS/Schedule/ScheduleLiveActivityManager.swift`
  根据当前账号的课表缓存与自定义日程，决定是否启动或更新课程提醒 Live Activity。
- `BIT101-iOS/BIT101ScheduleWidget/BIT101ScheduleWidget.swift`
  桌面课表 widget 与 Live Activity / Dynamic Island 的全部 UI。

这条链路当前的设计约束：

1. Widget 只读取共享容器里的精简课表快照，不直接访问主 App 的复杂缓存模型。
2. Live Activity 只展示“当前项 / 下一项”，并受“提前显示阈值”控制。
3. 灵动岛紧凑态优先展示高密度信息，例如 `上课/日程 + xx分`。
4. 小组件 deep link 统一走 `bit101://schedule/courses`，打开后落到“日程 -> 课表”。

## 账号隔离

当前以下数据已按账号隔离，不再在不同学号之间串用：

1. 课表 / DDL 本地缓存
2. 话题社区规则同意状态
3. 隐藏用户 / 隐藏帖子
4. 账号相关设置快照

## 地图模块补充

地图页当前不再暴露手动缩放倍率设置，默认按固定倍率展示，只保留：

1. 校区跳转
2. 回到我的位置
3. 系统原生的地图交互缩放

## 空教室模块补充

空教室筛选当前采用两种语义：

1. `一个节次都不选`
   等价于“当前空闲”。
2. `选中若干节次`
   采用“命中任一节次空闲即显示”的规则。

列表页当前只保留最核心信息：

1. 教室名称
2. 空闲时段

## 当前维护约定

- 复杂网络链路优先在 service 层加注释，而不是把视图层写成解释器。
- 状态机类文件优先说明“什么时候刷新”“什么时候恢复缓存”“为什么忽略取消错误”。
- 视图文件优先说明“页面层级”和“手势/路由/弹层”的关系。
- 新增模块时，先更新本文件，再补对应代码内的类型注释。
