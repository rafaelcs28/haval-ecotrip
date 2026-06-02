import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
}

// Assinatura: mesma lógica do :app (local.properties em dev, env vars em CI).
val localProps = Properties().also { props ->
    rootProject.file("local.properties").takeIf { it.exists() }
        ?.inputStream()?.use { props.load(it) }
}
fun signingProp(envKey: String, localKey: String = envKey): String =
    System.getenv(envKey) ?: localProps.getProperty(localKey) ?: ""

android {
    namespace = "br.com.redesurftank.ecotripcluster"
    compileSdk = 36

    defaultConfig {
        applicationId = "br.com.redesurftank.ecotripcluster"
        minSdk = 26
        targetSdk = 34
        versionCode = 21
        versionName = "1.20"
    }

    signingConfigs {
        create("release") {
            val storeFilePath = signingProp("SIGNING_STORE_FILE")
            if (storeFilePath.isNotEmpty()) {
                storeFile     = file(storeFilePath)
                storePassword = signingProp("SIGNING_STORE_PASSWORD")
                keyAlias      = signingProp("SIGNING_KEY_ALIAS")
                keyPassword   = signingProp("SIGNING_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        named("release") {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    kotlinOptions { jvmTarget = "11" }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
}
