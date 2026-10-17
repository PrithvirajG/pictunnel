// Command covergate fails when statement coverage in a Go cover profile is
// below a threshold, per package and in total (S§11.7 coverage gate).
//
//	go run ./tools/ci/covergate -min 85 -exclude '/gen$|test$' cover.out
//
// Blocks listed more than once (several test binaries covering the same
// package) count as covered if any listing covered them.
package main

import (
	"bufio"
	"flag"
	"fmt"
	"io"
	"os"
	"path"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

type block struct {
	stmts   int
	covered bool
}

type tally struct{ stmts, covered int }

func (t tally) percent() float64 {
	if t.stmts == 0 {
		return 100
	}
	return 100 * float64(t.covered) / float64(t.stmts)
}

// parse reads a cover profile into blocks keyed by "file:range".
func parse(r io.Reader) (map[string]block, error) {
	blocks := map[string]block{}
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	line := 0
	for sc.Scan() {
		line++
		text := strings.TrimSpace(sc.Text())
		if text == "" || strings.HasPrefix(text, "mode:") {
			continue
		}
		// file.go:12.3,14.5 2 1
		f := strings.Fields(text)
		if len(f) != 3 {
			return nil, fmt.Errorf("line %d: malformed %q", line, text)
		}
		stmts, err1 := strconv.Atoi(f[1])
		count, err2 := strconv.Atoi(f[2])
		if err1 != nil || err2 != nil {
			return nil, fmt.Errorf("line %d: malformed %q", line, text)
		}
		b := blocks[f[0]]
		b.stmts = stmts
		b.covered = b.covered || count > 0
		blocks[f[0]] = b
	}
	return blocks, sc.Err()
}

// summarize groups blocks by package (the import path of the file's
// directory), skipping packages that match exclude.
func summarize(blocks map[string]block, exclude *regexp.Regexp) (map[string]tally, tally) {
	pkgs := map[string]tally{}
	var total tally
	for key, b := range blocks {
		file, _, _ := strings.Cut(key, ":")
		pkg := path.Dir(file)
		if exclude != nil && exclude.MatchString(pkg) {
			continue
		}
		t := pkgs[pkg]
		t.stmts += b.stmts
		total.stmts += b.stmts
		if b.covered {
			t.covered += b.stmts
			total.covered += b.stmts
		}
		pkgs[pkg] = t
	}
	return pkgs, total
}

func run(args []string, stdout io.Writer) error {
	fs := flag.NewFlagSet("covergate", flag.ContinueOnError)
	min := fs.Float64("min", 85, "minimum statement coverage in percent, per package and in total")
	excl := fs.String("exclude", "", "regexp of package import paths to leave out")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return fmt.Errorf("usage: covergate [-min N] [-exclude RE] cover.out")
	}
	var exclude *regexp.Regexp
	if *excl != "" {
		var err error
		if exclude, err = regexp.Compile(*excl); err != nil {
			return err
		}
	}
	f, err := os.Open(fs.Arg(0))
	if err != nil {
		return err
	}
	defer f.Close()
	blocks, err := parse(f)
	if err != nil {
		return err
	}
	pkgs, total := summarize(blocks, exclude)
	if total.stmts == 0 {
		return fmt.Errorf("no statements in %s", fs.Arg(0))
	}
	names := make([]string, 0, len(pkgs))
	for p := range pkgs {
		names = append(names, p)
	}
	sort.Strings(names)
	var low []string
	for _, p := range names {
		t := pkgs[p]
		mark := ""
		if t.percent() < *min {
			mark = "  < min"
			low = append(low, p)
		}
		_, _ = fmt.Fprintf(stdout, "%6.1f%%  %s%s\n", t.percent(), p, mark)
	}
	_, _ = fmt.Fprintf(stdout, "%6.1f%%  total (min %.1f%%)\n", total.percent(), *min)
	if total.percent() < *min {
		low = append(low, "total")
	}
	if len(low) > 0 {
		return fmt.Errorf("coverage below %.1f%%: %s", *min, strings.Join(low, ", "))
	}
	return nil
}

func main() {
	if err := run(os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "covergate:", err)
		os.Exit(1)
	}
}
