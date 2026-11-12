import java.io.File;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import java.util.TreeMap;
import java.util.stream.Stream;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import org.gradle.tooling.GradleConnector;
import org.gradle.tooling.ProjectConnection;
import org.gradle.tooling.model.kotlin.dsl.KotlinDslModelsParameters;
import org.gradle.tooling.model.kotlin.dsl.KotlinDslScriptModel;
import org.gradle.tooling.model.kotlin.dsl.KotlinDslScriptsModel;

/**
 * Writes the Kotlin DSL script model of a Gradle build as JSON.
 *
 * <p>Usage: {@code java -cp "<gradle-home>/lib/*" ScriptModel.java <root> <gradle-home> <output>}
 */
public class ScriptModel {

    private static final String PLUGIN_DESCRIPTOR_FOLDER = "META-INF/gradle-plugins/";
    private static final String PLUGIN_DESCRIPTOR_SUFFIX = ".properties";
    private static final String IMPLEMENTATION_CLASS_KEY = "implementation-class";

    private final Map<File, Map<String, String>> pluginClassesByEntry = new LinkedHashMap<>();
    private final Map<List<String>, Integer> listIndexes = new LinkedHashMap<>();

    public static void main(String[] arguments) {
        if (arguments.length != 3) {
            System.err.println("ScriptModel: expected <root> <gradle-home> <output>, got " + List.of(arguments));
            System.exit(1);
        }
        try {
            new ScriptModel().run(new File(arguments[0]), new File(arguments[1]), Path.of(arguments[2]));
        } catch (Exception exception) {
            System.err.println("ScriptModel: cannot write the script model of " + arguments[0]);
            for (Throwable cause = exception; cause != null; cause = cause.getCause()) {
                System.err.println("  " + cause);
            }
            System.exit(1);
        }
    }

    private void run(File root, File gradleHome, Path output) throws IOException {
        Map<File, KotlinDslScriptModel> scriptModels = requestScriptModels(root, gradleHome);
        String json = toJson(scriptModels);
        Files.writeString(output, json, StandardCharsets.UTF_8);
    }

    private static Map<File, KotlinDslScriptModel> requestScriptModels(File root, File gradleHome) {
        GradleConnector connector = GradleConnector.newConnector()
            .useInstallation(gradleHome)
            .forProjectDirectory(root);
        String gradleUserHome = System.getenv("GRADLE_USER_HOME");
        if (gradleUserHome != null && !gradleUserHome.isEmpty()) {
            connector.useGradleUserHomeDir(new File(gradleUserHome));
        }
        try (ProjectConnection connection = connector.connect()) {
            String correlationId = "-P" + KotlinDslModelsParameters.CORRELATION_ID_GRADLE_PROPERTY_NAME
                + "=" + System.nanoTime();
            return connection.model(KotlinDslScriptsModel.class)
                .addArguments(correlationId, KotlinDslModelsParameters.CLASSPATH_MODE_SYSTEM_PROPERTY_DECLARATION)
                .get()
                .getScriptModels();
        }
    }

    private String toJson(Map<File, KotlinDslScriptModel> scriptModels) {
        StringBuilder scripts = new StringBuilder();
        Map<String, KotlinDslScriptModel> sortedModels = new TreeMap<>();
        scriptModels.forEach((file, model) -> sortedModels.put(file.getAbsolutePath(), model));
        sortedModels.forEach((path, model) -> {
            if (scripts.length() > 0) {
                scripts.append(",\n");
            }
            scripts.append("    ").append(quote(path)).append(": {")
                .append("\"sourcePath\": ").append(indexOf(paths(model.getSourcePath())))
                .append(", \"implicitImports\": ").append(indexOf(model.getImplicitImports()))
                .append(", \"pluginClasses\": ").append(pluginClassesJson(model.getClassPath()))
                .append("}");
        });

        StringBuilder lists = new StringBuilder();
        listIndexes.keySet().forEach(list -> {
            if (lists.length() > 0) {
                lists.append(",\n");
            }
            lists.append("    ").append(stringArrayJson(list));
        });

        return "{\n  \"lists\": [\n" + lists + "\n  ],\n  \"scripts\": {\n" + scripts + "\n  }\n}\n";
    }

    private static List<String> paths(List<File> files) {
        return files.stream().map(File::getAbsolutePath).toList();
    }

