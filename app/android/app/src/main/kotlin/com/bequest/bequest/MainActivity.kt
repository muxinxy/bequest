package com.bequest.bequest

import io.flutter.embedding.android.FlutterFragmentActivity

// 必须继承 FlutterFragmentActivity:local_auth 生物识别要求宿主为 FragmentActivity,
// 否则 authenticate 抛 PlatformException(no_fragment_activity),系统指纹/人脸弹窗无法出现。
class MainActivity : FlutterFragmentActivity()
