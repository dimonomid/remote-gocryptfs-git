# Git gocryptfs wrapper

This is a small wrapper for git repository stored on a remote server in an
encrypted form.

The basic idea is: all git repos are stored in a directory encrypted with
[gocryptfs](https://github.com/rfjakob/gocryptfs), and majority of time, its
plaintext version is not mounted anywhere. Whenever we need to run a git
command involving remote server (such as `git fetch`, `git push` etc), we do it
via wrapper, which does the following:

- Collects the encryption passphrase (either from an environment variable, or
  if it's not available, request it from the user right in the terminal
  session)
- On the remote server, decrypt the repos (by mounting the plaintext volume to
  a certain location)
- Execute whatever git command we wanted (which will interact with the
  remote plaintext git repo we just mounted above)
- On the remote server, unmount the plaintext dir

That's it.

Why not just rely on full-disk encryption - because it protects data when the
server is powered off, but it does not protect data from someone who gets
access while the server is running.

Why not [git-remote-gcrypt](https://github.com/spwhitton/git-remote-gcrypt) -
shortly, because it seemed too invasive for my needs. Every push is a
force-push, performance suffers on big repos significantly, custom encrypted
repository format... I mean it's secure, and in particular it's more secure
than this wrapper, but I wanted something more low-key.

The weakest point of this gocryptfs wrapper is that while someone interacts
with the repo, its plaintext contents are mounted somewhere, so if the access
to the corresponding OS user is compromised, then the attacker just needs to
wait for the right moment to read the data. Keep in mind though that by
default, gocryptfs FUSE mount isn't accessible by other users at all, so
precisely the user who decrypts the repos (or someone with sudo access,
obviously) needs to be compromised. For my case, I considered it to be
acceptable, and a reasonable tradeoff between usability and security.

Tbh I'd love to have native git support for encrypted repositories, which
doesn't affect usability in any way except for having to provide the passphrase
when interacting with the repo, and having the repo always encrypted (only the
workdir on the local machine should be plaintext). But alas.

## Setup

### On the remote server

First, [install gocryptfs](https://github.com/rfjakob/gocryptfs#installation).

Then, initialize your encrypted dir with repos, and prepare the mountpoint for
the plaintext repos. You can check out gocryptfs docs for all the details, but
in the simplest form it can be something like this:

```bash
mkdir /home/user/repos_encrypted
mkdir /home/user/repos_plain
gocryptfs -init /home/user/repos_encrypted

# For the bootstrap, mount the plaintext repos manually
gocryptfs /home/user/repos_encrypted /home/user/repos_plain

# Copy or initialize repos in the plaintext dir
mkdir /home/user/repos_plain/myrepo1
git init --bare /home/user/repos_plain/myrepo1

mkdir /home/user/repos_plain/myrepo2
git init --bare /home/user/repos_plain/myrepo2

# Unmount the plaintext repos
umount /home/user/repos_plain
```

Now that dir with repos is in place, copy the
[remote-gocryptfs-git-server.sh](./remote-gocryptfs-git-server.sh) file from
this repo to the remote server and put it somewhere in `PATH` (e.g.
`/usr/local/bin`).

### On the client

Copy the [remote-gocryptfs-git.sh](./remote-gocryptfs-git.sh) file from this
repo somewhere in the `PATH` (e.g. `/usr/local/bin`).

Then, for convenience, in the repos that are hosted in such a way, I prefer
having a wrapper script like `scripts/remote_repo.sh`, like that:

```bash
#!/bin/bash

set -e

if ! command -v remote-gocryptfs-git.sh >/dev/null 2>&1; then
  >&2 echo "remote-gocryptfs-git.sh is not found; install it from https://github.com/dimonomid/remote-gocryptfs-git"
  exit 1
fi

DEST=myuser@myhost \
  PORT=22 \
  ENCRYPTED_GIT_ROOT=/home/user/repos_encrypted \
  PLAINTEXT_GIT_ROOT=/home/user/repos_plain \
  remote-gocryptfs-git.sh "$@"
```

And then point git's remote to the plaintext location, like this:

```
git remote add origin ssh://myuser@myhost:22/home/user/repos_plain/myrepo1
```

That's it. And from now on, whenever you need to do e.g. `git push`, you do it
like this:

```bash
bash scripts/remote_repo.sh git push
```

If everything is set up properly, you'll see output like this:

```
Unlocking remote repos...
Mounting /home/user/repos_encrypted -> /home/user/repos_plain
passfile: reading from file "/dev/stdin"
Decrypting master key
Filesystem mounted and ready.
Running git command: git push
------------------------------------------
Everything up-to-date
------------------------------------------
Locking remote repos back...
Unmounting /home/user/repos_plain
```

The verbatim `git` command output always goes between these
`------------------------------------------` marks, the rest is the encryption
bookkeeping logs printed by the wrapper.

## Limitations

Currently, only one client can safely use it at a time. Concurrent usage from
multiple clients is not supported, and is not gracefully handled either. It
shouldn't be too hard to address, but I just haven't bothered yet, since I only
need it for single-user projects for now.

## License

BSD 2-Clause. See [LICENSE](LICENSE).
