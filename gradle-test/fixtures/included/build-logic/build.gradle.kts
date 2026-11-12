plugins {
    `java-gradle-plugin`
}

gradlePlugin {
    plugins {
        create("convention") {
            id = "fixture.convention"
            implementationClass = "ConventionPlugin"
        }
    }
}
