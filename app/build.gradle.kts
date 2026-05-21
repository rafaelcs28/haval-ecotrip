import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

// Load signing properties from local.properties (local dev) or environment vars (CI)
val localProps = Properties().also { props ->
    rootProject.file("local.properties").takeIf { it.exists() }
        ?.inputStream()?.use { props.load(it) }
}
fun signingProp(envKey: String, localKey: String = envKey): String =
    System.getenv(envKey) ?: localProps.getProperty(localKey) ?: ""

android {
    namespace = "br.com.redesurftank.ecotrip"
    compileSdk = 36

    defaultConfig {
        applicationId = "br.com.redesurftank.ecotrip"
        minSdk = 28
        //noinspection ExpiredTargetSdkVersion
        targetSdk = 28
        versionCode = 157
        versionName = "5.26"

        buildConfigField("String", "GITHUB_REPO", "\"rafaelcs28/haval-ecotrip\"")
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
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    buildFeatures {
        aidl = true
        compose = true
        buildConfig = true
    }
}

kotlin {
    jvmToolchain(11)
    compilerOptions { jvmTarget = JvmTarget.JVM_11 }
}

dependencies {
    implementation(libs.shizuku)
    implementation(libs.shizuku.provider)
    implementation(libs.hiddenapibypass)
    implementation(libs.gson)
    implementation(libs.lifecycle.runtime.ktx)
    implementation(libs.activity.compose)
    implementation(platform(libs.compose.bom))
    implementation(libs.ui)
    implementation(libs.ui.graphics)
    implementation(libs.ui.tooling.preview)
    implementation(libs.material3)
    implementation("com.google.android.material:material:1.12.0")
    implementation("org.eclipse.paho:org.eclipse.paho.client.mqttv3:1.2.5")
    implementation("org.slf4j:slf4j-nop:1.7.36")
    implementation(libs.material.icons.extended)
    annotationProcessor(libs.annotation.processor)
    compileOnly(libs.annotation)
    debugImplementation(libs.ui.tooling)
    debugImplementation(libs.ui.test.manifest)
}
