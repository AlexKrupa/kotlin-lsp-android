// Package download fetches the SDK and Gradle sources that the init script reports as missing.
// The server imports them on its next import.
package download

import (
	"archive/zip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/AlexKrupa/kotlin-lsp-android/internal/root"
)

// BaseURL is a variable so that tests can point it at a local server.
var BaseURL = "https://services.gradle.org/distributions"

// The sources archive is large and the download runs in the background, so the limit only stops
// a connection that hangs for ever. A hung download would hold the lock.
var client = &http.Client{Timeout: 15 * time.Minute}

type missingSources struct {
	AndroidPlatforms []string `json:"androidPlatforms"`
	GradleVersions   []string `json:"gradleVersions"`
}

// Start runs `download <cacheDir>` as a detached child process of this executable and returns at
// once. The child writes to <cache root>/download.log.
func Start(cacheDir string) error {
	executable, err := os.Executable()
	if err != nil {
		return fmt.Errorf("find own executable: %w", err)
	}
	cacheRoot := root.CacheRoot()
	if err := os.MkdirAll(cacheRoot, 0o755); err != nil {
		return fmt.Errorf("create cache folder %s: %w", cacheRoot, err)
	}
	logPath := filepath.Join(cacheRoot, "download.log")
	log, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return fmt.Errorf("open download log %s: %w", logPath, err)
	}
	defer log.Close()
	child := exec.Command(executable, "download", cacheDir)
	child.Stdout = log
	child.Stderr = log
	child.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := child.Start(); err != nil {
		return fmt.Errorf("start download process %s: %w", executable, err)
	}
	return child.Process.Release()
}

// Run downloads what <cacheDir>/missing-sources.json lists. It does nothing when another
// download holds the lock. A failed download does not stop the others: Run returns all errors.
func Run(cacheDir string) error {
	cacheRoot := root.CacheRoot()
	if err := os.MkdirAll(cacheRoot, 0o755); err != nil {
		return fmt.Errorf("create cache folder %s: %w", cacheRoot, err)
	}
	lockPath := filepath.Join(cacheRoot, "download.lock")
	lock, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return fmt.Errorf("open lock %s: %w", lockPath, err)
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil
		}
		return fmt.Errorf("lock %s: %w", lockPath, err)
	}

	missingPath := filepath.Join(cacheDir, "missing-sources.json")
	data, err := os.ReadFile(missingPath)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("read %s: %w", missingPath, err)
	}
	var missing missingSources
	if err := json.Unmarshal(data, &missing); err != nil {
		return fmt.Errorf("parse %s: %w", missingPath, err)
	}

	var errs []error
	for _, platform := range missing.AndroidPlatforms {
		errs = append(errs, sdkSources(platform))
	}
	for _, version := range missing.GradleVersions {
		errs = append(errs, gradleSources(filepath.Join(cacheRoot, "gradle-sources"), version))
	}
	return errors.Join(errs...)
}

func sdkSources(platform string) error {
	packageName := "sources/" + platform
	output, err := exec.Command("android", "sdk", "install", packageName).CombinedOutput()
	if err != nil {
		return fmt.Errorf("android sdk install %s: %w: %s", packageName, err, strings.TrimSpace(string(output)))
	}
	return nil
}

func gradleSources(sourcesDir, version string) error {
	name := "gradle-" + version
	finalDir := filepath.Join(sourcesDir, name)
	if _, err := os.Stat(finalDir); err == nil {
		return nil
	}
	if err := os.MkdirAll(sourcesDir, 0o755); err != nil {
		return fmt.Errorf("create %s: %w", sourcesDir, err)
	}

	url := BaseURL + "/" + name + "-src.zip"
	wantChecksum, err := fetchChecksum(url + ".sha256")
	if err != nil {
		return err
	}
	archive, err := os.CreateTemp(sourcesDir, name+"-*.zip")
	if err != nil {
		return fmt.Errorf("create temporary file in %s: %w", sourcesDir, err)
	}
	defer os.Remove(archive.Name())
	defer archive.Close()
	gotChecksum, err := fetchTo(archive, url)
	if err != nil {
		return err
	}
	if gotChecksum != wantChecksum {
		return fmt.Errorf("checksum of %s is %s, want %s", url, gotChecksum, wantChecksum)
	}

	partialDir := finalDir + ".partial"
	if err := os.RemoveAll(partialDir); err != nil {
		return fmt.Errorf("remove %s: %w", partialDir, err)
	}
	if err := extractSrcMain(archive.Name(), name, partialDir); err != nil {
		os.RemoveAll(partialDir)
		return err
	}
	if err := os.Rename(partialDir, finalDir); err != nil {
		os.RemoveAll(partialDir)
		return fmt.Errorf("rename %s to %s: %w", partialDir, finalDir, err)
	}
	return nil
}