    private int indexOf(List<String> list) {
        return listIndexes.computeIfAbsent(list, key -> listIndexes.size());
    }

    private String pluginClassesJson(List<File> classPath) {
        Map<String, String> pluginClasses = new TreeMap<>();
        for (File entry : classPath) {
            pluginClassesByEntry.computeIfAbsent(entry, ScriptModel::readPluginClasses)
                .forEach(pluginClasses::putIfAbsent);
        }
        StringBuilder json = new StringBuilder("{");
        pluginClasses.forEach((id, implementationClass) -> {
            if (json.length() > 1) {
                json.append(", ");
            }
            json.append(quote(id)).append(": ").append(quote(implementationClass));
        });
        return json.append("}").toString();
    }

    private static Map<String, String> readPluginClasses(File entry) {
        try {
            if (entry.isDirectory()) {
                return readPluginClassesOfFolder(entry.toPath());
            }
            if (entry.isFile()) {
                return readPluginClassesOfJar(entry);
            }
            // A class folder of a build that has not run yet does not exist.
            return Map.of();
        } catch (IOException | UncheckedIOException exception) {
            System.err.println("ScriptModel: cannot read plugin descriptors of " + entry + ": " + exception);
            return Map.of();
        }
    }

    private static Map<String, String> readPluginClassesOfFolder(Path folder) throws IOException {
        Path descriptors = folder.resolve(PLUGIN_DESCRIPTOR_FOLDER);
        if (!Files.isDirectory(descriptors)) {
            return Map.of();
        }
        Map<String, String> pluginClasses = new TreeMap<>();
        try (Stream<Path> files = Files.list(descriptors)) {
            for (Path file : files.sorted(Comparator.comparing(Path::toString)).toList()) {
                String fileName = file.getFileName().toString();
                if (!fileName.endsWith(PLUGIN_DESCRIPTOR_SUFFIX)) {
                    continue;
                }
                try (var input = Files.newInputStream(file)) {
                    putImplementationClass(pluginClasses, fileName, input.readAllBytes());
                }
            }
        }
        return pluginClasses;
    }

    private static Map<String, String> readPluginClassesOfJar(File jar) throws IOException {
        Map<String, String> pluginClasses = new TreeMap<>();
        try (ZipFile zip = new ZipFile(jar)) {
            for (ZipEntry zipEntry : zip.stream().toList()) {
                String name = zipEntry.getName();
                if (zipEntry.isDirectory()
                    || !name.startsWith(PLUGIN_DESCRIPTOR_FOLDER)
                    || !name.endsWith(PLUGIN_DESCRIPTOR_SUFFIX)) {
                    continue;
                }
                try (var input = zip.getInputStream(zipEntry)) {
                    putImplementationClass(
                        pluginClasses, name.substring(PLUGIN_DESCRIPTOR_FOLDER.length()), input.readAllBytes());
                }
            }
        }
        return pluginClasses;
    }

    private static void putImplementationClass(
        Map<String, String> pluginClasses, String descriptorName, byte[] descriptor
    ) throws IOException {
        // A descriptor in a subfolder is not a plugin id.
        if (descriptorName.contains("/")) {
            return;
        }
        Properties properties = new Properties();
        properties.load(new java.io.ByteArrayInputStream(descriptor));
        String implementationClass = properties.getProperty(IMPLEMENTATION_CLASS_KEY);
        if (implementationClass == null) {
            return;
        }
        String id = descriptorName.substring(0, descriptorName.length() - PLUGIN_DESCRIPTOR_SUFFIX.length());
        pluginClasses.put(id, implementationClass.trim());
    }

    private static String stringArrayJson(List<String> strings) {
        List<String> quoted = new ArrayList<>();
        strings.forEach(string -> quoted.add(quote(string)));
        return "[" + String.join(", ", quoted) + "]";
    }

    private static String quote(String text) {
        StringBuilder json = new StringBuilder("\"");
        for (int index = 0; index < text.length(); index++) {
            char character = text.charAt(index);
            switch (character) {
                case '\\' -> json.append("\\\\");
                case '"' -> json.append("\\\"");
                case '\n' -> json.append("\\n");
                case '\r' -> json.append("\\r");
                case '\t' -> json.append("\\t");
                default -> {
                    if (character < 0x20) {
                        json.append(String.format("\\u%04x", (int) character));
                    } else {
                        json.append(character);
                    }
                }
            }
        }
        return json.append('"').toString();
    }
}
