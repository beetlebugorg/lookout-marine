# What R8 must not touch in this app.
#
# Only one rule here is load-bearing, and it is the JNI boundary. The core's
# natives are name-mangled exports, not registered at runtime: src/jni_android.zig
# exports Java_org_beetlebug_lookout_Lookout_nOpen and eighty more like it, and
# the JVM resolves each one by the CLASS name and the METHOD name at the first
# call. Rename either and the app dies on its first chart open, with a link
# error that names a symbol nobody wrote.
#
# The default proguard-android.txt already keeps classes that declare native
# methods, so this is belt and braces. It is spelled out because the default is
# not this project's to rely on, and because the failure is a crash on device
# rather than a build error.
-keepclasseswithmembernames,includedescriptorclasses class org.beetlebug.lookout.Lookout {
    native <methods>;
}

# The Activity and the Service are named in AndroidManifest.xml; AGP keeps
# manifest-referenced classes on its own, so nothing is needed for them here.
#
# Compose, AndroidX and kotlinx ship their own consumer rules inside their AARs.
# Adding copies here would only let them drift.
#
# minifyEnabled is currently false for release. Turning it on is its own change
# with its own on-device testing, and these rules are what it will start from.
