# Large File Test

This is a test repo for the [Git Large File Storage](https://git-lfs.github.com/) extension powered by GitHub.

## Install the git-lfs extension

Find the download link for a binary distribution of your working platform from the [official website](https://git-lfs.github.com/). For OS X users with package managers, simply use `brew install git-lfs` or `port install git-lfs`.

After installing the extension, a first-time setup should be done with the command `git lfs install`. Probably there's some configuration magic for git-lfs to work with git automatically.

## Use git-lfs in your repo

If you have some large files in a git repo, which you want them to be stored separately from the repo to a dedicated server, a simple command `git lfs track "*.bin"` will work. The `*.bin` in the command refers to a Git LFS path that will be added to the `.gitattributes` file for git-lfs to automatically upload to and download from the large file storage server.

The uploadings and downloadings are all automatically carried out by git-lfs whenever you clone, pull, fetch or push after you've setup the extension properly.

## How the big testing file is created

```
dd if=/dev/zero of=big-file.bin bs=1024 count=10240
```

`/dev/zero` is a special device file that provides null characters. `/dev/random` or `/dev/urandom` should also do the trick but they are more CPU intensive and `/dev/zero` just works if you only need a file big enough for testing bandwidth or something else.
