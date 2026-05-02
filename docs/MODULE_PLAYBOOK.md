# BIT101-iOS 模块维护清单

这份文档不是介绍模块“是什么”，而是回答：

- 如果我要改这个模块，我应该先看哪几个文件
- 哪些地方最容易出回归
- 改完后最值得人工验证什么

适合当作日常维护的落地手册。

## 1. 登录模块

### 先看哪些文件

- `Login/LoginViews.swift`
- `Login/LoginViewModel.swift`
- `Login/LoginService.swift`

### 最容易出问题的点

- 学校 CAS 参数变更
- 学校登录成功但 BIT101 侧注册 / 登录桥接失败
- 登录态检查误把网络波动或学校页面异常当成凭据失效，导致清掉 `fake-cookie` 并连带让 widget / Apple Watch 显示未登录
- 账号切换后，本地状态没有跟着更新
- URL 跳转链里出现 `http -> https` 兼容问题

### 改完建议验证

- 冷启动自动恢复登录
- 断网 / 弱网下触发登录检查时，不应直接退出登录或把手表端推成未登录
- BIT101 明确返回 401 或学校 CAS 静默重登明确失败时，应能正常清退并回到登录流程
- 退出登录再重新登录
- 切换到另一个账号后，课表和设置是否串号

## 2. 日程模块

### 先看哪些文件

- `Schedule/ScheduleModels.swift`
- `Schedule/ScheduleService.swift`
- `Schedule/ScheduleViewModel.swift`
- `Schedule/ScheduleRootView.swift`

### 最容易出问题的点

- 缓存恢复和同步覆盖顺序
- 自定义日程与远端课表合并
- 空教室校区 / 教学楼 / 节次自动匹配
- DDL 与考试的展示边界

### 改完建议验证

- 冷启动是否能秒开并恢复缓存
- 手动同步后结果是否正常刷新
- 空教室是否仍按当前时段块筛选
- 切号后是否不再使用上一个账号的课表

## 3. 成绩模块

### 先看哪些文件

- `Score/ScoreModels.swift`
- `Score/ScoreService.swift`
- `Score/ScoreRootView.swift`

### 最容易出问题的点

- 成绩解析字段兼容
- 学期筛选与成绩类型筛选
- “上一次筛选偏好”恢复逻辑
- 列表排序偏好与统计口径是否被混在一起

### 改完建议验证

- 成绩查询是否仍正常
- 学期筛选退出重进后是否恢复
- 全选 / 全不选 / 0 选是否正常
- 按名称 / 成绩 / 均分 / 学分切换升序和降序后，列表顺序是否符合预期

## 4. 地图模块

### 先看哪些文件

- `Map/CampusMapScreen.swift`

### 最容易出问题的点

- `MKMapView` 桥接
- 校区跳转
- attribution / legal label 隐藏
- 系统版本变化导致子视图层级变化

### 改完建议验证

- 拖拽缩放
- 校区切换
- 回到我的位置
- 地图角标是否异常

## 5. 话廊模块

### 先看哪些文件

- `Gallery/GalleryModels.swift`
- `Gallery/GalleryService.swift`
- `Gallery/GalleryViewModel.swift`
- `Gallery/GalleryRootView.swift`
- `Gallery/GalleryPosterDetailViewModel.swift`

### 最容易出问题的点

- feed 刷新后跳位置
- 推荐流分页、预取和去重
- 本地过滤后的可见列表与原始列表错位
- 帖子详情、图片查看器、消息页之间的路由
- 本地敏感词与屏蔽逻辑

### 改完建议验证

- `关注 / 推荐 / 最新 / 最热 / 机器人` 切换
- 推荐流下滑分页
- 搜索结果分页
- 帖子详情和评论
- 消息中心四个分类切换
- 点消息进入帖子详情

## 6. 我的模块

### 先看哪些文件

- `Mine/MineModels.swift`
- `Mine/MineService.swift`
- `Mine/MineViewModel.swift`
- `Mine/MineRootView.swift`

### 最容易出问题的点

- 个人信息刷新与分页并存
- 粉丝 / 关注 / 帖子分页
- 我的主页与他人主页复用
- 从帖子详情、评论作者跳到他人主页

### 改完建议验证

- 我的主页数据是否正常
- 他人主页能否进入
- 粉丝 / 关注 / 帖子是否能加载更多
- 从他人主页再点帖子详情是否正常

## 7. 设置模块

### 先看哪些文件

- `Settings/AppSettingsStore.swift`
- `Settings/SettingsRootView.swift`
- `Settings/SettingsServices.swift`

### 最容易出问题的点

- 设置是全局还是账号隔离
- 改完后是否即时生效
- 文案与实际行为不一致

### 改完建议验证

- 主题切换
- 自动旋转
- 话廊屏蔽偏好
- 灵动岛阈值
- 关于页与开源声明

## 8. 小组件 / 锁屏组件 / Live Activity

### 先看哪些文件

- `Schedule/ScheduleWidgetSupport.swift`
- `Schedule/ScheduleLiveActivityManager.swift`
- `BIT101ScheduleWidget/BIT101ScheduleWidget.swift`
- `BIT101ScheduleWidget/BIT101ScheduleWidgetBundle.swift`

### 最容易出问题的点

- 主 App 快照变了，扩展没同步
- widget family 布局被改坏
- 锁屏组件、桌面组件、Live Activity 混成一套逻辑
- 提前显示阈值与实际显示不一致

### 改完建议验证

- 桌面小组件
- 锁屏组件
- Live Activity / 灵动岛
- 深链是否仍然能打开到 `日程 -> 课表`

## 9. 跨模块改动时的建议顺序

如果你准备改的是“一个设置影响多个页面”“一个缓存影响主 App 和 widget”这类功能，建议顺序是：

1. 先定位真实的数据源
2. 再确认谁负责持久化
3. 再确认哪些页面只是消费方
4. 最后再改 UI

不要从页面层直接往下瞎补逻辑，否则很容易变成：

- UI 先写一套临时状态
- ViewModel 再补一套
- 持久化层又补一套

最后谁也说不清到底哪份状态才是真的。
