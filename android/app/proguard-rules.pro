# R8 保留规则：Flutter 引擎、插件注册与网络/媒体等依赖反射或 JNI 的入口。
# 保留注解、签名、内部类等属性，避免序列化与反射解析失败。
-keepattributes Signature, *Annotation*, InnerClasses, EnclosingMethod

# Flutter 引擎与插件框架
-keep class io.flutter.** { *; }
-dontwarn io.flutter.**

# 媒体播放：ExoPlayer / Media3，保留其反射加载的数据源与渲染器
-keep class androidx.media3.** { *; }
-keep interface androidx.media3.** { *; }
-dontwarn androidx.media3.**
-keep class com.google.android.exoplayer2.** { *; }
-dontwarn com.google.android.exoplayer2.**

# 网络与序列化库：仅做 -dontwarn，保留其完整实现
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn retrofit2.**
-dontwarn com.google.gson.**
-dontwarn com.squareup.**

# 应用自身入口
-keep class com.hoowhoami.echotv.** { *; }
