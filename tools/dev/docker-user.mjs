// Prints `--user uid:gid` on Linux/macOS so containers do not create root-owned files; nothing on Windows.
process.stdout.write(process.platform === "win32" ? "" : `--user ${process.getuid()}:${process.getgid()}`);
