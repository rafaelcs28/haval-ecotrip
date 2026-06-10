import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "br.com.consorciolimpagyn.navrelay"
    compileSdk = 36

    defaultConfig {
        applicationId = "br.com.consorciolimpagyn.navrelay"
        minSdk = 28
        //noinspection ExpiredTargetSdkVersion
        targetSdk = 28   // target baixo relaxa o background-activity-start (abre o Maps/Waze sozinho)
        versionCode = (project.findProperty("vCode") as String?)?.toIntOrNull() ?: 1
        versionName = (project.findProperty("vName") as String?) ?: "1.0"
    }

    buildTypes {
        named("release") {
            isMinifyEnabled = false
            // App é sideload (download direto), não Play Store. Assina com a debug key
            // pra a release instalar por cima do build debug já instalado sem desinstalar.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    buildFeatures { compose = true }
}

kotlin {
    jvmToolchain(11)
    compilerOptions { jvmTarget = JvmTarget.JVM_11 }
}

dependencies {
    implementation(libs.lifecycle.runtime.ktx)
    implementation(libs.activity.compose)
    implementation(platform(libs.compose.bom))
    implementation(libs.ui)
    implementation(libs.ui.graphics)
    implementation(libs.material3)
    implementation("org.eclipse.paho:org.eclipse.paho.client.mqttv3:1.2.5")
    implementation("org.slf4j:slf4j-nop:1.7.36")
    debugImplementation(libs.ui.tooling)
}
