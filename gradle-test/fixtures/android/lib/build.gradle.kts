plugins {
    id("com.android.library")
}

android {
    namespace = "com.example.lib"
    compileSdk = 36
    defaultConfig {
        minSdk = 24
    }
}

dependencies {
    implementation("androidx.annotation:annotation:1.9.1")
}
