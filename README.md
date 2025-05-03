# MongoDB Replica Set Setup

This repo can be used to provision MongoDB instances intended to be part of a replica set (either single-member or multi-member).


# Prerequisites

## Generate a key for keyFile

This key must be stored in a common keyFile location on ALL replica set members. To generate a valid key (this must be in base64), run:

```
openssl rand -base64 32
```

The output of this function should be placed in the file at the path specified for security.keyFile in your /etc/mongodb/mongod.conf.

**WARNING**: this file needs to be copied from the primary to all secondary members as it's used for authentication between members.

## Install micro on the instance

Not required, but helpful. Install `micro` via `sudo apt install -y micro` to installed the Micro IDE which gives a mouse-friendly TUI for editing files on a Linux machine.

## Copy files to instance via Git

```
git clone https://github.com/cheatcode/mongodb.git
```

Let this copy into the /root/mongodb directory.

