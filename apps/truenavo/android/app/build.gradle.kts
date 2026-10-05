import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Credentials stay outside source control. CI supplies environment variables;
// local maintainers may use the already-gitignored android/key.properties.
val keystoreProperties = Properties().apply {
    val propertiesFile = rootProject.file("key.properties")
    if (propertiesFile.exists()) {
        propertiesFile.inputStream().use { load(it) }
    }
}
val releaseSigningValues = mapOf(
    "storeFile" to (System.getenv("TRUENAVO_KEYSTORE_PATH") ?: keystoreProperties.getProperty("storeFile")),
    "storePassword" to (System.getenv("ANDROID_KEYSTORE_PASSWORD") ?: keystoreProperties.getProperty("storePassword")),
    "keyAlias" to (System.getenv("ANDROID_KEY_ALIAS") ?: keystoreProperties.getProperty("keyAlias")),
    "keyPassword" to (System.getenv("ANDROID_KEY_PASSWORD") ?: keystoreProperties.getProperty("keyPassword")),
)
val hasReleaseSigning = releaseSigningValues.values.all { !it.isNullOrBlank() }
val releaseRequested = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
}
if (releaseRequested) {
    check(hasReleaseSigning) {
        "TrueNavo release signing is required. Configure the upload key; debug signing is never used for a release."
    }
    check(file(releaseSigningValues.getValue("storeFile")!!).isFile) {
        "TrueNavo release keystore file does not exist."
    }
}

android {
    namespace = "com.truenavo.truenavo"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.truenavo.truenavo"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(releaseSigningValues.getValue("storeFile")!!)
                storePassword = releaseSigningValues.getValue("storePassword")
                keyAlias = releaseSigningValues.getValue("keyAlias")
                keyPassword = releaseSigningValues.getValue("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseSigning) signingConfigs.getByName("release") else null
        }
    }
}

dependencies {
    // The TLS trust bridge needs a WebSocket client whose TLS trust manager and
    // hostname policy are replaceable before the HTTP upgrade.
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
    testImplementation("com.squareup.okhttp3:okhttp-tls:4.12.0")
}

flutter {
    source = "../.."
}
