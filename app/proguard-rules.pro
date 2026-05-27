-keep class com.beantechs.** { *; }
-keep class rikka.shizuku.** { *; }
-keep class org.lsposed.hiddenapibypass.** { *; }
-keep class br.com.redesurftank.ecotrip.managers.** { *; }

# androidx.security:security-crypto usa Google Tink, que referencia anotações
# (javax.annotation.*, errorprone) ausentes em runtime → R8 reclama de classes
# faltando. Ignora os warnings e mantém o Tink.
-dontwarn javax.annotation.**
-dontwarn com.google.errorprone.annotations.**
-keep class com.google.crypto.tink.** { *; }
