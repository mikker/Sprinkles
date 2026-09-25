package main

import (
	"fmt"
	"os"
	"path/filepath"
)

const globalCSS = `/* This is Sprinkles' global.css.
 *
 * The styles you add here will be added to every page you visit.
 *
 * To add styles specific to a single domain, create files in this directory, named
 * after the (full) domain, eg. "twitter.com.css" or "subdomain.example.com.css".
 *
 * For example, uncomment the line below to get an extra creamy web experience: */

 /* body { background-color: papayawhip; } */
`

const globalJS = `// This is Sprinkles' global.js.
//
// The JavaScript code you add here will be run on every page you visit.
//
// To add scripts specific to a single domain, create files in this directory, name
// after the domain, eg. "twitter.com.js" or "subdomain.example.com.js".
//
// For example, uncomment the lines below to change every image on the web to random new one:

// for (const elm of document.querySelectorAll("img")) {
//   elm.src = ` + "`//picsum.photos/${elm.width}`" + `
// }
`

// prepareScriptsDir creates dir if needed and adds global.css/global.js unless
// present. Returns the paths of the files it wrote.
func prepareScriptsDir(dir string) ([]string, error) {
	if fi, err := os.Lstat(dir); err == nil && fi.Mode()&os.ModeSymlink != 0 {
		if _, err := os.Stat(dir); err != nil {
			target, _ := os.Readlink(dir)
			return nil, fmt.Errorf("%s is a symlink to %s, which doesn't exist", tildify(dir), tildify(target))
		}
	}
	if fi, err := os.Stat(dir); err == nil && !fi.IsDir() {
		return nil, fmt.Errorf("%s is not a directory", tildify(dir))
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}

	var written []string
	for _, file := range []struct{ name, content string }{{"global.css", globalCSS}, {"global.js", globalJS}} {
		path := filepath.Join(dir, file.name)
		if exists(path) {
			continue
		}
		if err := os.WriteFile(path, []byte(file.content), 0o644); err != nil {
			return written, err
		}
		written = append(written, path)
	}
	return written, nil
}
