# BIT101-iOS 维护手册

这份文档面向“准备继续维护这个仓库的人”，重点不是介绍功能，而是说明：

- 如何构建
- 哪些 target 需要一起看
- 哪些数据是按账号隔离的
- 小组件、锁屏组件和 Live Activity 的维护边界是什么
- 遇到问题时，应该先从哪一层排查

## 1. 工程组成

当前工程包含两个 target：

- 主 App：`BIT101-iOS`
- 扩展：`BIT101ScheduleWidget`

相关 bundle identifier：

- 主 App：`BIT101-dev.BIT101-iOS`
- Widget 扩展：`BIT101-dev.BIT101-iOS.ScheduleWidget`

相关共享容器：

- `group.BIT101-dev.BIT101-iOS.shared`

相关 URL Scheme：

- `bit101`

## 2. 构建与运行

### 2.1 日常开发建议

如果只是改主 App 内部逻辑，可以先做一次主工程构建确认。

如果改动涉及下面这些内容，必须连扩展一起看：

- 课表数据结构
- 小组件快照导出
- 锁屏组件
- Live Activity / 灵动岛
- App Group 相关路径

### 2.2 命令行构建

当前仓库常用的命令行构建方式是：

```bash
xcodebuild \
  -project BIT101-iOS/BIT101-iOS.xcodeproj \
  -scheme BIT101-iOS \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  build
```

如果命令行看不到可用真机，`generic/platform=iOS` 是更稳的兜底方案。

### 2.3 真机调试

真机调试经常还要同时注意：

- 签名是否有效
- 扩展 target 是否也签上了
- App Group entitlement 是否仍然一致
- Live Activities 是否还在 Info.plist / target settings 中启用

## 3. 本地状态与持久化

项目当前本地状态来源主要有四类。

### 3.1 Keychain

用于保存：

- 学校统一认证账号密码
- 与登录恢复相关的敏感信息

相关入口：

- `Login/LoginService.swift`

### 3.2 UserDefaults

用于保存：

- 全局设置
- 账号隔离设置快照
- 话廊相关偏好
- 一些查询筛选偏好

相关入口：

- `Settings/AppSettingsStore.swift`

### 3.3 本地缓存文件

用于保存：

- 课表
- DDL
- 考试
- 自定义日程

相关入口：

- `Schedule/ScheduleModels.swift`

### 3.4 App Group 共享快照

用于保存：

- 提供给 widget / 锁屏组件 / Live Activity 的精简课表快照

相关入口：

- `Schedule/ScheduleWidgetSupport.swift`
- `BIT101ScheduleWidget/BIT101ScheduleWidget.swift`

## 4. 账号隔离的维护原则

当前项目已经做了账号隔离，但这部分非常容易在后续修改时被破坏。

新增设置或缓存前，先问自己：

- 这是设备级偏好，还是账号级偏好
- 切换账号后，它应该跟着变吗
- 退出登录后，这个状态应该保留吗

如果答案偏向“跟账号走”，就不要把它写成全局唯一 key。

目前至少这几类已经按账号隔离：

- 课表 / DDL 缓存
- 社区规则同意状态
- 隐藏用户 / 隐藏帖子
- 一部分查询和筛选偏好

## 5. 小组件、锁屏组件与 Live Activity

### 5.1 修改课表模型时要注意什么

如果你改了主 App 内部的课表结构，不代表 widget 会自动跟上。

因为当前链路是：

1. 主 App 维护完整课表缓存
2. `ScheduleWidgetSupport` 导出精简快照
3. Widget 和 Live Activity 只读快照

所以任何课表结构变化，都要同步检查：

- `ScheduleWidgetSupport.swift`
- `BIT101ScheduleWidget.swift`
- `ScheduleLiveActivityManager.swift`

### 5.2 修改灵动岛提醒时要注意什么

灵动岛不是“独立的数据系统”，而是“基于当前课表和自定义日程计算出的当前项 / 下一项提醒”。

当前提醒逻辑依赖：

- 当前账号的课表缓存
- 自定义日程
- 提前显示阈值

因此如果你看到灵动岛显示异常，不要只盯 widget 代码，先确认：

- 当前账号的课表缓存是否正确
- 快照是否同步出去
- 提前显示阈值是不是把提醒压掉了

### 5.3 锁屏组件与桌面组件

它们虽然共享同一批快照，但展示目标不同：

- 桌面组件强调“下一节 / 后续几节”
- 锁屏组件强调高密度、低字数

后续如果要继续改排版，不要试图用一套视图硬凑所有 family。

## 6. 话廊模块维护建议

### 6.1 分页与刷新

话廊最容易出体验问题的地方不是卡片 UI，而是：

- 刷新后丢位置
- 预取时机不对
- 推荐流去重和过滤
- 可见列表与原始列表错位

维护分页时要区分三个概念：

- 原始服务端返回列表
- 本地过滤后的可见列表
- 当前屏幕上真正处于尾部的触发项

### 6.2 消息中心

消息中心当前的“新消息”不是服务端逐条已读，而是客户端根据分类未读数做的本地近似表现。

这意味着：

- 不要把它误当成强一致的消息系统
- 跨设备同步不保证完全准确
- 但本地体验可以通过“全部已读”“单条点开即清除”保持顺手

## 7. 地图维护建议

地图页的问题通常分成两类：

1. 地图本身功能问题
2. attribution / legal label / logo 相关显示问题

第二类通常更脆，因为依赖系统内部子视图层级。

如果未来系统版本升级后地图角标又异常，优先检查：

- `CampusMapScreen.swift` 里对 `MKMapView` 子视图的处理

## 8. 常见排查路径

### 8.1 登录失败

先分三层看：

1. 学校 CAS 参数获取是否失败
2. 学校登录是否失败
3. BIT101 注册 / 登录桥接是否失败

### 8.2 课表 / 成绩 / 空教室异常

先分清是：

- 本地缓存恢复异常
- 服务端接口变了
- 查询偏好把结果筛掉了

### 8.3 小组件没更新

先看：

1. 主 App 课表是否正确
2. 共享快照是否导出成功
3. Widget 是否读到了共享容器
4. 当前 family 是否命中正确布局

### 8.4 灵动岛不显示

先看：

1. 设备是否支持
2. 开关是否开启
3. 提前显示阈值是否太小
4. 当前是不是根本没有“当前项 / 下一项”

## 9. 更新文档的约定

后续如果你改动了下面这些内容，建议同步更新文档：

- tab 结构
- 账号隔离策略
- 小组件 / 锁屏组件 / Live Activity 行为
- 话廊 feed 结构
- 设置页结构
- 主要模块职责边界

最少要同步更新：

- `README.md`
- `docs/CODEBASE_GUIDE.md`

如果改动已经影响维护方式，还要同步更新：

- `docs/MAINTENANCE_GUIDE.md`
- `docs/FILE_INDEX.md`
