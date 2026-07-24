plugins {
    id("com.android.application")
}

android {
    namespace = "com.example.smartergrillbletester"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.example.smartergrillbletester"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1"
    }
}

dependencies {
    implementation("org.eclipse.paho:org.eclipse.paho.client.mqttv3:1.2.5")
    testImplementation("junit:junit:4.13.2")
}
