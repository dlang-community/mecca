module mecca.lib.paths;


struct Path {
    string _path;

    this(string path) {
        _path = path;
    }

    Path opBinary(string op: "/")(string rhs) {
        return Path(_path ~ "/" ~ rhs);
    }
    Path opBinary(string op: "/")(Path rhs) {
        return Path(_path ~ "/" ~ rhs);
    }
    Path opBinaryRight(string op: "/")(string lhs) {
        return Path(lhs ~ "/" ~ _path);
    }

    // stat, exists, isDir, isFile, isSymlink,
    // unlink, link, symlink, copy, move, rename
    // mkdir, rmdir(recurisve)
    // write, read, open, touch
    // dirname, basename, suffix (".exe")
    // chown, chmod, access
    // touch

    enum IterTypes {
        ALL    = 0x00,
        FILES  = 0x01,
        DIRS   = 0x02,
    }

    struct DirIter {
        Path parent;
        string globPattern;
        IterTypes types;
        // DIR* dir;

        this(Path parent, string globPattern, IterTypes types) {
            this.parent = parent;
            this.globPattern = globPattern;
            this.types = types;
        }

        @property bool empty() {
            return true;
        }
        @property Path front() {
            return Path.init;
        }
        void popFront() {
        }
    }

    DirIter iter(string globPattern=null, IterTypes types=IterTypes.ALL) {
        return DirIter(this, globPattern, types);
    }
}


unittest {
    auto p1 = Path("/hello/world");
    auto p2 = p1 / "zorld";
    auto Sp3 = "/borld" / p1;
}


struct WorkDir {
    private static __gshared Path path;

    @disable this();
    @disable this(this);

    shared static this() {
        // getcwd()
    }

    @property Path get() nothrow {
        return path;
    }

    static void change(string newPath) {
        change(Path(newPath));
    }
    static void change(Path newPath) {
    }

    static auto push(string newPath) {
        return push(Path(newPath));
    }
    static auto push(Path newPath) {
        static struct Stacked {
            private Path prev;
            private this(Path prev, Path newPath) {
                this.prev = prev;
                WorkDir.change(newPath);
            }
            ~this() {
                WorkDir.change(prev);
            }
        }
        return Stacked(path, newPath);
    }
}


unittest {
    with (WorkDir.push("/tmp")) {
    }
}