func fetchChecksum(url string) (string, error) {
	response, err := client.Get(url)
	if err != nil {
		return "", fmt.Errorf("get %s: %w", url, err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf("get %s: %s", url, response.Status)
	}
	body, err := io.ReadAll(response.Body)
	if err != nil {
		return "", fmt.Errorf("read %s: %w", url, err)
	}
	fields := strings.Fields(string(body))
	if len(fields) == 0 {
		return "", fmt.Errorf("checksum file %s is empty", url)
	}
	return fields[0], nil
}

// fetchTo writes the body of url to target and returns its SHA-256 digest as hex.
func fetchTo(target *os.File, url string) (string, error) {
	response, err := client.Get(url)
	if err != nil {
		return "", fmt.Errorf("get %s: %w", url, err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf("get %s: %s", url, response.Status)
	}
	hash := sha256.New()
	if _, err := io.Copy(io.MultiWriter(target, hash), response.Body); err != nil {
		return "", fmt.Errorf("download %s to %s: %w", url, target.Name(), err)
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

// extractSrcMain copies the files that have a src/main path segment from the folder topDir of the
// archive into targetDir.
func extractSrcMain(archivePath, topDir, targetDir string) error {
	reader, err := zip.OpenReader(archivePath)
	// The stdlib reports names with ".." but still returns a reader. The check below rejects them
	// with a message that names the entry.
	if err != nil && !errors.Is(err, zip.ErrInsecurePath) {
		return fmt.Errorf("open archive %s: %w", archivePath, err)
	}
	defer reader.Close()

	extracted := 0
	for _, entry := range reader.File {
		relative, found := strings.CutPrefix(entry.Name, topDir+"/")
		if !found || !entry.Mode().IsRegular() || !hasSrcMain(relative) {
			continue
		}
		if !filepath.IsLocal(relative) {
			return fmt.Errorf("archive entry %q leaves the target folder %s", entry.Name, targetDir)
		}
		if err := extractFile(entry, filepath.Join(targetDir, relative)); err != nil {
			return err
		}
		extracted++
	}
	if extracted == 0 {
		return fmt.Errorf("archive %s has no src/main files in %s/", archivePath, topDir)
	}
	return nil
}

func hasSrcMain(path string) bool {
	segments := strings.Split(path, "/")
	for index := 0; index+1 < len(segments); index++ {
		if segments[index] == "src" && segments[index+1] == "main" {
			return true
		}
	}
	return false
}

func extractFile(entry *zip.File, targetPath string) error {
	if err := os.MkdirAll(filepath.Dir(targetPath), 0o755); err != nil {
		return fmt.Errorf("create folder of %s: %w", targetPath, err)
	}
	source, err := entry.Open()
	if err != nil {
		return fmt.Errorf("open archive entry %q: %w", entry.Name, err)
	}
	defer source.Close()
	target, err := os.OpenFile(targetPath, os.O_CREATE|os.O_WRONLY|os.O_EXCL, 0o644)
	if err != nil {
		return fmt.Errorf("create %s: %w", targetPath, err)
	}
	if _, err := io.Copy(target, source); err != nil {
		target.Close()
		return fmt.Errorf("extract %q to %s: %w", entry.Name, targetPath, err)
	}
	return target.Close()
}
