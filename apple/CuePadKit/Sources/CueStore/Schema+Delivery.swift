extension Schema {
  /// 旧 failed 混合了未交出与已领取后未知，只在结构升级与远端应用入口读取它。
  static let legacyDeliveryFailure = "failed"
  static let deliveryFailureStatus = "CASE WHEN handledBy IS NULL THEN '\(DeliveryStatus.failed.rawValue)' ELSE '\(DeliveryStatus.unconfirmed.rawValue)' END"

  /// 不猜原因文案；领取事实决定旧请求的单向迁移，改写版本使 canonical 值上传。
  static let canonicalDeliveryFailures = """
    UPDATE deliveryRequests SET status = \(deliveryFailureStatus), modifiedAt = modifiedAt + 1
    WHERE status = '\(legacyDeliveryFailure)';
    """
}
