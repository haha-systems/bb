# bb

a little file event watcher written in [zig](https://ziglang.org).

**sorry: currently linux only*

## building

1. `zig build --release=fast`
2. `cp zig-out/bin/bb ~/.local/bin` (or wherever you want it)

## usage

```
bb <path> "<pattern>" -- <command> [args..]
```

`path` - the path to watch for events, includes all subdirs, uses .gitignore if available, supports relative or absolute paths

`pattern` - a simple pattern to filter for specific files, supports simple glob (*) and maybe (?) parameters, e.g. `*.zig` or `?prefix_*.zig`, uses .gitignore if available, **must be enclosed in quotes**

`--` to pass the next args to `bb`

`command` - the command you want to run on file events

`args...` - any additional args for the command

### full example

```bash
bb . "*.zig" -- zig build test --summary all
```

this will cause any changes to *.zig files in the current directory and below to trigger a test build to run

## why?

- learning zig/linux stuff
- i needed a file watcher, so i made one

## why not just use X?

see [why?](#why)

# license

see [LICENSE.md](LICENSE.md)
