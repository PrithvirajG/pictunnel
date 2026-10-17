package storage

import "os"

type osFS struct{}

// OS returns the real filesystem.
func OS() FS { return osFS{} }

// wrap avoids returning a typed-nil *os.File inside the File interface.
func wrap(f *os.File, err error) (File, error) {
	if err != nil {
		return nil, err
	}
	return f, nil
}

func (osFS) Create(name string) (File, error) { return wrap(os.Create(name)) }
func (osFS) OpenFile(name string, flag int, perm os.FileMode) (File, error) {
	return wrap(os.OpenFile(name, flag, perm))
}
func (osFS) Open(name string) (File, error)               { return wrap(os.Open(name)) }
func (osFS) Rename(from, to string) error                 { return os.Rename(from, to) }
func (osFS) Remove(name string) error                     { return os.Remove(name) }
func (osFS) RemoveAll(path string) error                  { return os.RemoveAll(path) }
func (osFS) MkdirAll(path string, perm os.FileMode) error { return os.MkdirAll(path, perm) }
func (osFS) Stat(name string) (os.FileInfo, error)        { return os.Stat(name) }
func (osFS) ReadDir(dir string) ([]os.DirEntry, error)    { return os.ReadDir(dir) }
func (osFS) SyncDir(dir string) error                     { return syncDir(dir) }
