/// 客户端内置预设分类,绝不发送给服务器。
///
/// 服务器分类(Category)只有自定义分类。预设分类在编辑页展示,
/// 选中预设时 category_id 存为 null(服务器视角为"未分类")。
/// ponytail: 预设无服务器 id,无法持久化其标签;若后端未来预置这些分类,
/// 可将预设合并到自定义分类下拉中,本文件即删除。
const List<String> kPhysicalPresetCategories = ['房产', '车辆', '贵金属', '收藏品', '其他'];

const List<String> kVirtualPresetCategories = ['银行账户', '证券投资', '加密货币', '数字账户', '其他'];

/// 按资产类型返回对应的预设分类列表。
List<String> presetCategoriesFor(String assetType) =>
    assetType == 'virtual' ? kVirtualPresetCategories : kPhysicalPresetCategories;
